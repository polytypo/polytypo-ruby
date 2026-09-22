# frozen_string_literal: true

require_relative "quote_ambiguity"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../edits"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # spec/rules/quotes.md (spec 0.5.0), order 40.
      #
      # Mandate 1 (every existing quote glyph is a re-typesetting candidate) and mandate 2 (a
      # space touching a quote mark is sloppiness, not evidence) are this rule's whole
      # architecture. Five passes plus an emit; no backtracking inside a pass, no regular
      # expression, no native-string indexing (ARCHITECTURE.md 4.1, 4.2).
      #
      #   Pass 1 (collect_candidates)  -- collect and classify candidates (quotes.md 3.2)
      #   Pass 2 (pair_candidates)     -- pair the candidates, one stack per width (3.3)
      #   Pass 3 (depth_of)            -- assign glyphs by depth, folded into the render plan (3.4)
      #   Pass 4 (certify)             -- the certification gate (3.5)
      #   Pass 5 (emit)                -- emit edits (3.6)
      module Quotes
        Candidate = Struct.new(:index, :wide, :can_open, :can_close)
        Pair = Struct.new(:open, :close)

        # WIDE is quotes.md 3.1 WIDE. NARROW is QuoteAmbiguity::NARROW, shared with apostrophe so
        # the two rules cannot define two slightly different NARROW sets. WIDE and NARROW are
        # disjoint and their union is QUOTEMARK.
        WIDE = [0x22, 0xAB, 0xBB, 0x201C, 0x201D, 0x201E, 0x201F, 0x301D, 0x301E, 0x301F].freeze

        BREAK = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029, Engine::LINE_MARKER].freeze
        DASHISH = [0x2D, 0x2011, 0x2013, 0x2014].freeze
        OPENISH_LITERAL = [0x28, 0x5B, 0x7B].freeze
        CLOSEISH_LITERAL = [0x29, 0x5D, 0x7D, 0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x2026, 0x2013, 0x2014].freeze

        def self.quote_mark?(cp)
          WIDE.include?(cp) || QuoteAmbiguity.narrow?(cp)
        end

        def self.digit?(cp)
          cp >= 0x30 && cp <= 0x39
        end

        def self.alnum?(cp)
          digit?(cp) || UnicodeUtil.letter?(cp)
        end

        def self.break?(cp)
          BREAK.include?(cp)
        end

        # SPACELIKE = INLINE-SPACE ∪ BREAK.
        def self.spacelike?(cp)
          QuoteAmbiguity.inline_space?(cp) || break?(cp)
        end

        # OPENISH. QUOTEMARK is a member of both OPENISH and CLOSEISH, and is exempt from
        # canOpen's closeish rejection -- Lemma A's entire mechanism (quotes.md 5) and the reason
        # a candidate's verdict never depends on which quote glyph its neighbour is. Do not
        # "simplify" this back to per-glyph lists. MARKER is a member too (modes.md 3.3).
        def self.openish?(cp)
          return true if cp == Engine::MARKER

          OPENISH_LITERAL.include?(cp) || quote_mark?(cp)
        end

        # CLOSEISH -- see openish?'s dual-membership note.
        def self.closeish?(cp)
          return true if cp == Engine::MARKER

          CLOSEISH_LITERAL.include?(cp) || quote_mark?(cp)
        end

        def self.dashish?(cp)
          DASHISH.include?(cp)
        end

        # DELETE-LANDING is the largest landing class for which every earlier-ordered rule's own
        # classes are unaffected by a quote glyph or a U+0020 (quotes.md 3.7, composition
        # obligation).
        def self.delete_landing?(cp)
          alnum?(cp) || quote_mark?(cp)
        end

        # V1ID (quotes.md 3.2, spec 0.4.1) -- a conservative over-approximation, not a claim that
        # every U+0027 becomes U+2019. apostrophe only ever emits U+2019 for a U+0027, but its own
        # case ladder leaves some U+0027s unedited (the prime guard, and "nothing inferable"), and
        # quotes cannot know which without re-deriving apostrophe's verdict against quotes' own
        # not-yet-final output -- circular. V1ID treats every U+0027 as possibly about to become
        # U+2019, and every U+2019 as possibly a U+0027 that already did, so V1's comparison stays
        # invariant across the two rules running in sequence on successive pipeline passes
        # (quotes.md 5, Lemma A).
        def self.v1_identity(cp)
          cp == 0x27 ? 0x2019 : cp
        end

        # glyph_codepoint decodes a locale-declared quote glyph (guaranteed by schema to be
        # exactly one code point) to its code point value.
        def self.glyph_codepoint(str)
          str.ord
        end

        # compute_skip_sets is quotes.md 3.1a -- locale-derived skip sets, computed once per call.
        # These are exactly the positions at which nbsp's N8 can insert a space (nbsp.md 3.10),
        # which is what makes Lemma B's coverage exact rather than a survey.
        def self.compute_skip_sets(quotes_data)
          space_right = {}
          space_left = {}
          [quotes_data["primary"], quotes_data["secondary"]].each do |pair|
            next if pair["innerSpace"] == "none"

            open_cp = glyph_codepoint(pair["open"])
            close_cp = glyph_codepoint(pair["close"])
            next if open_cp == close_cp

            space_right[open_cp] = true
            space_left[close_cp] = true
          end
          { space_right: space_right, space_left: space_left }
        end

        # skip_left/skip_right are the straight-line walk of quotes.md 3.2: step outward across a
        # maximal INLINE-SPACE run. MARKER and every BREAK stop it, because neither is in
        # INLINE-SPACE.
        def self.skip_left(cp, i)
          j = i - 1
          j -= 1 while j >= 0 && QuoteAmbiguity.inline_space?(cp[j])
          j >= 0 ? cp[j] : Engine::NONE
        end

        def self.skip_right(cp, i)
          n = cp.length
          j = i + 1
          j += 1 while j < n && QuoteAmbiguity.inline_space?(cp[j])
          j < n ? cp[j] : Engine::NONE
        end

        # collect_candidates is pass 1 (quotes.md 3.2) -- collect and classify candidates.
        # can_open always skips right and can_close always skips left (mandate 2's inner-side
        # skip); the outer side skips only when nbsp can reach it (the locale-derived
        # space_right/space_left sets), which is what keeps every verdict inert to nbsp (Lemma B).
        def self.collect_candidates(cp, skip_sets, idioms, clitics)
          n = cp.length
          candidates = []

          # spec 0.5.0: the veto set is the UNION of the cited-idiom match (unchanged since 0.4.0)
          # and the general ambiguous-medial-span shape (quotes.md 3.2a) -- quotes must decline
          # pairing for both, so apostrophe's own case ladder never independently "fixes" a shape
          # quotes left alone.
          # spec 1.4.0 adds a third member to the same union: the span-boundary elision veto,
          # which fires only where one literal neighbour is the inline MARKER (quotes.md 3.2).
          idiom_matched = QuoteAmbiguity.compute_idiom_matched_indices(cp, idioms)
          ambiguous_shape = QuoteAmbiguity.compute_ambiguous_shape_indices(cp)
          span_boundary = QuoteAmbiguity.compute_span_boundary_veto_indices(cp, clitics)
          elision_vetoed = idiom_matched.merge(ambiguous_shape).merge(span_boundary)

          (0...n).each do |i|
            g = cp[i]
            next unless quote_mark?(g)

            l_lit = QuoteAmbiguity.at(cp, i - 1)
            r_lit = QuoteAmbiguity.at(cp, i + 1)
            l_skip = skip_left(cp, i)
            r_skip = skip_right(cp, i)

            open_left = skip_sets[:space_left][g] ? l_skip : l_lit
            close_right = skip_sets[:space_right][g] ? r_skip : r_lit

            can_open = (open_left == Engine::NONE || spacelike?(open_left) || openish?(open_left) || dashish?(open_left)) &&
                       r_skip != Engine::NONE && !spacelike?(r_skip) &&
                       (!closeish?(r_skip) || quote_mark?(r_skip) || r_skip == Engine::MARKER)

            can_close = l_skip != Engine::NONE && !spacelike?(l_skip) &&
                        (close_right == Engine::NONE || spacelike?(close_right) || closeish?(close_right) || dashish?(close_right))

            # Medial-elision veto (quotes.md 3.2), NARROW marks only, literal reads: don't,
            # l'été, O'Brien, 1990's -- and, on a second pipeline pass, don't with U+2019, because
            # apostrophe has converted the mark and U+2019 is also NARROW.
            if QuoteAmbiguity.narrow?(g) && l_lit != Engine::NONE && r_lit != Engine::NONE &&
               alnum?(l_lit) && alnum?(r_lit)
              can_open = false
              can_close = false
            end

            # Listed + general ambiguous-shape veto (quotes.md 3.2, spec 0.4.0/0.5.0): both
            # capabilities forced false, overriding every other test in this loop.
            if elision_vetoed.key?(i)
              can_open = false
              can_close = false
            end

            # V1 -- same-V1-identity adjacency veto (quotes.md 3.2), both widths: "", '', ««, ””,
            # plus the same shape separated by exactly one INLINE-SPACE code point at a position
            # nbsp can insert or remove (gap_insertable, scoped to Lemma B's two insertion sites).
            g_v1 = v1_identity(g)
            gap_insertable = skip_sets[:space_right][g] || skip_sets[:space_left][g]
            left_vetoed = v1_identity(l_lit) == g_v1 ||
                          (l_lit != Engine::NONE && QuoteAmbiguity.inline_space?(l_lit) &&
                           v1_identity(l_skip) == g_v1 && gap_insertable)
            right_vetoed = v1_identity(r_lit) == g_v1 ||
                           (r_lit != Engine::NONE && QuoteAmbiguity.inline_space?(r_lit) &&
                            v1_identity(r_skip) == g_v1 && gap_insertable)
            if left_vetoed || right_vetoed
              can_open = false
              can_close = false
            end

            candidates << Candidate.new(i, WIDE.include?(g), can_open, can_close) if can_open || can_close
          end

          candidates
        end

        # vacuous? is quotes.md 3.3 vacuous(a, b). Vacuously true when b = a + 1 (Ruby's Range#all?
        # on the empty range (a+1...a+1) is true, matching the spec directly).
        def self.vacuous?(cp, a, b)
          ((a + 1)...b).all? { |k| QuoteAmbiguity.inline_space?(cp[k]) }
        end

        # pair_candidates is pass 2 (quotes.md 3.3) -- pair the candidates, one stack per width.
        # Closing is tried before opening; a candidate reaches exactly one of three outcomes
        # (paired, pushed, unmatched), and a closer that fails the vacuity condition falls through
        # to step 2 and then step 3 rather than being discarded -- the exhaustive three-outcome
        # shape the certification gate depends on.
        def self.pair_candidates(cp, candidates)
          wide_stack = []
          narrow_stack = []
          pairs = []

          candidates.each do |c|
            stack = c.wide ? wide_stack : narrow_stack
            if c.can_close && !stack.empty?
              top = stack.last
              unless vacuous?(cp, top.index, c.index)
                stack.pop
                pairs << Pair.new(top.index, c.index)
                next
              end
            end
            stack.push(c) if c.can_open
          end

          pairs
        end

        # depth_of is pass 3's depth (quotes.md 3.4), computed over the accepted set, never the
        # raw pass-2 output: on a second run the accepted set is the raw set, so a depth taken
        # over the raw set on run 1 and the accepted set on run 2 would disagree whenever the gate
        # declined anything.
        def self.depth_of(pairs, p)
          depth = 1
          pairs.each do |q|
            depth += 1 if q.open < p.open && p.close < q.close
          end
          depth
        end

        def self.pair_for(quotes_data, depth)
          depth.odd? ? quotes_data["primary"] : quotes_data["secondary"]
        end

        # compute_render_plan is quotes.md 3.5 render's glyph/deletion plan, shared by the
        # certification gate's hypothetical and the real emit (pass 5) -- the only difference
        # between them is whether the plan is applied to a throwaway array or actually returned
        # as edits.
        def self.compute_render_plan(cp, accepted, quotes_data)
          replace = {}
          del = {}
          n = cp.length

          accepted.each do |p|
            glyphs = pair_for(quotes_data, depth_of(accepted, p))
            replace[p.open] = glyph_codepoint(glyphs["open"])
            replace[p.close] = glyph_codepoint(glyphs["close"])

            next unless glyphs["innerSpace"] == "none"

            # Open-side run: the maximal INLINE-SPACE run starting at p.open + 1.
            open_start = p.open + 1
            open_end = open_start
            open_end += 1 while open_end < n && QuoteAmbiguity.inline_space?(cp[open_end])
            open_empty = open_end == open_start
            open_landing = open_end < n ? cp[open_end] : Engine::NONE

            # Close-side run: the maximal INLINE-SPACE run ending at p.close - 1.
            close_end = p.close
            close_start = close_end - 1
            close_start -= 1 while close_start >= 0 && QuoteAmbiguity.inline_space?(cp[close_start])
            close_start += 1
            close_empty = close_start == close_end
            close_landing = close_start - 1 >= 0 ? cp[close_start - 1] : Engine::NONE

            # A run is deleted iff non-empty, its landing is in DELETE-LANDING, and it is not
            # simultaneously both of the pair's runs -- a pair enclosing nothing but spaces
            # deletes neither (quotes.md 3.5). Unreachable for an accepted pair given pass 2's
            # vacuity condition, but the guard is cheap and the spec states it unconditionally.
            same_run = !open_empty && !close_empty && open_start == close_start && open_end == close_end

            if !open_empty && delete_landing?(open_landing) && !same_run
              (open_start...open_end).each { |k| del[k] = true }
            end
            if !close_empty && delete_landing?(close_landing) && !same_run
              (close_start...close_end).each { |k| del[k] = true }
            end
          end

          { replace: replace, del: del }
        end

        # apply_render_plan applies a render plan, returning the rendered array and the
        # order-preserving index map from surviving input indices to output indices.
        def self.apply_render_plan(cp, plan)
          y = []
          m = Array.new(cp.length, -1)
          cp.each_with_index do |c, i|
            next if plan[:del][i]

            m[i] = y.length
            y << (plan[:replace].key?(i) ? plan[:replace][i] : c)
          end
          [y, m]
        end

        # certify is pass 4, the certification gate (quotes.md 3.5): the accepted pairing is
        # checked, not proved. Render the hypothetical output, re-run passes 1-2 on it, and
        # decline pairs until the re-run reproduces the accepted set exactly. Declination is
        # simultaneous per round, and when the intersection fails to shrink A, the pair with the
        # greatest open index is forced out -- both clauses are normative, so two ports cannot
        # disagree.
        def self.certify(cp, initial_pairs, quotes_data, skip_sets, idioms, clitics)
          accepted = initial_pairs.dup
          # Each round accepts or strictly shrinks `accepted`; it is finite and the empty set
          # accepts unconditionally, so the loop runs at most |A0| + 1 times (quotes.md 3.5). The
          # bound below is a defensive safety net, not a normative one.
          max_rounds = initial_pairs.length + 2

          (0..max_rounds).each do
            return accepted if accepted.empty?

            plan = compute_render_plan(cp, accepted, quotes_data)
            y, m = apply_render_plan(cp, plan)
            rederived = pair_candidates(y, collect_candidates(y, skip_sets, idioms, clitics))

            b_set = Set.new(rederived)
            projected = accepted.map { |p| Pair.new(m[p.open], m[p.close]) }
            proj_set = Set.new(projected)

            return accepted if proj_set == b_set

            survivors = []
            accepted.each_with_index do |p, idx|
              survivors << p if b_set.include?(projected[idx])
            end

            if survivors.length == accepted.length
              remove_idx = 0
              (1...accepted.length).each do |i|
                remove_idx = i if accepted[i].open > accepted[remove_idx].open
              end
              accepted = accepted[0...remove_idx] + accepted[(remove_idx + 1)..]
            else
              accepted = survivors
            end
          end

          # Unreachable given the termination argument; declines everything rather than looping.
          []
        end

        # emit is pass 5 (quotes.md 3.6). An edit whose replacement equals the span it replaces is
        # never emitted -- the invisible-edit principle, applied per mark, not per pair. Hash
        # iteration order is never relied on: both replacement and deletion indices are sorted
        # before edits are built (ARCHITECTURE.md 4.5).
        def self.emit(cp, accepted, quotes_data)
          plan = compute_render_plan(cp, accepted, quotes_data)
          edits = []

          plan[:replace].keys.sort.each do |idx|
            new_cp = plan[:replace][idx]
            next if cp[idx] == new_cp

            edits << Engine::Edit.new(idx, idx + 1, [new_cp], "quotes")
          end

          del_idx = plan[:del].keys.sort
          i = 0
          while i < del_idx.length
            j = i
            j += 1 while j + 1 < del_idx.length && del_idx[j + 1] == del_idx[j] + 1
            edits << Engine::Edit.new(del_idx[i], del_idx[j] + 1, [], "quotes")
            i = j + 1
          end

          edits.sort_by(&:start)
        end

        def self.scan(cp, locale_data, _ctx)
          quotes_data = locale_data["quotes"]
          idioms = quotes_data["elisionIdioms"] || []
          clitics = quotes_data["elisionClitics"] || {}
          skip_sets = compute_skip_sets(quotes_data)

          candidates = collect_candidates(cp, skip_sets, idioms, clitics)
          return [] if candidates.empty?

          initial_pairs = pair_candidates(cp, candidates)
          return [] if initial_pairs.empty?

          accepted = certify(cp, initial_pairs, quotes_data, skip_sets, idioms, clitics)
          return [] if accepted.empty?

          emit(cp, accepted, quotes_data)
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "quotes",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::Quotes.scan(cp, locale_data, ctx) }
)

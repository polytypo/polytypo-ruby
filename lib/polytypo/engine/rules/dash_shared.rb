# frozen_string_literal: true

require_relative "../sentinels"

module Polytypo
  module Engine
    module Rules
      # Structural primitives shared by `dashes` (spec/rules/dashes.md, order 30) and `ranges`
      # (spec/rules/ranges.md, order 25). Both rules scan the same DASH-token shape and share the
      # same symmetry/isolation/cluster/joiner guards (dashes.md 3.2, 3.2a, 3.2b) -- this module is
      # the single source of truth for that shared machinery, mirroring the JS reference
      # implementation's dash-shared.ts, the Python port's _dash_shared.py and the Go port's
      # dash_shared.go. Each rule adds only its own branch-specific guards (P1/P4/P5 for `dashes`;
      # G1-G5 for `ranges`) and its own locale style (`dash.parenthetical` vs `dash.range`) on top
      # of what `find_tokens` returns.
      #
      # Not a registered rule itself -- an internal helper module for the two rules that are.
      module DashShared
        HYPHEN_MINUS = 0x2d
        HYPHEN = 0x2010
        FIGURE_DASH = 0x2012
        EN_DASH = 0x2013
        EM_DASH = 0x2014
        HORIZONTAL_BAR = 0x2015
        MINUS_SIGN = 0x2212
        SOFT_HYPHEN = 0x00ad
        NON_BREAKING_HYPHEN = 0x2011
        SMALL_EM_DASH = 0xfe58
        SMALL_HYPHEN_MINUS = 0xfe63
        FULLWIDTH_HYPHEN_MINUS = 0xff0d

        SPACE = 0x20
        NO_BREAK_SPACE = 0x00a0
        NARROW_NO_BREAK_SPACE = 0x202f

        DIGIT_ZERO = 0x30
        DIGIT_NINE = 0x39

        LF = 0x0a
        CR = 0x0d
        VT = 0x0b
        FF = 0x0c
        NEL = 0x85
        LS = 0x2028
        PS = 0x2029

        # dashes.md 3.1 JOINER: U+2060, emitted only around a tight range dash (ranges.md 3.3.1).
        WORD_JOINER = 0x2060

        COMMA = 0x2c
        FULL_STOP = 0x2e
        SEMICOLON = 0x3b
        COLON = 0x3a
        EXCLAMATION = 0x21
        QUESTION = 0x3f
        ELLIPSIS_CHAR = 0x2026

        PAREN_OPEN = 0x28
        PAREN_CLOSE = 0x29
        SQUARE_OPEN = 0x5b
        SQUARE_CLOSE = 0x5d
        CURLY_OPEN = 0x7b
        CURLY_CLOSE = 0x7d

        # One shared dash-token shape returned by find_tokens (dashes.md 3.2, 3.2a).
        DashToken = Struct.new(
          :s, :e,           # the DASH run itself, in input-array indices [s, e)
          :lsp, :rsp,        # outer spacing (0 or 1 U+0020 on each side)
          :left, :right,     # indices immediately outside the token's content, after the joiner
          # walk (dashes.md 3.2a) -- L*/R* in the spec
          :left_cp, :right_cp,
          :span_start, :span_end, # full edit span, including outer spacing and any crossed joiner
          :crossed_joiner,
          keyword_init: true
        )

        module_function

        # dashes.md 3.1 DASH.
        def dash?(cp)
          cp == HYPHEN_MINUS || cp == HYPHEN || cp == EN_DASH || cp == EM_DASH || cp == MINUS_SIGN
        end

        # dashes.md 3.1 INERT-DASH: never a candidate, never produced, by either rule.
        def inert_dash?(cp)
          cp == SOFT_HYPHEN || cp == FIGURE_DASH || cp == NON_BREAKING_HYPHEN ||
            cp == HORIZONTAL_BAR || cp == SMALL_EM_DASH || cp == SMALL_HYPHEN_MINUS ||
            cp == FULLWIDTH_HYPHEN_MINUS
        end

        # DASH union INERT-DASH -- the alphabet G2 and T1 read as "a dash".
        def dash_union?(cp)
          dash?(cp) || inert_dash?(cp)
        end

        # dashes.md 3.1 DIGIT: ASCII only, deliberately -- see ranges.md 7.1.
        def digit?(cp)
          cp >= DIGIT_ZERO && cp <= DIGIT_NINE
        end

        # BREAK, including Engine::LINE_MARKER: a member of BREAK for every rule everywhere
        # (modes.md 3.2).
        def break?(cp)
          cp == LF || cp == CR || cp == VT || cp == FF || cp == NEL || cp == LS || cp == PS ||
            cp == Polytypo::Engine::LINE_MARKER
        end

        def no_break_space?(cp)
          cp == NO_BREAK_SPACE || cp == NARROW_NO_BREAK_SPACE
        end

        # Whether a dash.parenthetical/dash.range value is one of the two "-spaced" forms.
        def spaced_style?(style)
          style == "em-spaced" || style == "en-spaced"
        end

        # The target dash glyph for a style value.
        def dash_code_point(style)
          style == "em-tight" || style == "em-spaced" ? EM_DASH : EN_DASH
        end

        # Whether cp[start...end] is exactly `next`, code point for code point.
        def same_content?(cp, start, stop, next_cp)
          return false if stop - start != next_cp.length

          next_cp.each_with_index { |want, i| return false if cp[start + i] != want }
          true
        end

        # dashes.md 3.6: every replacement is built from U+0020 alone plus the target dash glyph.
        # `bind` is meaningful only for `ranges` (ranges.md 3.3.1) -- `dashes`' parenthetical
        # branch always calls this with bind=false, since a parenthetical dash never binds (an
        # interrupting dash is exactly where a line may break).
        def build_replacement(style, bind)
          unless spaced_style?(style)
            return [WORD_JOINER, dash_code_point(style), WORD_JOINER] if bind

            return [dash_code_point(style)]
          end
          [SPACE, dash_code_point(style), SPACE]
        end

        # dashes.md 3.2 step 9 (T2)'s own set union CLOSE-BRACKET -- the positions from which
        # `spaces` (order 10) deletes a U+0020, plus U+2026 (T2's set is a strict superset of
        # `spaces`' STRIP-BEFORE by exactly that one code point -- dashes.md 3.2 step 9's own
        # note).
        def strip_before_or_close_bracket?(cp)
          cp == COMMA || cp == FULL_STOP || cp == SEMICOLON || cp == COLON || cp == EXCLAMATION ||
            cp == QUESTION || cp == ELLIPSIS_CHAR ||
            cp == PAREN_CLOSE || cp == SQUARE_CLOSE || cp == CURLY_CLOSE
        end

        # T2's OPEN-BRACKET set.
        def open_bracket?(cp)
          cp == PAREN_OPEN || cp == SQUARE_OPEN || cp == CURLY_OPEN
        end

        # dashes.md 3.2 step 7's cluster alphabet: DASH union INERT-DASH union DIGIT union
        # JOINER (a joiner `ranges` emitted on an earlier pass must not split a cluster it sits
        # inside -- 3.2b).
        def cluster_member?(cp)
          dash?(cp) || inert_dash?(cp) || digit?(cp) || cp == WORD_JOINER
        end

        # dashes.md 3.2 step 7 -- the cluster guard. A maximal span of cluster members containing
        # this run is inert (declines every token in it) if it holds two or more maximal
        # DASH-union-INERT-DASH runs.
        def cluster_inert?(cp, s, e)
          n = cp.length
          start = s
          start -= 1 while start.positive? && cluster_member?(cp[start - 1])
          stop = e
          stop += 1 while stop < n && cluster_member?(cp[stop])

          runs = 0
          i = start
          while i < stop
            unless dash_union?(cp[i])
              i += 1
              next
            end
            runs += 1
            return true if runs >= 2

            i += 1 while i < stop && dash_union?(cp[i])
          end
          false
        end

        # dashes.md 3.2b's "effective neighbour" walk: step from `from` in `step` direction
        # (+1/-1) across a maximal run of JOINER, returning the resulting index, or nil if the
        # walk leaves the array.
        def effective_index(cp, from, step)
          n = cp.length
          i = from
          i += step while i >= 0 && i < n && cp[i] == WORD_JOINER
          return nil if i.negative? || i >= n

          i
        end

        # effective_index's code point, or Engine::NONE if the walk leaves the array.
        def effective_neighbour(cp, from, step)
          i = effective_index(cp, from, step)
          return Polytypo::Engine::NONE if i.nil?

          cp[i]
        end

        # dashes.md 3.2 step 8 (T1) -- the spacing-transition guard. A tight token must not become
        # spaced when doing so would insert a U+0020 between itself and a digit run that has
        # another dash on its far side, read through effective neighbours (3.2b). Shared because a
        # `dashes` token becoming spaced can insert a space next to a `ranges` token's digit run,
        # and vice versa.
        def spacing_transition_blocked?(cp, left, right)
          n = cp.length

          if left >= 0 && left < n && digit?(cp[left])
            d = left
            d -= 1 while d.positive? && digit?(cp[d - 1])
            i1 = effective_index(cp, d - 1, -1)
            one = i1.nil? ? Polytypo::Engine::NONE : cp[i1]
            two = i1.nil? ? Polytypo::Engine::NONE : effective_neighbour(cp, i1 - 1, -1)
            return true if dash_union?(one)
            return true if (one == SPACE || no_break_space?(one)) && dash_union?(two)
          end

          if right >= 0 && right < n && digit?(cp[right])
            d = right
            d += 1 while d + 1 < n && digit?(cp[d + 1])
            i1 = effective_index(cp, d + 1, 1)
            one = i1.nil? ? Polytypo::Engine::NONE : cp[i1]
            two = i1.nil? ? Polytypo::Engine::NONE : effective_neighbour(cp, i1 + 1, 1)
            return true if dash_union?(one)
            return true if (one == SPACE || no_break_space?(one)) && dash_union?(two)
          end

          false
        end

        # dashes.md 3.2 steps 1-7 and 3.2a, exactly as they read before the `ranges` split -- the
        # common prefix every DASH-run token must pass before either rule's own branch-specific
        # guards run. Returns every token that survives symmetry, content, joiner-crossing,
        # isolation and cluster guards; each rule then filters to the tokens it owns:
        #
        #   - `ranges` only ever processes a token whose left_cp/right_cp are both DIGIT.
        #   - `dashes` must decline every such token unconditionally (operator decision, spec
        #     0.5.0) -- never reinterpreting a digit-flanked stroke as a parenthetical dash,
        #     regardless of whether `ranges` is enabled.
        #
        # A token with crossed_joiner=true and non-digit flanks is NOT returned at all (declined
        # inline, exactly as dashes.md 3.2a specifies: "if a joiner was crossed in any other
        # configuration, emit nothing") -- a joiner is `ranges`' own emission alphabet, and an
        # author who types one next to a dash meant it, exactly as with INERT-DASH.
        #
        # Sequencing is load-bearing and must not be reordered: (1) the symmetry guard runs first;
        # (2) the array-bounds check on the raw L/R runs next; (3) the joiner walk (3.2a) runs
        # immediately after that, extending across any adjacent WORD_JOINER run, bounds-checked
        # again; (4) the crossed-joiner test is evaluated against the POST-WALK left_cp/right_cp;
        # (5) the BREAK check reads the POST-WALK neighbours too; (6) the isolation guard; then
        # (7) the cluster guard. Evaluating BREAK/isolation/cluster before the joiner walk is a
        # known bug class (it diverged from the JS reference implementation during an earlier port
        # and had to be fixed): a joiner-adjacent BREAK or space-like character must be read past
        # the joiner, not at it.
        def find_tokens(cp)
          n = cp.length
          tokens = []
          i = 0

          while i < n
            unless dash?(cp[i])
              i += 1
              next
            end

            s = i
            e = s
            e += 1 while e < n && dash?(cp[e])
            i = e

            # dashes.md 3.2 step 2 -- a run longer than three is decoration, not a dash.
            next if e - s > 3

            lsp = s.positive? && cp[s - 1] == SPACE ? 1 : 0
            rsp = e < n && cp[e] == SPACE ? 1 : 0

            # dashes.md 3.2 step 4 -- symmetry guard.
            next if lsp != rsp

            # dashes.md 3.2 step 5 -- content on both sides (array-bounds half; BREAK is checked
            # below, after the joiner walk, against the post-walk neighbour).
            left = s - 1 - lsp
            right = e + rsp
            next if left.negative? || right >= n

            # dashes.md 3.2a -- joiner neighbours. This walk, and everything that reads its
            # result, must run before the BREAK/isolation/cluster guards below: those guards read
            # the effective (post-walk) neighbour, not the raw one.
            join_start = left + 1
            join_end = right
            left -= 1 while left >= 0 && cp[left] == WORD_JOINER
            right += 1 while right < n && cp[right] == WORD_JOINER
            next if left.negative? || right >= n

            crossed_joiner = (left + 1 != join_start) || (right != join_end)
            join_start = left + 1
            join_end = right

            left_cp = cp[left]
            right_cp = cp[right]

            next if crossed_joiner && !(digit?(left_cp) && digit?(right_cp))
            next if break?(left_cp) || break?(right_cp)

            # dashes.md 3.2 step 6 -- isolation guard.
            next if inert_dash?(left_cp) || inert_dash?(right_cp)
            next if dash?(left_cp) || dash?(right_cp)
            next if left_cp == SPACE || no_break_space?(left_cp)
            next if right_cp == SPACE || no_break_space?(right_cp)

            # dashes.md 3.2 step 7 -- cluster guard.
            next if cluster_inert?(cp, s, e)

            span_start = [s - lsp, join_start].min
            span_end = [e + rsp, join_end].max

            tokens << DashToken.new(
              s: s, e: e,
              lsp: lsp, rsp: rsp,
              left: left, right: right,
              left_cp: left_cp, right_cp: right_cp,
              span_start: span_start, span_end: span_end,
              crossed_joiner: crossed_joiner
            )
          end

          tokens
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../edits"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../registry"
require_relative "../../errors"

module Polytypo
  module Engine
    module Rules
      # `nbsp` -- spec/rules/nbsp.md (spec 1.2.0), order 70 (last).
      #
      # Ten sub-rules, N1 through N10, evaluated in that fixed order (3.2); each produces
      # candidate edits keyed by the index of the space (or insertion point) it claims, and the
      # first sub-rule to claim an index wins. The claims table is a positional array indexed
      # 0..cp.length, never a Hash -- a map-iteration implementation would resolve conflicts
      # differently in Go (ARCHITECTURE.md section 4.5). No regex, no native-string indexing
      # (ARCHITECTURE.md section 4.1, 4.2).
      module Nbsp
        SPACE = 0x20
        TAB = 0x09
        NBSP = 0xA0
        NNBSP = 0x202F
        FULL_STOP = 0x2E

        DIGIT_ZERO = 0x30
        DIGIT_NINE = 0x39

        PAREN_OPEN = 0x28
        SQUARE_OPEN = 0x5B
        BRACE_OPEN = 0x7B
        PAREN_CLOSE = 0x29
        SQUARE_CLOSE = 0x5D
        BRACE_CLOSE = 0x7D

        EN_DASH = 0x2013
        EM_DASH = 0x2014
        ELLIPSIS = 0x2026

        # cp[i], or NONE if i is out of bounds -- the spec's own boundary value.
        def self.at(cp, i)
          return NONE if i.negative? || i >= cp.length

          cp[i]
        end

        def self.digit?(cp)
          cp >= DIGIT_ZERO && cp <= DIGIT_NINE
        end

        def self.alnum?(cp)
          digit?(cp) || UnicodeUtil.letter?(cp)
        end

        # BREAK (nbsp.md 3.1), including LINE_MARKER -- a member of BREAK for every rule,
        # everywhere (modes.md 3.2). MARKER is not a member of BREAK; see closeish? below.
        def self.break?(cp)
          cp == 0x0A || cp == 0x0D || cp == 0x0B || cp == 0x0C || cp == 0x85 ||
            cp == 0x2028 || cp == 0x2029 || cp == LINE_MARKER
        end

        def self.no_break?(cp)
          cp == NBSP || cp == NNBSP
        end

        # OTHER-SPACE (nbsp.md 3.1): the fixed-width spaces. A member of SPACELIKE for boundary
        # purposes, but never converted and never an "already correct" state -- a thin or
        # figure space the author placed stays exactly where it is.
        def self.other_space?(cp)
          (cp >= 0x2000 && cp <= 0x200A) || cp == 0x205F || cp == 0x3000
        end

        # SPACELIKE, with NOBREAK included. Every boundary test in this rule uses this
        # predicate and never U+0020 alone; that single decision is what makes the rule
        # idempotent (nbsp.md 3.1).
        def self.space_like?(cp)
          cp == SPACE || no_break?(cp) || cp == TAB || other_space?(cp) || break?(cp)
        end

        # SENTENCE-DASH (nbsp.md 3.1): U+2013 and U+2014 only, never a hyphen. A hyphen marks
        # an intra-word position by construction, so the token after it is not a free-standing
        # word -- without this exclusion "из-за дождя" would bind twice over, once by `hyphen`
        # producing "из-за" and once by N3 reading the compound's tail "за" as a listed
        # preposition (nbsp.md 3.5 step 2). An em or en dash does open a phrase, so
        # "-- в Москве" still binds.
        def self.sentence_dash?(cp)
          cp == EN_DASH || cp == EM_DASH
        end

        # One locale quote pair N8 owns: the open/close glyphs and the no-break space (or
        # narrow no-break space) that belongs on their inner side.
        QuoteTarget = Struct.new(:open, :close, :target)

        # Locale data resolved to code points once per call. No module-level mutable state
        # (ARCHITECTURE.md section 7): everything here is local to one scan call.
        Prepared = Struct.new(
          :before_punctuation, :narrow_before_punctuation, :short_words, :abbreviations,
          :units, :before_number, :before_word, :symbols, :initial_binding, :opens, :closes,
          :quote_pairs,
          keyword_init: true,
        )

        def self.malformed(message)
          raise Polytypo::Error.new(Polytypo::CODE_MALFORMED_LOCALE_DATA, message)
        end
        private_class_method :malformed

        def self.single_code_point(entry, field)
          cps = entry.codepoints
          malformed("nbsp.#{field} entry #{entry.inspect} is not exactly one code point.") if cps.length != 1
          cps[0]
        end

        # Longest first, so each sub-rule's "longest match wins at a given a" (nbsp.md 3.5) is
        # a linear search that returns on the first match.
        def self.prepare_list(entries)
          entries.map(&:codepoints).sort_by { |cps| -cps.length }
        end

        # Resolves the locale's nbsp and quotes fields to code points once. nbsp.md 2 lists the
        # fields; 2.1 explains why the mechanism (U+00A0 vs U+202F, convert-only vs insert)
        # lives here and not in the locale file.
        def self.prepare(locale_data)
          data = locale_data["nbsp"]
          before_punctuation = data["beforePunctuation"].map { |e| single_code_point(e, "beforePunctuation") }
          narrow_before_punctuation =
            data["narrowBeforePunctuation"].map { |e| single_code_point(e, "narrowBeforePunctuation") }

          # nbsp.md 2 precondition: the two arrays must be disjoint. locale.schema.json does
          # not enforce this; an implementation that finds a code point in both must raise
          # POLYTYPO_MALFORMED_LOCALE_DATA rather than pick a winner silently.
          before_punctuation.each do |cp|
            next unless narrow_before_punctuation.include?(cp)

            malformed(
              format(
                "nbsp.beforePunctuation and nbsp.narrowBeforePunctuation both list U+%04X; " \
                "they must be disjoint (spec/rules/nbsp.md section 2).",
                cp,
              ),
            )
          end

          quotes = locale_data["quotes"]
          primary = quotes["primary"]
          secondary = quotes["secondary"]
          opens = [
            PAREN_OPEN, SQUARE_OPEN, BRACE_OPEN,
            single_code_point(primary["open"], "quotes.primary.open"),
            single_code_point(secondary["open"], "quotes.secondary.open"),
          ]
          closes = [
            PAREN_CLOSE, SQUARE_CLOSE, BRACE_CLOSE,
            single_code_point(primary["close"], "quotes.primary.close"),
            single_code_point(secondary["close"], "quotes.secondary.close"),
          ]

          quote_pairs = []
          [primary, secondary].each do |pair|
            next if pair["innerSpace"] == "none"

            open_cp = single_code_point(pair["open"], "quotes.open")
            close_cp = single_code_point(pair["close"], "quotes.close")
            # 3.10 sidedness precondition: an open glyph equal to its close glyph cannot be
            # told apart without the pairing information only `quotes` has. Documented no-op
            # (7.5).
            next if open_cp == close_cp

            target = pair["innerSpace"] == "nbsp" ? NBSP : NNBSP
            quote_pairs << QuoteTarget.new(open_cp, close_cp, target)
          end

          Prepared.new(
            before_punctuation: before_punctuation,
            narrow_before_punctuation: narrow_before_punctuation,
            short_words: prepare_list(data["afterShortWords"]),
            abbreviations: prepare_list(data["abbreviations"]),
            units: prepare_list(data["beforeUnits"]),
            before_number: prepare_list(data["beforeNumber"]),
            before_word: prepare_list(data["beforeWord"]),
            symbols: prepare_list(data["afterSymbols"]),
            initial_binding: data["initialBinding"],
            opens: opens,
            closes: closes,
            quote_pairs: quote_pairs,
          )
        end

        # OPENISH / CLOSEISH (nbsp.md 3.1): the ASCII brackets plus every locale quote glyph.
        #
        # Since spec 1.2.0 the span boundary MARKER is a member of CLOSEISH and not of OPENISH
        # (nbsp.md 3.1 and 7 item 12, modes.md 3.3). CLOSEISH is read only by N1/N2's right-context
        # guard, where membership lets French `<strong>gel :</strong>` keep its no-break space
        # after `spaces` deletes the U+0020. OPENISH stays marker-free: with the marker in it,
        # N1/N2's quote-glyph guard would decline `<em>non</em> ! Oui`, and the left-boundary
        # tests of N3, N7, N9, N10 would widen at span edges.
        def self.openish?(prep, cp)
          prep.opens.include?(cp)
        end

        def self.closeish?(prep, cp)
          cp == MARKER || prep.closes.include?(cp)
        end

        def self.mark?(prep, cp)
          prep.before_punctuation.include?(cp) || prep.narrow_before_punctuation.include?(cp)
        end

        # The only writers into the claims table. Both no-op if the index is already claimed,
        # which is what makes sub-rule evaluation order equal first-claim-wins (nbsp.md 3.2).
        def self.claim_conversion(claims, index, target)
          return unless claims[index].nil?

          claims[index] = Edit.new(index, index + 1, [target], "nbsp")
        end

        def self.claim_insertion(claims, index, target)
          return unless claims[index].nil?

          claims[index] = Edit.new(index, index, [target], "nbsp")
        end

        def self.match_exact?(cp, a, w)
          return false if a + w.length > cp.length

          w.each_with_index { |want, j| return false if cp[a + j] != want }
          true
        end

        # nbsp.md 3.5 step 1: exact except that the pattern's first code point may also match
        # its Unicode simple uppercase mapping -- a plain code-point-to-code-point table, never
        # a locale-sensitive case operation (ARCHITECTURE.md section 4.4).
        def self.match_first_char_lenient?(cp, a, w)
          return false if w.empty? || a + w.length > cp.length

          head = cp[a]
          first = w[0]
          return false if head != first && head != UnicodeUtil.simple_uppercase(first)

          (1...w.length).each { |j| return false if cp[a + j] != w[j] }
          true
        end

        # nbsp.md 3.6 step 1: exact except that a pattern U+0020 also matches an existing
        # U+00A0 or U+202F in the input, so a previously-converted abbreviation still matches
        # on a later run (the idempotency property nbsp.md 5 item 2 requires of N4).
        def self.match_space_lenient?(cp, a, w)
          return false if a + w.length > cp.length

          w.each_with_index do |want, j|
            got = cp[a + j]
            next if got == want
            next if want == SPACE && no_break?(got)

            return false
          end
          true
        end

        # Returns the first pattern (from a longest-first-sorted list) that matches at a,
        # implementing "longest match wins at a given a, with no backtracking" (nbsp.md 3.5)
        # for every list-driven sub-rule: N3, N4, N5, N6, N9, N10.
        def self.longest_match(patterns, cp, a, matcher)
          patterns.each do |w|
            return w if matcher.call(cp, a, w)
          end
          nil
        end

        # N1 (3.3, beforePunctuation -> U+00A0) and N2 (3.4, narrowBeforePunctuation ->
        # U+202F): identical shape with target/other exchanged.
        def self.punctuation_sub_rule(cp, prep, claims, marks, target, other)
          return if marks.empty?

          (0...cp.length).each do |i|
            next unless marks.include?(cp[i])

            left = at(cp, i - 1)
            # Step 1 -- run guard: only the first mark of "?!" or "!!!" takes the space.
            next if left != NONE && mark?(prep, left)

            # Step 2 -- right-context guard: this is what protects "http://" and "12:30".
            # U+2026 is accepted because the guard exists to catch punctuation *inside a
            # token*, and an ellipsis after a question mark is not that (nbsp.md 3.3 step 2).
            after = at(cp, i + 1)
            if after != NONE && !space_like?(after) && !closeish?(prep, after) &&
               after != ELLIPSIS && !mark?(prep, after)
              next
            end

            # Step 3 -- quote-glyph guard. The space beside an opening quotation glyph is
            # quotes.innerSpace and belongs to N8 alone; without this N2 and N8 alternate for
            # ever on the French input "«?" (3.2, 3.10.1).
            next if openish?(prep, left)
            next if left != NONE && space_like?(left) && openish?(prep, at(cp, i - 2))

            # Step 4.
            next if left == target

            if left == SPACE || left == other
              claim_conversion(claims, i - 1, target)
              next
            end
            # A fixed-width space stays as typed, and nothing is inserted beside it.
            next if other_space?(left)
            next if left == NONE || break?(left) || left == TAB

            claim_insertion(claims, i, target)
          end
        end

        # N3 -- nbsp.md 3.5 afterShortWords.
        def self.short_words_sub_rule(cp, prep, claims)
          return if prep.short_words.empty?

          (0...cp.length).each do |a|
            w = longest_match(prep.short_words, cp, a, method(:match_first_char_lenient?))
            next if w.nil?

            k = w.length
            before = at(cp, a - 1)
            unless before == NONE || space_like?(before) || openish?(prep, before) ||
                   sentence_dash?(before)
              next
            end

            separator = at(cp, a + k)
            next if separator == NBSP # already correct
            next if separator != SPACE

            following = at(cp, a + k + 1)
            next unless alnum?(following) || openish?(prep, following)

            claim_conversion(claims, a + k, NBSP)
          end
        end

        # N4 -- nbsp.md 3.6 abbreviations, U+00A0 for every internal space.
        def self.abbreviations_sub_rule(cp, prep, claims)
          return if prep.abbreviations.empty?

          (0...cp.length).each do |a|
            w = longest_match(prep.abbreviations, cp, a, method(:match_space_lenient?))
            next if w.nil?

            k = w.length
            next if alnum?(at(cp, a - 1))
            next if alnum?(at(cp, a + k))

            (0...k).each do |j|
              next unless w[j] == SPACE
              next if cp[a + j] == NBSP # already correct at this internal position

              claim_conversion(claims, a + j, NBSP)
            end
          end
        end

        # N5 -- nbsp.md 3.7 beforeUnits. Converts an existing space; never inserts one (7.2).
        def self.units_sub_rule(cp, prep, claims)
          return if prep.units.empty?

          (0...cp.length).each do |a|
            w = longest_match(prep.units, cp, a, method(:match_exact?))
            next if w.nil?

            k = w.length
            next if alnum?(at(cp, a + k))

            left = at(cp, a - 1)
            next if left == NBSP # already correct
            next if left != SPACE

            next unless digit?(at(cp, a - 2))

            b = a - 2
            b -= 1 while b - 1 >= 0 && digit?(cp[b - 1])
            # The letter guard: "H2 O", "A4", "MP3" are not measurements.
            next if UnicodeUtil.letter?(at(cp, b - 1))

            claim_conversion(claims, a - 1, NBSP)
          end
        end

        # N6 -- nbsp.md 3.8 afterSymbols. Conversion only.
        def self.symbols_sub_rule(cp, prep, claims)
          return if prep.symbols.empty?

          (0...cp.length).each do |a|
            w = longest_match(prep.symbols, cp, a, method(:match_exact?))
            next if w.nil?

            k = w.length
            next if alnum?(at(cp, a - 1))

            separator = at(cp, a + k)
            next if separator == NBSP # already correct
            next if separator != SPACE

            next unless digit?(at(cp, a + k + 1))

            claim_conversion(claims, a + k, NBSP)
          end
        end

        # nbsp.md 3.9: one uppercase letter, one full stop, at a token start.
        def self.initial_at?(cp, prep, p)
          return false if p.negative?
          return false unless UnicodeUtil.upper?(at(cp, p))
          return false if at(cp, p + 1) != FULL_STOP

          before = at(cp, p - 1)
          before == NONE || space_like?(before) || openish?(prep, before)
        end

        # Guard C1-a (nbsp.md 3.9): an uppercase letter plus a dot that is itself preceded by
        # a lower-case letter plus a dot is the second token of an abbreviation, not an
        # initial. Without it the shipped de-DE data turns "z. B. Berlin" into a form with
        # both the internal abbreviation space AND the space after "B." bound to U+00A0 -- a
        # false positive on ordinary prose ("z. B." is correct, "B. Berlin" is not a name).
        # "А. С. Пушкин" is unaffected: cp[p-3] there is uppercase.
        def self.abbreviation_tail?(cp, p)
          return false unless space_like?(at(cp, p - 1))
          return false if at(cp, p - 2) != FULL_STOP

          head = at(cp, p - 3)
          UnicodeUtil.letter?(head) && !UnicodeUtil.upper?(head)
        end

        # The "chain" mode confirmation (nbsp.md 3.9): is the initial whose letter sits at p
        # itself immediately preceded by another initial? Used only by "chain" mode's C1, to
        # require Chicago's own "two or more initials" before the space leading into a
        # following non-initial word (a candidate surname) is bound.
        def self.preceding_initial?(cp, prep, p)
          gap = at(cp, p - 1)
          return false unless gap == SPACE || gap == NBSP
          return false if at(cp, p - 2) != FULL_STOP

          initial_at?(cp, prep, p - 3)
        end

        # N7 -- nbsp.md 3.9 initialBinding, skipped entirely when the locale's initialBinding
        # is "none".
        def self.initials_sub_rule(cp, prep, claims)
          mode = prep.initial_binding
          return if mode == "none"

          (0...cp.length).each do |q|
            here = cp[q]
            next unless here == SPACE || here == NBSP

            # C1 -- an initial on the left and an uppercase letter on the right, unless C1-a
            # declines.
            left_initial_p = q - 2
            c1_shape = at(cp, q - 1) == FULL_STOP &&
                       initial_at?(cp, prep, left_initial_p) &&
                       UnicodeUtil.upper?(at(cp, q + 1)) &&
                       !abbreviation_tail?(cp, left_initial_p)
            # "chain" mode additionally requires either that the right side is itself an
            # initial (the between-initials case, e.g. "E.|B.", always safe) or that the left
            # initial is itself preceded by another initial (a confirmed chain of two or more,
            # e.g. "E. B.|White") before binding to a plain following word. "single" mode keeps
            # the unconditional shape check -- the behaviour fr/fr-CA need for
            # "N. Bourbaki"/"M. Dupont" (nbsp.md 3.9, Jacques Andre), structurally
            # indistinguishable from a sentence-boundary collision.
            c1 = c1_shape &&
                 (mode == "single" ||
                  initial_at?(cp, prep, q + 1) ||
                  preceding_initial?(cp, prep, left_initial_p))

            # C2 -- a word on the left and two consecutive initials on the right
            # ("Пушкин А. С."). Already requires two initials by construction, so it is
            # unaffected by "chain" vs "single".
            right_space = at(cp, q + 3)
            c2 = UnicodeUtil.letter?(at(cp, q - 1)) &&
                 initial_at?(cp, prep, q + 1) &&
                 (right_space == SPACE || right_space == NBSP) &&
                 initial_at?(cp, prep, q + 4)

            next unless c1 || c2
            next if here == NBSP # already correct

            claim_conversion(claims, q, NBSP)
          end
        end

        # N8 -- nbsp.md 3.10 quotes.innerSpace. The only sub-rule besides N1/N2 that may
        # insert.
        def self.quotes_sub_rule(cp, prep, claims)
          prep.quote_pairs.each do |pair|
            (0...cp.length).each do |i|
              here = cp[i]

              if here == pair.open
                right = at(cp, i + 1)
                if right == pair.target
                  # already correct
                elsif right == SPACE || no_break?(right)
                  claim_conversion(claims, i + 1, pair.target)
                elsif right == NONE || break?(right)
                  # skip: never insert at a line boundary or the end of the text
                else
                  claim_insertion(claims, i + 1, pair.target)
                end
                next
              end

              next unless here == pair.close

              left = at(cp, i - 1)
              if left == pair.target
                # already correct
              elsif left == SPACE || no_break?(left)
                claim_conversion(claims, i - 1, pair.target)
              elsif left == NONE || break?(left)
                # skip
              else
                claim_insertion(claims, i, pair.target)
              end
            end
          end
        end

        # N9 (nbsp.md 3.11, beforeNumber, wants_digit = true) and N10 (3.12, beforeWord,
        # wants_digit = false). They share every guard except what must follow the separator:
        # a digit for N9, a letter for N10.
        def self.forward_binding_sub_rule(cp, prep, claims, patterns, wants_digit)
          return if patterns.empty?

          (0...cp.length).each do |a|
            w = longest_match(patterns, cp, a, method(:match_exact?))
            next if w.nil?

            k = w.length

            # G-D (3.12 step 5, N10 only): in a locale where N7 is active, an *uppercase*
            # letter plus a dot is structurally an initial, and N7 owns that shape with better
            # evidence (it inspects what follows for a second initial or a surname). The UPPER
            # test is load-bearing: without it a lower-case entry such as "ул." would be inert
            # in an initialBinding-active locale.
            if !wants_digit && prep.initial_binding != "none" && k == 2 &&
               UnicodeUtil.upper?(w[0]) && w[1] == FULL_STOP
              next
            end

            # G-L -- stronger than "not ALNUM": it is what stops "S." matching inside
            # "Fig.S. 3". A hyphen fails it, per 3.5 step 2 -- an abbreviation cannot begin
            # immediately after an intra-word hyphen.
            before = at(cp, a - 1)
            unless before == NONE || space_like?(before) || openish?(prep, before) ||
                   sentence_dash?(before)
              next
            end

            # G-S -- exactly one separator, and it must already be a space.
            separator = at(cp, a + k)
            next if separator == NBSP # already correct
            next if separator != SPACE

            following = at(cp, a + k + 1)
            next if space_like?(following)

            # G-W / "a following number": one code point, tested for membership. NONE fails
            # both, which is also the line-boundary guard G-B.
            if wants_digit
              next unless digit?(following)
            else
              next unless UnicodeUtil.letter?(following)
            end

            claim_conversion(claims, a + k, NBSP)
          end
        end

        # nbsp.md 3.2: N1 through N10, in that fixed order, first claim wins. The order is
        # positional and total, never an artefact of Hash iteration.
        #
        # First-claim-wins only settles a conflict when both sub-rules actually emit an edit;
        # an "already correct" branch emits nothing and therefore claims nothing, silently
        # yielding the index to a lower-priority sub-rule. Sub-rules wanting *different* code
        # points at a shared index are therefore made disjoint by construction elsewhere
        # (N1/N2's quote-glyph guard, nbsp.md 3.10.1) rather than relying on ordering alone.
        def self.scan(cp, locale_data, _ctx)
          prep = prepare(locale_data)
          claims = Array.new(cp.length + 1)

          punctuation_sub_rule(cp, prep, claims, prep.before_punctuation, NBSP, NNBSP)       # N1
          punctuation_sub_rule(cp, prep, claims, prep.narrow_before_punctuation, NNBSP, NBSP) # N2
          short_words_sub_rule(cp, prep, claims)                                             # N3
          abbreviations_sub_rule(cp, prep, claims)                                           # N4
          units_sub_rule(cp, prep, claims)                                                   # N5
          symbols_sub_rule(cp, prep, claims)                                                 # N6
          initials_sub_rule(cp, prep, claims)                                                # N7
          quotes_sub_rule(cp, prep, claims)                                                  # N8
          forward_binding_sub_rule(cp, prep, claims, prep.before_number, true)                # N9
          forward_binding_sub_rule(cp, prep, claims, prep.before_word, false)                 # N10

          edits = []
          (0..cp.length).each do |i|
            edits << claims[i] unless claims[i].nil?
          end
          edits
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "nbsp",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::Nbsp.scan(cp, locale_data, ctx) },
)

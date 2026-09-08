# frozen_string_literal: true

require_relative "../edits"
require_relative "../registry"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../../errors"

module Polytypo
  module Engine
    module Rules
      # `hyphen` -- spec/rules/hyphen.md (spec 0.1.0), order 35.
      #
      # Replaces U+002D with U+2011 inside a closed list of locale-listed morphological forms
      # (hyphen.prefixes/suffixes/compounds). Explicit index-based scanning over the code-point
      # array only: no regex, no native-string indexing (docs/ARCHITECTURE.md section 4.1, 4.2).
      # All identifiers here live under Rules::Hyphen so they cannot collide with sibling rule
      # files in this same directory.
      module Hyphen
        HYPHEN_MINUS = 0x2D
        NON_BREAKING_HYPHEN = 0x2011
        DIGIT_ZERO = 0x30
        DIGIT_NINE = 0x39

        # 3.4: the three lists, in the order that breaks a length tie.
        COMPOUND = 0
        PREFIX = 1
        SUFFIX = 2

        # Out-of-range reads yield NONE, the spec's own boundary value (3.1).
        def self.at(cp, i)
          return Engine::NONE if i.negative? || i >= cp.length

          cp[i]
        end

        def self.digit?(cp)
          cp >= DIGIT_ZERO && cp <= DIGIT_NINE
        end

        # 3.1 HYPHENISH. U+2010, U+00AD, U+2012, U+2013, U+2014 are deliberately absent.
        def self.hyphenish?(cp)
          cp == HYPHEN_MINUS || cp == NON_BREAKING_HYPHEN
        end

        # 3.1 WORDISH = ALNUM u HYPHENISH. U+2011 is a member on purpose: without it a converted
        # hyphen would flip a neighbouring form's boundary verdict between runs (5).
        def self.wordish?(cp)
          digit?(cp) || UnicodeUtil.letter?(cp) || hyphenish?(cp)
        end

        Pattern = Struct.new(:cps, :kind)

        # Converts one locale word list into match patterns of the given kind. hyphen.md 2
        # requires every entry to contain at least one U+002D; an entry with none is meaningless
        # and raises POLYTYPO_MALFORMED_LOCALE_DATA directly -- Ruby exceptions propagate through
        # the call chain without the panic/recover workaround the Go port needs for the same case.
        def self.prepare_patterns(entries, field, kind, out)
          entries.each do |entry|
            cps = entry.codepoints
            has_hyphen = cps.any? { |cp| cp == HYPHEN_MINUS }
            unless has_hyphen
              raise Polytypo::Error.new(
                Polytypo::CODE_MALFORMED_LOCALE_DATA,
                "hyphen.#{field} entry #{entry.inspect} contains no U+002D; there is nothing " \
                "for the rule to convert (spec/rules/hyphen.md section 2).",
              )
            end
            out << Pattern.new(cps, kind)
          end
          out
        end

        # 3.3 -- hyphen-lenient, first-character-lenient literal matching. The hyphen leniency
        # covers j = 0 too, because a suffix entry begins with its own hyphen and must keep
        # matching its own output once that hyphen has already been converted to U+2011 (5's
        # idempotency argument depends on this). The first-character case leniency uses the
        # Unicode simple uppercase mapping of the *pattern*, never a locale-dependent case fold
        # of the input (ARCHITECTURE.md section 4.4).
        def self.matches_at?(cp, a, w)
          return false if a + w.length > cp.length

          w.each_with_index do |p, j|
            c = cp[a + j]
            if p == HYPHEN_MINUS
              return false unless hyphenish?(c)

              next
            end
            next if c == p
            next if j.zero? && UnicodeUtil.letter?(p) && c == UnicodeUtil.simple_uppercase(p)

            return false
          end
          true
        end

        # 3.4 -- the longest entry that matches at `a`, ties broken compounds, prefixes,
        # suffixes. `patterns` is built compounds-first, prefixes-second, suffixes-third, so
        # keeping the first-seen entry on a length tie already yields that order.
        def self.select(cp, a, patterns)
          best = nil
          patterns.each do |pattern|
            next unless matches_at?(cp, a, pattern.cps)

            best = pattern if best.nil? || pattern.cps.length > best.cps.length
          end
          best
        end

        # 3.4 C -- a compound must be a whole word.
        def self.guard_compound?(cp, a, k)
          before = at(cp, a - 1)
          return false if before != Engine::NONE && wordish?(before)

          after = at(cp, a + k)
          after == Engine::NONE || !wordish?(after)
        end

        # 3.4 P -- a prefix starts a word and must actually prefix something.
        def self.guard_prefix?(cp, a, k)
          before = at(cp, a - 1)
          return false if before != Engine::NONE && wordish?(before)

          UnicodeUtil.letter?(at(cp, a + k))
        end

        # 3.4 S -- a suffix must actually suffix something and must end the word.
        def self.guard_suffix?(cp, a, k)
          return false unless UnicodeUtil.letter?(at(cp, a - 1))

          after = at(cp, a + k)
          after == Engine::NONE || !wordish?(after)
        end

        def self.bind(index)
          Edit.new(index, index + 1, [NON_BREAKING_HYPHEN], "hyphen")
        end

        def self.scan(cp, locale_data, _ctx)
          hyphen = locale_data["hyphen"]
          prefixes = hyphen["prefixes"]
          suffixes = hyphen["suffixes"]
          compounds = hyphen["compounds"]

          # 2: with all three lists empty the rule emits nothing for any input -- the common
          # case for every v1 locale except ru.
          return [] if prefixes.empty? && suffixes.empty? && compounds.empty?

          patterns = []
          prepare_patterns(compounds, "compounds", COMPOUND, patterns)
          prepare_patterns(prefixes, "prefixes", PREFIX, patterns)
          prepare_patterns(suffixes, "suffixes", SUFFIX, patterns)

          n = cp.length
          edits = []
          a = 0
          while a < n
            selected = select(cp, a, patterns)
            if selected.nil?
              a += 1
              next
            end

            # 3.4: matching and guarding are separate steps, and there is no backtracking. A
            # guard failure ends the position; no shorter entry is tried at `a`.
            w = selected.cps
            k = w.length
            case selected.kind
            when COMPOUND
              unless guard_compound?(cp, a, k)
                a += 1
                next
              end
              w.each_with_index do |p, j|
                edits << bind(a + j) if p == HYPHEN_MINUS && cp[a + j] != NON_BREAKING_HYPHEN
              end
            when PREFIX
              unless guard_prefix?(cp, a, k)
                a += 1
                next
              end
              # The entry's own last code point is its hyphen (hyphen.md 2).
              if w[k - 1] == HYPHEN_MINUS && cp[a + k - 1] != NON_BREAKING_HYPHEN
                edits << bind(a + k - 1)
              end
            else # SUFFIX
              unless guard_suffix?(cp, a, k)
                a += 1
                next
              end
              # A suffix is matched at its own hyphen, which is its first code point.
              edits << bind(a) if w[0] == HYPHEN_MINUS && cp[a] != NON_BREAKING_HYPHEN
            end
            a += k
          end
          edits
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "hyphen",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::Hyphen.scan(cp, locale_data, ctx) },
)

# frozen_string_literal: true

require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../codepoints"

module Polytypo
  module Engine
    module Rules
      # Shared ambiguous-medial-span predicate -- spec/rules/quotes.md 3.2 ("Listed elision veto"
      # and "General ambiguous-medial-span veto") and spec/rules/apostrophe.md 3.4. One
      # definition, used identically by quotes.rb and apostrophe.rb, so the two rules cannot
      # drift apart on what counts as ambiguous (mirrors ref-js's src/rules/quote-ambiguity.ts,
      # the Python port's _quote_ambiguity.py and the Go port's quote_ambiguity.go).
      #
      # The shape (quotes.md 3.2, "General ambiguous-medial-span veto"): a pair of straight ASCII
      # single quotes (U+0027) enclosing 1-3 LETTER code points, with at least one INLINE-SPACE
      # code point immediately outside each mark -- `rock 'n' roll`, `She chose 'A' today`. Only
      # the single adjacent code point is tested on each side; a longer run of inline spaces
      # further out does not invalidate the match (quotes.md 3.2's "at least one, deliberately
      # not exactly one").
      #
      # Without a matching quotes.elisionIdioms entry, neither quotes nor apostrophe may touch
      # either mark: quotes must not pair them as an ordinary quotation, and apostrophe's own case
      # ladder (which would otherwise independently read the left mark as a leading elision and
      # the right one as a trailing possessive/elision, apostrophe.md 3.3 cases 3/4) must not
      # convert them either.
      module QuoteAmbiguity
        # LOWER_N / UPPER_N -- quotes.md 3.2's one enclosed code point, in either case.
        LOWER_N = 0x6E
        UPPER_N = 0x4E

        # NARROW -- quotes.md 3.1 NARROW -- every glyph an elision mark may appear as across
        # pipeline passes (straight, or already curled by an earlier pass). Shared with quotes.rb
        # so the two rules cannot define two slightly different NARROW sets. For the universal
        # medial-n veto, matching the whole class is an IDEMPOTENCY obligation rather than a
        # preference: its marks are converted to U+2019 by apostrophe, so a straight-ASCII-only
        # predicate would not recognise its own output and pass 2 would pair `rock ’n’ roll`
        # as an ordinary NARROW quotation on the next run.
        NARROW = [0x27, 0x2018, 0x2019, 0x201A, 0x201B, 0x2039, 0x203A].freeze

        # INLINE_SPACE -- quotes.md 3.1 INLINE-SPACE, deliberately excluding BREAK/MARKER/
        # LINE_MARKER so this shape never crosses a line or span boundary (modes.md 3.3) -- the
        # same anchor the elisionIdioms matcher already uses.
        INLINE_SPACE = [0x20, 0x09, 0xA0, 0x202F, 0x2007, 0x2009, 0x200A].freeze

        def self.narrow?(cp)
          NARROW.include?(cp)
        end

        def self.inline_space?(cp)
          INLINE_SPACE.include?(cp)
        end

        # at(cp, i) returns cp[i], or Engine::NONE if i is out of bounds -- the spec's own
        # boundary value.
        def self.at(cp, i)
          return Engine::NONE if i.negative? || i >= cp.length

          cp[i]
        end

        def self.alnum?(cp)
          (cp >= 0x30 && cp <= 0x39) || UnicodeUtil.letter?(cp)
        end

        # ascii_lower folds ASCII A-Z to a-z, ASCII-only -- the same convention nbsp's
        # afterShortWords and the existing idiom matcher already use (ARCHITECTURE.md 4.4: never
        # a platform locale case-fold).
        def self.ascii_lower(cp)
          cp >= 0x41 && cp <= 0x5A ? cp + 0x20 : cp
        end

        # elided_matches? compares cp[start, elided.length] against elided exactly, code point
        # for code point -- no case leniency, ever, on the elided content (quotes.md 3.2). A
        # MARKER/LINE_MARKER/NONE sentinel (a negative value, not a valid code point) is never
        # treated as if it could equal a real code point: every comparison here goes through
        # Codepoints.valid_codepoint? first, and this method never assembles the candidate span
        # into a Ruby String (no `.pack("U*")`, no `.chr`) -- comparison stays code point vs.
        # code point throughout. This is the exact defensive check the Python port needed after a
        # real crash (`ValueError: chr() arg not in range`) when a span straddling a span-
        # boundary marker was packed into a string and compared to a literal.
        def self.elided_matches?(cp, start, elided)
          elided.each_with_index do |want, w|
            c = at(cp, start + w)
            return false unless Codepoints.valid_codepoint?(c)
            return false unless c == want
          end
          true
        end

        # word_ends_at? reports whether the word.length code points immediately before index
        # `end_` (exclusive) match word exactly -- except the first code point, compared
        # ASCII-case-insensitively -- and have a legal outer (left) word boundary: NONE, or not
        # LETTER/DIGIT (quotes.md 3.2's Word definition). The caller has already verified the
        # code point at `end_` itself is a legal right-hand boundary (a single INLINE-SPACE code
        # point). Guarded against a marker exactly like elided_matches? above.
        def self.word_ends_at?(cp, end_, word)
          start = end_ - word.length
          return false if start.negative?

          word.each_with_index do |want, k|
            c = at(cp, start + k)
            return false unless Codepoints.valid_codepoint?(c)

            if k.zero?
              return false unless ascii_lower(c) == ascii_lower(want)
            else
              return false unless c == want
            end
          end
          before = at(cp, start - 1)
          before == Engine::NONE || !alnum?(before)
        end

        # word_starts_at? is word_ends_at?'s mirror image: word must start exactly at `start`,
        # first code point ASCII-case-insensitive, with a legal outer (right) word boundary
        # immediately after it.
        def self.word_starts_at?(cp, start, word)
          n = cp.length
          word.each_with_index do |want, k|
            c = at(cp, start + k)
            return false unless Codepoints.valid_codepoint?(c)

            if k.zero?
              return false unless ascii_lower(c) == ascii_lower(want)
            else
              return false unless c == want
            end
          end
          after = start + word.length
          return true if after >= n

          !alnum?(cp[after])
        end

        # compute_idiom_matched_indices is the listed elision veto (quotes.md 3.2, spec 0.4.0),
        # locale data quotes.elisionIdioms. Bounded literal scan for `left, NARROW, elided,
        # NARROW, right` (`rock 'n' roll`'s {left: "rock", elided: "n", right: "roll"}). Both
        # marks of a match are returned (as Hash keys, used as a set). Matches on NARROW quote
        # marks generally (U+0027 and already-curly U+2018/U+2019), not only straight ASCII --
        # required for quotes' own idempotency (an idiom must still veto pairing on a second
        # pipeline pass, after apostrophe has curled the marks).
        #
        # idioms is the locale's quotes.elisionIdioms array: a list of Hashes with String keys
        # "left"/"elided"/"right", each a literal String (locale.schema.json).
        def self.compute_idiom_matched_indices(cp, idioms)
          vetoed = {}
          return vetoed if idioms.nil? || idioms.empty?

          n = cp.length
          compiled = idioms.map do |idiom|
            {
              left: idiom["left"].codepoints,
              elided: idiom["elided"].codepoints,
              right: idiom["right"].codepoints
            }
          end

          (0...n).each do |i|
            g = cp[i]
            next unless narrow?(g)

            l_lit = at(cp, i - 1)
            next if l_lit == Engine::NONE || !inline_space?(l_lit)

            compiled.each do |idiom|
              k = idiom[:elided].length
              j = i + 1 + k
              next if j >= n
              next unless elided_matches?(cp, i + 1, idiom[:elided])
              next unless narrow?(cp[j])

              r_lit = at(cp, j + 1)
              next if r_lit == Engine::NONE || !inline_space?(r_lit)

              next unless word_ends_at?(cp, i - 1, idiom[:left])
              next unless word_starts_at?(cp, j + 2, idiom[:right])

              vetoed[i] = true
              vetoed[j] = true
            end
          end

          vetoed
        end

        # compute_ambiguous_shape_indices is the general ambiguous-medial-span shape,
        # locale-independent (quotes.md 3.2, spec 0.5.0): a pair of straight ASCII single quotes
        # (spec 1.1.0) a pair of NARROW marks enclosing exactly one code point, U+006E or
        # U+004E, with at least one INLINE-SPACE code point immediately outside each mark. Both
        # mark positions are returned for every match. A superset of
        # compute_idiom_matched_indices's output for every idiom whose elided field is a single
        # n (true of every idiom shipped so far), but computed independently rather than assumed,
        # since a future idiom's elided field is not required to be that short.
        def self.compute_ambiguous_shape_indices(cp)
          ambiguous = {}
          n = cp.length

          (0...n).each do |i|
            next unless narrow?(at(cp, i))

            l_lit = at(cp, i - 1)
            next if l_lit == Engine::NONE || !inline_space?(l_lit)

            enclosed = at(cp, i + 1)
            next unless [LOWER_N, UPPER_N].include?(enclosed)

            j = i + 2
            next unless narrow?(at(cp, j))

            r_lit = at(cp, j + 1)
            next if r_lit == Engine::NONE || !inline_space?(r_lit)

            ambiguous[i] = true
            ambiguous[j] = true
          end

          ambiguous
        end

      end
    end
  end
end

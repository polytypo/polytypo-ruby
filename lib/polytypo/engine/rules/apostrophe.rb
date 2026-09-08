# frozen_string_literal: true

require_relative "quote_ambiguity"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../edits"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # spec/rules/apostrophe.md (spec 0.5.0), order 50.
      #
      # Converts a straight U+0027 to U+2019 where it is genuinely an apostrophe: a contraction,
      # an elision, a possessive, or a decade elision. Runs immediately after `quotes` (order 40)
      # and sees only the U+0027 marks quotes declined to claim. Every edit is one code point
      # replacing one code point; the rule never inserts, never deletes, and never touches U+2019
      # itself.
      #
      # As of spec 0.5.0 this rule additionally skips a small, precisely-defined set of positions
      # entirely (apostrophe.md 3.4) -- the shared ambiguous-medial-span preserve set,
      # QuoteAmbiguity.compute_preserve_indices -- rather than applying its case ladder to them.
      module Apostrophe
        SQ = 0x27
        RIGHT_SINGLE = 0x2019

        # OPENISH is apostrophe.md 3.1 OPENISH. Unlike quotes.md's OPENISH, this is not "every
        # QUOTEMARK" -- only the specific opening-shaped glyphs the spec lists. Engine::MARKER is
        # a member (modes.md 3.3's table names this rule explicitly).
        OPENISH = [
          Engine::MARKER,
          0x28, 0x5B, 0x7B, 0xAB,
          0x2018, 0x201A, 0x201B, 0x201C, 0x201E, 0x201F, 0x2039,
          0x2D, 0x2011, 0x2013, 0x2014
        ].freeze

        # CLOSEISH is apostrophe.md 3.1 CLOSEISH. U+2019 is a member and U+0027 is a member of
        # neither this nor OPENISH -- apostrophe.md 5 turns exactly that asymmetry into the
        # idempotency argument. U+2011 sits beside U+002D because `hyphen` (order 35) converts one
        # to the other.
        CLOSEISH = [
          Engine::MARKER,
          0x29, 0x5D, 0x7D, 0xBB,
          0x2019, 0x201D, 0x203A,
          0x2C, 0x2E, 0x3B, 0x3A, 0x21, 0x3F, 0x2026,
          0x2D, 0x2011, 0x2013, 0x2014
        ].freeze

        BREAK = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029, Engine::LINE_MARKER].freeze

        # SPACELIKE, including Engine::LINE_MARKER as a member of BREAK for every rule everywhere
        # (modes.md 3.2).
        def self.spacelike?(cp)
          QuoteAmbiguity.inline_space?(cp) || BREAK.include?(cp)
        end

        def self.digit?(cp)
          cp >= 0x30 && cp <= 0x39
        end

        def self.alnum?(cp)
          digit?(cp) || UnicodeUtil.letter?(cp)
        end

        # apostrophe? is the case ladder of apostrophe.md 3.3, first match wins. Every verdict
        # is a pure function of exactly two neighbouring code points; there is no lookahead and no
        # state carried between candidates.
        def self.apostrophe?(left, right)
          # Case 1 -- prime guard, first so it wins over case 3: `6' 2"`, `55° 40' N`, `6'2"`. A
          # foot mark is not an apostrophe.
          return false if digit?(left) && !UnicodeUtil.letter?(right)

          # Case 2 -- medial apostrophe: `don't`, `l'été`, `O'Brien`, `1990's`.
          return true if alnum?(left) && alnum?(right)

          # Case 3 -- trailing elision or possessive: `the dogs' bowls`, `Jesus'`, `rock 'n'` (the
          # trailing mark).
          if left != Engine::NONE && UnicodeUtil.letter?(left) &&
             (right == Engine::NONE || spacelike?(right) || CLOSEISH.include?(right))
            return true
          end

          # Case 4 -- leading elision: `'90s`, `'tis`, `'em`, `'n'` (the leading mark). The
          # replacement is U+2019, never U+2018 -- a leading elision is a raised comma, not an
          # opening quotation mark, and `quotes` has already had its chance to claim the mark as a
          # quotation and declined (quotes.md 3.2, 5).
          if (left == Engine::NONE || spacelike?(left) || OPENISH.include?(left)) && alnum?(right)
            return true
          end

          # Case 5 -- nothing inferable: `a ' b`, `''`. Leave it.
          false
        end

        def self.scan(cp, locale_data, _ctx)
          n = cp.length
          # apostrophe.md 3.4, spec 0.5.0: positions in the shared ambiguous-medial-span preserve
          # set (an ambiguous shape with no cited elisionIdioms match) are skipped entirely,
          # before left/right are even read -- this rule's own case ladder would otherwise curl
          # both marks of e.g. `rock 'n' roll` independently and silently defeat quotes'
          # deliberate veto.
          idioms = (locale_data["quotes"] || {})["elisionIdioms"] || []
          preserve = QuoteAmbiguity.compute_preserve_indices(cp, idioms)

          edits = []
          (0...n).each do |i|
            next unless cp[i] == SQ
            next if preserve.key?(i)

            left = QuoteAmbiguity.at(cp, i - 1)
            right = QuoteAmbiguity.at(cp, i + 1)
            next unless apostrophe?(left, right)

            edits << Engine::Edit.new(i, i + 1, [RIGHT_SINGLE], "apostrophe")
          end

          edits
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "apostrophe",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::Apostrophe.scan(cp, locale_data, ctx) }
)

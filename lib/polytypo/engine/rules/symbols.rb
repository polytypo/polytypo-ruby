# frozen_string_literal: true

require_relative "../edits"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # `symbols` -- spec/rules/symbols.md (spec 0.1.0), order 60.
      #
      # Three unrelated substitutions, one left-to-right scan: `(c)`/`(r)`/`(tm)` literals
      # become (c)/(r)/(tm) signs (3.2); a `DIGIT+ (MUL-LETTER DIGIT+)+` chain becomes
      # multiplication signs, converted whole or not at all (3.3); the literal `+/-` becomes
      # plus-minus (3.4). No locale data -- order.json declares "localeData": [] for this rule.
      # No regex, no case folding anywhere (ARCHITECTURE.md section 4.1, 4.4): the accepted
      # spellings are enumerated explicitly rather than derived from `downcase`/`upcase`, which
      # are locale-dependent in the host process (Turkish dotless i).
      module Symbols
        PAREN_OPEN = 0x28
        PAREN_CLOSE = 0x29
        SQUARE_OPEN = 0x5B
        SQUARE_CLOSE = 0x5D

        COPYRIGHT = 0xA9
        REGISTERED = 0xAE
        TRADEMARK = 0x2122
        MULTIPLICATION = 0xD7

        SPACE = 0x20
        NBSP = 0xA0
        NNBSP = 0x202F

        LOWER_X = 0x78
        UPPER_X = 0x58
        CYRILLIC_LOWER_HA = 0x445
        CYRILLIC_UPPER_HA = 0x425
        DIGIT_ZERO = 0x30
        DIGIT_NINE = 0x39

        PLUS = 0x2B
        SOLIDUS = 0x2F
        HYPHEN_MINUS = 0x2D
        PLUS_MINUS = 0xB1

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

        # SPACE u NOBREAK-SPACE (symbols.md 3.1): U+0020, U+00A0, U+202F only -- no tabs, no
        # other Unicode spaces, no line breaks. Narrower than nbsp's SPACELIKE on purpose: this
        # rule only needs the spacing a multiplication chain can legally carry.
        def self.space_like?(cp)
          cp == SPACE || cp == NBSP || cp == NNBSP
        end

        # MUL-LETTER (symbols.md 3.1): exactly four code points, enumerated, never case-folded
        # and never derived from locale data. The Cyrillic pair is unconditional -- U+0445
        # between two ASCII digits is a Russian dimension typed on a Cyrillic layout or
        # keyboard-layout debris, and the glyphs are visually identical to the Latin ones in
        # every font, so no human review can catch a missed conversion.
        def self.mul_letter?(cp)
          cp == LOWER_X || cp == UPPER_X || cp == CYRILLIC_LOWER_HA || cp == CYRILLIC_UPPER_HA
        end

        # One row of the trademark table (symbols.md 3.1). guarded_by_s1 is true only for the
        # (c)/(r) rows -- the (tm) rows are exempt from S1 (3.2 step 3).
        TrademarkRow = Struct.new(:literal, :to, :guarded_by_s1)

        # Exhaustive and case-explicit; nothing else matches. Longest literals first (the
        # 4-code-point (tm) rows before the 3-code-point (c)/(r) rows), per 3.2 step 1.
        TRADEMARK_TABLE = [
          TrademarkRow.new([PAREN_OPEN, 0x74, 0x6D, PAREN_CLOSE], TRADEMARK, false), # (tm)
          TrademarkRow.new([PAREN_OPEN, 0x54, 0x4D, PAREN_CLOSE], TRADEMARK, false), # (TM)
          TrademarkRow.new([PAREN_OPEN, 0x54, 0x6D, PAREN_CLOSE], TRADEMARK, false), # (Tm)
          TrademarkRow.new([PAREN_OPEN, 0x74, 0x4D, PAREN_CLOSE], TRADEMARK, false), # (tM)
          TrademarkRow.new([PAREN_OPEN, 0x63, PAREN_CLOSE], COPYRIGHT, true),        # (c)
          TrademarkRow.new([PAREN_OPEN, 0x43, PAREN_CLOSE], COPYRIGHT, true),        # (C)
          TrademarkRow.new([PAREN_OPEN, 0x72, PAREN_CLOSE], REGISTERED, true),       # (r)
          TrademarkRow.new([PAREN_OPEN, 0x52, PAREN_CLOSE], REGISTERED, true),       # (R)
        ].freeze

        def self.matches_at?(cp, i, literal)
          return false if i + literal.length > cp.length

          literal.each_with_index { |want, j| return false if at(cp, i + j) != want }
          true
        end

        # symbols.md 3.2. Returns the Edit, or nil when no row matches or a guard rejects the
        # candidate.
        def self.trademark_at(cp, i)
          TRADEMARK_TABLE.each do |row|
            next unless matches_at?(cp, i, row.literal)

            end_index = i + row.literal.length
            before = at(cp, i - 1)
            after = at(cp, end_index)

            # S1 -- left adjacency, (c)/(r) rows only: a one-letter argument list ("f(c)") is
            # common, "(tm)" tucked against a product name is not a call. The three replacement
            # signs are listed so that "(c)(r)" converges to "(c)(r)" in one run (symbols.md 5).
            if row.guarded_by_s1 && before != NONE &&
               (alnum?(before) || before == PAREN_CLOSE || before == SQUARE_CLOSE ||
                before == COPYRIGHT || before == REGISTERED || before == TRADEMARK)
              return nil
            end
            # S2 -- right adjacency: "(r)evolution", "(c)ompiler".
            return nil if after != NONE && alnum?(after)
            # S3 -- no nesting: "((c))" is ASCII art or code.
            return nil if before == PAREN_OPEN

            return Edit.new(i, end_index, [row.to], "symbols")
          end
          nil
        end

        # One MUL-LETTER position within a multiplication chain, plus whether it carried a
        # space on each side (0 or 1 code point -- symbols.md 3.3 never allows more than one).
        ChainLink = Struct.new(:letter_index, :left_space, :right_space)

        # The result of reading a whole DIGIT+ (MUL-LETTER DIGIT+)+ shape starting at a maximal
        # digit run (symbols.md 3.3 step 1). end_index is the last code point read, whether or
        # not any link was completed -- the caller resumes scanning at end_index + 1 either way.
        # first_run_end is the last digit of the very first digit run, used only by guard M4.
        Chain = Struct.new(:end_index, :first_run_end, :links)

        # Reads the chain greedily and unconditionally; guard decisions happen afterward in
        # chain_edits, never here, so the scan shape itself cannot express "how many links
        # converted" -- only "whole chain or nothing" (symbols.md 3.3 step 2, 5).
        def self.read_chain(cp, a)
          p = a
          p += 1 while digit?(at(cp, p))
          first_run_end = p - 1
          end_index = p - 1
          links = []

          loop do
            q = p
            left_space = 0
            if space_like?(at(cp, q))
              left_space = 1
              q += 1
            end
            break unless mul_letter?(at(cp, q))

            letter_index = q
            q += 1
            right_space = 0
            if space_like?(at(cp, q))
              right_space = 1
              q += 1
            end
            break unless digit?(at(cp, q))

            q += 1 while digit?(at(cp, q))
            links << ChainLink.new(letter_index, left_space, right_space)
            end_index = q - 1
            p = q
          end

          Chain.new(end_index, first_run_end, links)
        end

        # Applies guards M1-M4 to a chain read by read_chain. Returns the edits, or nil when the
        # chain is declined whole -- symbols.md 3.3 never half-converts a chain.
        def self.chain_edits(cp, a, chain)
          links = chain.links
          first = links.first
          return nil if first.nil?

          # M1 -- every link symmetric, and every link agreeing with the first. "5x4 x 3" is
          # ambiguous input and is declined whole rather than half-converted.
          sp = first.left_space
          links.each do |link|
            return nil if link.left_space != link.right_space
            return nil if link.left_space != sp
          end

          # M2/M3 -- the chain's OUTER boundaries, not each link. Applying them per link is
          # exactly what made the pairwise form reject chains: the letter past the middle digit
          # run is itself a MUL-LETTER, hence a LETTER.
          before = at(cp, a - 1)
          after = at(cp, chain.end_index + 1)
          return nil if before != NONE && UnicodeUtil.letter?(before)
          return nil if after != NONE && UnicodeUtil.letter?(after)

          # M4 -- hexadecimal literal veto. Latin lowercase only: a hex literal is never
          # written with Cyrillic. Inspects the first link alone.
          if sp.zero? && at(cp, first.letter_index) == LOWER_X &&
             chain.first_run_end == a && at(cp, a) == DIGIT_ZERO
            return nil
          end

          # There is no M5. It was removed rather than extended (symbols.md 3.3 step 7, 7.3).
          edits = []
          links.each do |link|
            j = link.letter_index
            replacement =
              sp.zero? ? [MULTIPLICATION] : [at(cp, j - 1), MULTIPLICATION, at(cp, j + 1)]
            start_index = j - sp
            end_span = j + sp + 1
            next if replacement == cp[start_index...end_span]

            edits << Edit.new(start_index, end_span, replacement, "symbols")
          end
          edits
        end

        # symbols.md 3.4. Only the literal "+/-"; the bare "+-" is never converted, in any
        # context (3.4, 7.11).
        def self.plus_minus_at(cp, i)
          return nil if at(cp, i + 1) != SOLIDUS || at(cp, i + 2) != HYPHEN_MINUS

          # F1 -- not a character class: "[+/-]" is a regular expression.
          return nil if at(cp, i - 1) == SQUARE_OPEN

          # F2 -- numeric context, with one optional intervening space so "+/-5" and "+/- 5"
          # both work. Without it, prose that names the characters ("lines marked +/- were
          # edited") is corrupted.
          j = i + 3
          j += 1 if at(cp, j) == SPACE
          return nil unless digit?(at(cp, j))

          Edit.new(i, i + 3, [PLUS_MINUS], "symbols")
        end

        # symbols.md 3.5: one left-to-right scan. The three branches key on different code
        # points -- U+0028, a DIGIT, U+002B -- so no two can match at the same index; on a
        # successful edit the scan continues from the index after the matched span.
        #
        # locale_data is unused: order.json declares "localeData": [] for this rule.
        def self.scan(cp, _locale_data, _ctx)
          n = cp.length
          edits = []
          i = 0

          while i < n
            current = at(cp, i)

            if current == PAREN_OPEN
              edit = trademark_at(cp, i)
              if edit
                edits << edit
                i = edit.end
                next
              end
            elsif digit?(current) && !digit?(at(cp, i - 1))
              # Keyed on the start of a maximal digit run, not on the letter.
              chain = read_chain(cp, i)
              chain_result = chain_edits(cp, i, chain)
              edits.concat(chain_result) if chain_result
              # Continue past the chain whether or not it converted. A declined chain has no
              # convertible sub-chain: any sub-chain starts right after a MUL-LETTER, which is
              # a LETTER, so M2 would reject it too.
              i = chain.end_index + 1
              next
            elsif current == PLUS
              edit = plus_minus_at(cp, i)
              if edit
                edits << edit
                i = edit.end
                next
              end
            end
            i += 1
          end

          edits
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "symbols",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::Symbols.scan(cp, locale_data, ctx) },
)

# frozen_string_literal: true

require_relative "quote_ambiguity"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../edits"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # `quote-punctuation` -- spec/rules/quote-punctuation.md (spec 1.21.0), order 45, off by
      # default.
      #
      # Moves a comma or a full stop from after the locale's closing primary quotation mark to
      # before it, only where `quotes.punctuationPlacement` is "inside". One left-to-right scan
      # over code points; every edit swaps two adjacent code points, so the text never changes
      # length and no regex or normalization is involved. The inline marker is in no class below,
      # so a span boundary or protected run on any of the three sides declines the move.
      module QuotePunctuation
        COMMA = 0x2C
        FULL_STOP = 0x2E

        # SPACELIKE (quotes.md 3.1): INLINE-SPACE plus BREAK, with Engine::LINE_MARKER a member of
        # BREAK for every rule (modes.md 3.2).
        BREAK = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029, Engine::LINE_MARKER].freeze

        def self.spacelike?(cp)
          QuoteAmbiguity.inline_space?(cp) || BREAK.include?(cp)
        end

        # cp[i], or NONE if i is out of bounds -- the spec's own boundary value.
        def self.at(cp, i)
          return NONE if i.negative? || i >= cp.length

          cp[i]
        end

        # quote-punctuation.md 3.2: C1-C4 for the pair at i, i + 1.
        def self.edit_at?(cp, i, close)
          return false unless cp[i] == close && i >= 1

          next_cp = cp[i + 1]
          return false unless next_cp == COMMA || next_cp == FULL_STOP
          return false unless UnicodeUtil.letter?(cp[i - 1])

          after = at(cp, i + 2)
          after == NONE || spacelike?(after)
        end
        private_class_method :edit_at?

        def self.scan(cp, locale_data, _ctx)
          quotes = locale_data["quotes"]
          return [] unless quotes["punctuationPlacement"] == "inside"

          close = quotes["primary"]["close"].codepoints.first
          return [] if close.nil?

          edits = []
          i = 0
          while i + 1 < cp.length
            if edit_at?(cp, i, close)
              edits << Edit.new(i, i + 2, [cp[i + 1], close], "quote-punctuation")
              i += 2
            else
              i += 1
            end
          end
          edits
        end
      end
    end
  end
end

Polytypo::Engine::Registry.register(
  "quote-punctuation",
  ->(cp, locale_data, ctx) { Polytypo::Engine::Rules::QuotePunctuation.scan(cp, locale_data, ctx) },
)

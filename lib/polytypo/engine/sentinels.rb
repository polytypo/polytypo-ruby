# frozen_string_literal: true

module Polytypo
  module Engine
    # The three non-code-point values a rule can meet in the array it scans. They live together
    # and must stay pairwise disjoint (mirrors src/engine/sentinels.ts in the JS reference
    # implementation and its Python/Go equivalents):
    #
    #   - NONE — there is nothing at that index; the array ends here.
    #   - MARKER — a span boundary whose skipped region has no line terminator. Per modes.md 3.3
    #     it is opaque content everywhere except OPENISH/CLOSEISH, where it is a member of both.
    #   - LINE_MARKER — a span boundary whose skipped region contains a line terminator. A member
    #     of BREAK for every rule, everywhere.
    MARKER = -1
    LINE_MARKER = -2
    NONE = -3

    # True for either span boundary. NONE is deliberately not a marker: it is not in the array.
    def self.marker?(value)
      value == MARKER || value == LINE_MARKER
    end
  end
end

# frozen_string_literal: true

module Polytypo
  module Engine
    # String <-> code-point array conversion (docs/ARCHITECTURE.md section 4.2: rules index an
    # explicit code-point array, never a native string). Ruby strings are already sequences of
    # Unicode code points for a UTF-8-encoded String -- this module exists for cross-runtime
    # consistency and because every rule below is written against "index i of the code-point
    # array," not "index i of the string."
    module Codepoints
      def self.to_codepoints(str)
        str.codepoints
      end

      def self.from_codepoints(cp)
        cp.pack("U*")
      end

      def self.valid_codepoint?(value)
        value.is_a?(Integer) && value >= 0 && value <= 0x10FFFF
      end
    end
  end
end

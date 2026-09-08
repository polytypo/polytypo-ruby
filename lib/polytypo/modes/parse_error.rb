# frozen_string_literal: true

require_relative "../errors"

module Polytypo
  module Modes
    # Wraps any error either mode parser produces into POLYTYPO_MALFORMED_INPUT -- no third-party
    # parser's error type is ever allowed to escape Transform.
    module ParseError
      def self.wrap
        yield
      rescue Polytypo::Error
        raise
      rescue StandardError => e
        raise Polytypo::Error.new(Polytypo::CODE_MALFORMED_INPUT, "input did not parse: #{e.message}")
      end
    end
  end
end

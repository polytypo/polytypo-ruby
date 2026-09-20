# frozen_string_literal: true

module Polytypo
  # The seven stable, cross-runtime error codes (docs/ARCHITECTURE.md section 4.6). Messages are
  # English and are not part of the contract; codes are.
  CODE_UNKNOWN_LOCALE = "POLYTYPO_UNKNOWN_LOCALE"
  CODE_INVALID_MODE = "POLYTYPO_INVALID_MODE"
  CODE_INVALID_DIALECT = "POLYTYPO_INVALID_DIALECT"
  CODE_UNKNOWN_RULE = "POLYTYPO_UNKNOWN_RULE"
  CODE_MALFORMED_LOCALE_DATA = "POLYTYPO_MALFORMED_LOCALE_DATA"
  CODE_RULE_CONTRACT = "POLYTYPO_RULE_CONTRACT"
  CODE_MALFORMED_INPUT = "POLYTYPO_MALFORMED_INPUT"
  # Spec 1.3.0. Deliberately general: every option added from 1.3.0 on shares this code, while
  # `mode` and `dialect` keep their own because callers branch on them.
  CODE_INVALID_OPTION = "POLYTYPO_INVALID_OPTION"

  # The only error type Transform ever raises. One class is enough: the stable machine-readable
  # +code+ is the contract, not the exception type or the message text.
  class Error < StandardError
    attr_reader :code

    def initialize(code, message)
      super(message)
      @code = code
    end
  end
end

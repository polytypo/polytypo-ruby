# frozen_string_literal: true

require_relative "codepoints"
require_relative "../errors"

module Polytypo
  module Engine
    # One replacement a rule proposes: replace cp[start...end] with replacement. Indices address
    # the code-point array, never a native string (docs/ARCHITECTURE.md section 4.2).
    Edit = Struct.new(:start, :end, :replacement, :rule_id)

    module Edits
      # Enforces the rule contract rather than trusting it (rules are community-contributed):
      # edits must be in bounds, ascending, non-overlapping, and made of real code points.
      # rule_id is nil when validating a caller-agnostic batch.
      def self.validate_edits(edits, length, rule_id = nil)
        previous_end = 0
        edits.each_with_index do |edit, i|
          where = rule_id.nil? ? "edit #{i}" : "rule #{rule_id.inspect} edit #{i}"

          if edit.start.negative? || edit.end > length
            reject("#{where} is out of bounds (#{edit.start}, #{edit.end}) for length #{length}")
          end
          if edit.end < edit.start
            reject("#{where} has end #{edit.end} before start #{edit.start}")
          end
          if edit.start < previous_end
            reject("#{where} starts at #{edit.start}, which overlaps or precedes the previous edit")
          end
          if !rule_id.nil? && edit.rule_id != rule_id
            reject("#{where} is tagged #{edit.rule_id.inspect} but was produced by rule #{rule_id.inspect}")
          end
          edit.replacement.each do |value|
            unless Codepoints.valid_codepoint?(value)
              reject("#{where} contains an invalid code point (#{value})")
            end
          end
          previous_end = edit.end
        end
      end

      # Applies validated edits left to right, producing a new code-point array.
      def self.apply_edits(cp, edits, rule_id = nil)
        validate_edits(edits, cp.length, rule_id)
        return cp.dup if edits.empty?

        out = []
        cursor = 0
        edits.each do |edit|
          out.concat(cp[cursor...edit.start])
          out.concat(edit.replacement)
          cursor = edit.end
        end
        out.concat(cp[cursor..])
        out
      end

      def self.reject(message)
        raise Polytypo::Error.new(Polytypo::CODE_RULE_CONTRACT, message)
      end
      private_class_method :reject
    end
  end
end

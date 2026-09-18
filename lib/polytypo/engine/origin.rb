# frozen_string_literal: true

require_relative "codepoints"

module Polytypo
  # One entry of Polytypo.analyze's result, in input coordinates (analyze.md section 2):
  # +rule_id+ is a rule id from spec/rules/order.json, +start+/+end+ are code-point offsets into
  # the input (inclusive/exclusive), and +before+/+after+ are the text on either side of that one
  # edit. +start+ == +end+ is a pure insertion, and +before+ is then empty.
  #
  # Public API, so it is named in this namespace rather than in Engine, where it is built.
  Change = Data.define(:rule_id, :start, :end, :before, :after)

  module Engine
    # analyze.md section 2: every reported offset is a code-point offset into the input the
    # caller passed, in every mode. The rules, however, run over an array that is not the input
    # -- in "text" mode edits from earlier rules have already shifted it, and in "html"/"markdown"
    # mode it is the marker-joined concatenation of the processable spans (modes.md 3.5). This
    # module carries the one structure that bridges the two: an origin map, parallel to the
    # current code-point array, holding the input offset each code point came from, or NO_ORIGIN
    # for one the pipeline itself produced. Mirrors polytypo-js's src/engine/origin.ts.
    module Origin
      NO_ORIGIN = -1

      # The input offset an edit boundary at +index+ addresses. Synthetic code points have no
      # origin of their own, so the scan runs forward to the first that has one -- an insertion
      # between two earlier insertions still lands where the next real character is. Falling off
      # the end means the boundary is at the end of the input.
      def self.origin_at(origin, index, input_length)
        (index...origin.length).each do |i|
          return origin[i] unless origin[i] == NO_ORIGIN
        end
        input_length
      end

      # The origin map for the array Edits.apply_edits is about to produce. A replacement of
      # equal length keeps its origins position by position, which is what makes a conversion
      # (U+0020 -> U+00A0) still point at the character it converted; anything longer is
      # synthetic beyond the positions it covers.
      def self.apply_edits_to_origin(origin, edits)
        return origin.dup if edits.empty?

        out = []
        cursor = 0
        edits.each do |edit|
          out.concat(origin[cursor...edit.start])
          edit.replacement.each_index do |k|
            source = edit.start + k
            out << (source < edit.end ? origin[source] : NO_ORIGIN)
          end
          cursor = edit.end
        end
        out.concat(origin[cursor..])
        out
      end

      # One rule's edits, in the coordinates that rule saw, rendered as Changes in input
      # coordinates. +before+ is the text this rule replaced and +after+ what it replaced it with
      # (analyze.md section 2), so on a text two rules have both touched, +before+ is what the
      # second rule saw rather than what the caller typed -- section 5 says so and shows the
      # French case where it matters.
      def self.record_changes(cp, edits, origin, input_length, rule_id)
        edits.map do |edit|
          Polytypo::Change.new(
            rule_id: rule_id,
            start: origin_at(origin, edit.start, input_length),
            end: origin_at(origin, edit.end, input_length),
            before: Codepoints.from_codepoints(cp[edit.start...edit.end]),
            after: Codepoints.from_codepoints(edit.replacement)
          )
        end
      end
    end
  end
end

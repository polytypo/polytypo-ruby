# frozen_string_literal: true

require_relative "codepoints"
require_relative "origin"
require_relative "pipeline"
require_relative "sentinels"
require_relative "../errors"
require_relative "../modes/spans"
require_relative "../modes/runner"

module Polytypo
  module Engine
    # modes.md 3.9: the caller's own skipped regions, "text" mode only (spec 1.13.0). Each maximal
    # protected run becomes ONE boundary marker in the code-point array -- at the very start or
    # end too, which is the one difference from the html/markdown/yaml span concatenation -- the
    # rules run once over that array, and the protected code points are put back at their markers.
    module Protect
      LINE_TERMINATORS = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029].freeze

      def self.invalid(message)
        raise Polytypo::Error.new(Polytypo::CODE_INVALID_OPTION, message)
      end
      private_class_method :invalid

      # modes.md 3.9.2: validates +value+ against the input's length in code points and returns
      # the protected runs as [start, end] pairs with touching ranges merged. nil and [] are the
      # same call.
      def self.resolve(value, length)
        return [] if value.nil?

        invalid("\"protect\" must be an Array of [start, end] pairs. Received #{value.inspect}.") unless value.is_a?(Array)

        holes = []
        previous_end = 0
        value.each do |range|
          unless range.is_a?(Array) && range.length == 2 && range.all?(Integer)
            invalid("\"protect\" entries must be [start, end] pairs of Integers; received #{range.inspect}.")
          end
          s, e = range
          invalid("protect range [#{s}, #{e}) is empty or negative.") if s.negative? || e <= s
          invalid("protect range [#{s}, #{e}) overlaps or precedes the previous one.") if s < previous_end
          invalid("protect range [#{s}, #{e}) runs past the end of the input (#{length}).") if e > length

          if !holes.empty? && holes.last[1] == s
            holes.last[1] = e
          else
            holes << [s, e]
          end
          previous_end = e
        end
        holes
      end

      # modes.md 3.9.2: outside "text" mode a non-empty +protect+ is refused rather than ignored.
      def self.refuse_outside_text(value, mode)
        return if value.nil? || (value.is_a?(Array) && value.empty?)

        invalid("\"protect\" is only available when mode is \"text\", not #{mode.inspect}.")
      end

      # [S0] m [S1] m ... [Sk], a marker for every run, edges included, and the origin map.
      def self.layout(cp, holes)
        array = []
        origin = []
        cursor = 0
        holes.each do |s, e|
          (cursor...s).each do |i|
            array << cp[i]
            origin << i
          end
          line = (s...e).any? { |i| LINE_TERMINATORS.include?(cp[i]) }
          array << (line ? Engine::LINE_MARKER : Engine::MARKER)
          origin << Origin::NO_ORIGIN
          cursor = e
        end
        (cursor...cp.length).each do |i|
          array << cp[i]
          origin << i
        end
        [array, origin]
      end
      private_class_method :layout

      # Returns [text, moved] where +moved+ is the protected runs located in the output, the
      # ranges a second call has to be given. Public API returns the text alone.
      def self.run_mapped(cp, holes, plan, locale_data, ctx)
        array, = layout(cp, holes)
        out = Modes::Runner.run_rules_over_spans(array, plan, locale_data, ctx)
        result = []
        moved = []
        index = 0
        out.each do |value|
          unless Engine.marker?(value)
            result << value
            next
          end

          s, e = holes[index]
          moved << [result.length, result.length + (e - s)]
          result.concat(cp[s...e])
          index += 1
        end
        if index != holes.length
          raise Polytypo::Error.new(Polytypo::CODE_RULE_CONTRACT, "boundary markers did not survive the pipeline")
        end

        [Codepoints.from_codepoints(result), moved]
      end

      def self.run(cp, holes, plan, locale_data, ctx)
        run_mapped(cp, holes, plan, locale_data, ctx).first
      end

      def self.analyze(cp, holes, plan, locale_data, ctx)
        array, origin = layout(cp, holes)
        Pipeline.run_rules_recording(array, plan, locale_data, ctx, origin, cp.length) do |current, edits|
          Modes::Spans.filter_boundary_edits(current, edits, Modes::Spans.span_ranges_of(current))
        end
      end
    end
  end
end

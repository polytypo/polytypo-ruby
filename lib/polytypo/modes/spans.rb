# frozen_string_literal: true

require_relative "../engine/origin"
require_relative "../engine/sentinels"
require_relative "../errors"

module Polytypo
  module Modes
    # The span model shared by every mode adapter that is not "text" (spec/rules/modes.md
    # 3.2-3.5). Mirrors the other three ports' spans.{ts,py,go} exactly: markers are written here
    # (mode layer), classified in Engine::Sentinels and in each rule's own class definitions (L1).
    module Spans
      LINE_TERMINATORS = [0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029].freeze

      # A processable span, identified by its offsets in the original source, addressed as
      # code-point indices (ARCHITECTURE.md section 4.2) -- Ruby String indices are already
      # code-point indices for a UTF-8 String, no separate byte/char distinction to manage here.
      Span = Struct.new(:start, :end)

      # A span's extent in the concatenated code-point array: s0/s1 of modes.md 3.4. `:first`
      # deliberately shadows Struct#first with the equivalent one-argument-less accessor -- this
      # struct is never called with an integer argument the way Struct#first(n) would expect, and
      # `first`/`last` match every other port's SpanRange naming exactly.
      SpanRange = Struct.new(:first, :last) # rubocop:disable Lint/StructNewOverride

      def self.gap_is_line_boundary?(cp, from, to)
        (from...to).any? { |i| LINE_TERMINATORS.include?(cp[i]) }
      end
      private_class_method :gap_is_line_boundary?

      # Sorts, drops empties, and coalesces spans separated by nothing in the source (modes.md
      # 7.5). Overlapping spans are an extractor bug and are rejected rather than silently merged.
      def self.normalize_spans(spans)
        sorted = spans.select { |s| s.end > s.start }.sort_by(&:start)
        out = []
        sorted.each do |span|
          if out.empty?
            out << span
            next
          end
          last = out[-1]
          if span.start < last.end
            raise Polytypo::Error.new(
              Polytypo::CODE_RULE_CONTRACT,
              "mode extractor produced overlapping spans (#{last.start}, #{last.end}) and " \
              "(#{span.start}, #{span.end})"
            )
          end
          if span.start == last.end
            out[-1] = Span.new(last.start, span.end)
          else
            out << span
          end
        end
        out
      end

      # S1 (marker) S2 ... Sm (modes.md 3.5 step 2), given the source's full code-point array.
      def self.concatenate_spans(source_cp, spans)
        cp = []
        previous = nil
        spans.each do |span|
          unless previous.nil?
            cp << (gap_is_line_boundary?(source_cp, previous.end, span.start) ? Engine::LINE_MARKER : Engine::MARKER)
          end
          cp.concat(source_cp[span.start...span.end])
          previous = span
        end
        cp
      end

      # The origin map for concatenate_spans (analyze.md section 2): for every code point of the
      # joined array, the code-point offset of the character it came from IN THE DOCUMENT, and
      # NO_ORIGIN for the markers, which came from nowhere. A Span's bounds are already
      # code-point offsets, so no coordinate conversion belongs here.
      def self.origin_of_spans(spans)
        origin = []
        spans.each_with_index do |span, i|
          origin << Engine::Origin::NO_ORIGIN unless i.zero?
          origin.concat((span.start...span.end).to_a)
        end
        origin
      end

      # The span extents of the array as it stands. Recomputed after every rule, because applying
      # edits shifts every index after the first one -- the markers themselves always survive,
      # since no edit may contain one.
      def self.span_ranges_of(cp)
        ranges = []
        first = 0
        cp.each_with_index do |value, i|
          if Engine.marker?(value)
            ranges << SpanRange.new(first, i - 1)
            first = i + 1
          end
        end
        ranges << SpanRange.new(first, cp.length - 1)
        ranges
      end

      def self.span_containing(ranges, p)
        ranges.find { |r| r.first <= p && p <= r.last + 1 }
      end
      private_class_method :span_containing

      # modes.md 3.4, two safety nets, both pure functions of (p, q, r, s0, s1):
      #
      #  1. No edit may contain a marker -- one that does is a bug, discarded rather than
      #     redistributed.
      #  2. The edge-growth rule: an edit is discarded if it would place code points at an
      #     extremity of its span that were not there before.
      def self.filter_boundary_edits(cp, edits, ranges)
        edits.select do |edit|
          next false if (edit.start...edit.end).any? { |i| Engine.marker?(cp[i]) }

          p = edit.start
          q = edit.end - 1
          d = edit.end - edit.start
          r = edit.replacement.length
          span = span_containing(ranges, p)
          !(span && r > d && (p == span.first || q == span.last))
        end
      end

      # Redistributes the transformed array back to one piece per span (modes.md 3.5 step 4).
      def self.split_on_marker(cp, expected)
        pieces = [[]]
        cp.each do |value|
          if Engine.marker?(value)
            pieces << []
          else
            pieces[-1] << value
          end
        end
        if pieces.length != expected
          raise Polytypo::Error.new(
            Polytypo::CODE_RULE_CONTRACT,
            "boundary markers did not survive the pipeline: expected #{expected} spans, " \
            "found #{pieces.length}"
          )
        end
        pieces
      end
    end
  end
end

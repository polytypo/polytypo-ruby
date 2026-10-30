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

      # U+0020, the one emitted code point whose meaning is positional (modes.md 3.4, 5 item 2).
      SPACE = 0x20

      # A processable span, identified by its offsets in the original source, addressed as
      # code-point indices (ARCHITECTURE.md section 4.2) -- Ruby String indices are already
      # code-point indices for a UTF-8 String, no separate byte/char distinction to manage here.
      #
      # +url_tail+ is true (or nil) on a span that begins at the U+0020 or U+0009 ending a bare web
      # address, so the filter can guard its first code point (modes.md 3.7.3, spec 1.17.2).
      Span = Struct.new(:start, :end, :url_tail)

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
            out[-1] = Span.new(last.start, span.end, last.url_tail)
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

      DELIMITERS = [0x2A, 0x5F, 0x7E].freeze

      def self.markdown_whitespace?(c)
        return false if c.nil?

        [0x09, 0x0A, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000].include?(c) ||
          (c >= 0x2000 && c <= 0x200A)
      end
      private_class_method :markdown_whitespace?

      # modes.md 3.4 delimiter-neighbour rule (markdown only, spec 1.17.2): an edit is discarded
      # when, beside U+002A, U+005F or U+007E, exactly one of the old and new neighbour is
      # CommonMark whitespace. A marker belongs to neither class, nor does a position outside the
      # array. An insertion has q = p - 1.
      def self.changes_delimiter_flank?(cp, p, q, replacement)
        r = replacement.length
        before_edit = p.positive? ? cp[p - 1] : nil
        if DELIMITERS.include?(before_edit)
          after = r.positive? ? replacement[0] : cp[q + 1]
          return true if markdown_whitespace?(cp[p]) != markdown_whitespace?(after)
        end
        if q + 1 < cp.length && DELIMITERS.include?(cp[q + 1])
          after = r.positive? ? replacement[r - 1] : before_edit
          return true if markdown_whitespace?(q.negative? ? nil : cp[q]) != markdown_whitespace?(after)
        end
        false
      end
      private_class_method :changes_delimiter_flank?

      def self.ascii_punctuation?(c)
        return false if c.nil?

        (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) ||
          (c >= 0x7B && c <= 0x7E)
      end
      private_class_method :ascii_punctuation?

      def self.ascii_alphanumeric?(c)
        return false if c.nil?

        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
      end
      private_class_method :ascii_alphanumeric?

      # modes.md 3.4 escape-and-reference rule, item 1 (markdown only, spec 1.17.4): an edit is
      # discarded when it follows a backslash and changes whether the first code point after the
      # backslash is ASCII punctuation, which would create or destroy a backslash escape.
      def self.creates_escape?(cp, p, q, replacement)
        return false if (p - 1).negative? || cp[p - 1] != 0x5C

        after = replacement.empty? ? cp[q + 1] : replacement[0]
        ascii_punctuation?(cp[p]) != ascii_punctuation?(after)
      end
      private_class_method :creates_escape?

      # modes.md 3.4 escape-and-reference rule, item 2 (markdown and html, spec 1.17.4): a deletion
      # that makes "&", an optional "#", one or more ASCII letters or digits and ";" adjacent
      # around the join. A marker is in no class and stops either scan.
      def self.creates_reference?(cp, p, q, replacement)
        return false if !replacement.empty? || (p - 1).negative? || q + 1 >= cp.length

        left = p - 1
        alnum = 0
        while left >= 0 && ascii_alphanumeric?(cp[left])
          left -= 1
          alnum += 1
        end
        right = q + 1
        right += 1 if left >= 0 && cp[left] == 0x26 && cp[right] == 0x23 && alnum.zero?
        while right < cp.length && ascii_alphanumeric?(cp[right])
          right += 1
          alnum += 1
        end
        return false if cp[right] != 0x3B || alnum.zero?

        left -= 1 if left >= 0 && cp[left] == 0x23
        left >= 0 && cp[left] == 0x26
      end
      private_class_method :creates_reference?

      # modes.md 3.4, two safety nets, both pure functions of (p, q, r, s0, s1):
      #
      #  1. No edit may contain a marker -- one that does is a bug, discarded rather than
      #     redistributed.
      #  2. The edge-growth rule: an edit is discarded if it would place code points at an
      #     extremity of its span that were not there before. That sentence is the rule;
      #     "r > d" alone is an incorrect formalisation of it and misses r == d. dashes P3
      #     admits a run of THREE dashes, so "---" -> U+0020 en-dash U+0020 is 3 -> 3: the
      #     length test sees nothing while U+0020 lands on both extremities anyway. The second
      #     clause tests the CHARACTER, and only U+0020 needs testing -- it is the one code
      #     point any rule emits whose meaning comes from its position rather than from itself
      #     (modes.md 5 item 2).
      #
      # +mode+ selects the neighbour rules of modes.md 3.4 -- delimiter-neighbour and the escape rule
      # for markdown, the reference rule for markdown and html -- and +guarded+ holds, per span,
      # whether its first code point is the terminator of a bare web address (modes.md 3.7.3).
      def self.filter_boundary_edits(cp, edits, ranges, mode: nil, guarded: [])
        edits.select do |edit|
          next false if (edit.start...edit.end).any? { |i| Engine.marker?(cp[i]) }

          p = edit.start
          q = edit.end - 1
          d = edit.end - edit.start
          r = edit.replacement.length
          markdown = mode == "markdown"
          next false if markdown && changes_delimiter_flank?(cp, p, q, edit.replacement)
          next false if markdown && creates_escape?(cp, p, q, edit.replacement)
          next false if (markdown || mode == "html") && creates_reference?(cp, p, q, edit.replacement)

          span = span_containing(ranges, p)
          if span && p == span.first && guarded[ranges.index(span)] == true &&
             (r.zero? || edit.replacement[0] != SPACE)
            next false
          end
          next true unless span && (p == span.first || q == span.last)
          next false if r > d
          next false if r.positive? && p == span.first && edit.replacement[0] == SPACE && cp[p] != SPACE
          next false if r.positive? && q == span.last && edit.replacement[r - 1] == SPACE && cp[q] != SPACE

          true
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

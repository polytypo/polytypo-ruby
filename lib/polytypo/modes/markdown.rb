# frozen_string_literal: true

require_relative "spans"
require_relative "html"
require_relative "parse_error"
require_relative "../errors"

module Polytypo
  module Modes
    # Markdown span extraction via `commonmarker` (the Ruby binding to the `comrak` Rust
    # CommonMark/GFM engine). `dialect="mdx"` returns POLYTYPO_INVALID_DIALECT: this runtime has
    # no MDX/JSX parser, which the spec permits (a narrower conformance claim, not a silent
    # mishandling of a dialect it claims to support).
    #
    # `require "commonmarker"` happens lazily, inside this file only, never at the top of
    # lib/polytypo.rb -- a caller who only ever uses mode: "text" never loads the native
    # commonmarker extension.
    module Markdown
      def self.resolve_dialect(dialect)
        case dialect
        when nil, ""
          raise Polytypo::Error.new(
            Polytypo::CODE_INVALID_DIALECT,
            'mode "markdown" requires a dialect; there is no default'
          )
        when "commonmark"
          nil
        when "mdx"
          raise Polytypo::Error.new(
            Polytypo::CODE_INVALID_DIALECT,
            'dialect "mdx" is not supported by this runtime (no MDX/JSX parser available); ' \
            'only "commonmark" is supported'
          )
        else
          raise Polytypo::Error.new(
            Polytypo::CODE_INVALID_DIALECT,
            "unknown dialect #{dialect.inspect}; this runtime supports \"commonmark\""
          )
        end
      end

      # Block/inline node types that are never processable, in full (modes.md 3.7.3): fenced and
      # indented code (comrak represents both as :code_block), inline code spans, thematic
      # breaks (no prose content), and frontmatter (skipped whole including its delimiters).
      SKIP_WHOLE_TYPES = %i[code code_block thematic_break frontmatter].freeze

      # A leaf whose Segment/source_position directly delineates literal, processable prose --
      # comrak's AST is segment-based like goldmark's: structural bytes (emphasis delimiters,
      # link brackets/destination, table pipes and the delimiter row, list markers, blockquote
      # markers, heading hashes, fence lines and info strings) are consumed during parsing and
      # never represented as a node's own source_position at all, so no gap-filling step is
      # needed here -- emitting a span for exactly every :text node's source_position already
      # reconstructs precisely the processable prose, nothing more (same discovery as the Go
      # port's goldmark-based adapter).
      TEXT_LEAF_TYPES = %i[text].freeze

      # detect_frontmatter_delimiter: comrak's frontmatter extension takes one literal delimiter
      # string and requires the opening AND closing lines to match it exactly -- unlike the Go
      # port (which had to hand-roll frontmatter detection entirely), here only the *which
      # delimiter* choice needs to be made upfront, from the document's own leading bytes.
      def self.detect_frontmatter_delimiter(source)
        return "+++" if source.start_with?("+++")
        return "---" if source.start_with?("---")

        nil
      end
      private_class_method :detect_frontmatter_delimiter

      # Locates the processable spans of a Markdown document. dialect must already be validated
      # via resolve_dialect (== "commonmark"); this function does not re-check it.
      def self.markdown_spans(source)
        require "commonmarker"

        cp = Polytypo::Engine::Codepoints.to_codepoints(source)
        chars = cp.map { |c| [c].pack("U") }
        line_starts = build_line_starts(chars)

        delimiter = detect_frontmatter_delimiter(source)
        options = { parse: { sourcepos_chars: true } }
        options[:extension] = { front_matter_delimiter: delimiter } if delimiter

        spans = []
        ParseError.wrap do
          doc = Commonmarker.parse(source, options: options)
          html_stack_holder = { stack: [] }
          walk(doc, chars, line_starts, spans, html_stack_holder)
        end
        spans
      end

      # line_starts[i] is the 0-based code-point index at which comrak's 1-based line i begins.
      def self.build_line_starts(chars)
        starts = [0]
        chars.each_with_index do |ch, i|
          starts << (i + 1) if ch == "\n"
        end
        starts
      end
      private_class_method :build_line_starts

      def self.offset_of(line_starts, line, column)
        line_starts[line - 1] + (column - 1)
      end
      private_class_method :offset_of

      def self.walk(node, chars, line_starts, spans, html_holder)
        type = node.type
        return if SKIP_WHOLE_TYPES.include?(type)

        if type == :html_block
          handle_html_block(node, chars, line_starts, spans)
          return
        end

        if type == :html_inline
          handle_html_inline(node, chars, line_starts, html_holder)
          return
        end

        if type == :link || type == :image
          sp = node.source_position
          start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
          unless chars[start_offset] == "["
            # No leading "[" at the link's own source position: this is an autolink
            # (<https://…> or a bare GFM autolink literal), not a real [text](url) link --
            # skipped whole, per modes.md 3.7.3.
            return
          end
          # A real link/image: fall through to the generic child walk below, which emits the
          # link text (or image alt text) as processable prose. The destination/title are never
          # represented as child nodes at all, so there is nothing further to exclude.
        end

        if TEXT_LEAF_TYPES.include?(type)
          sp = node.source_position
          start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
          end_offset = offset_of(line_starts, sp[:end_line], sp[:end_column]) + 1
          if html_holder[:stack].empty? && end_offset > start_offset
            spans << Spans::Span.new(start_offset, end_offset)
          end
          return
        end

        if %i[paragraph heading table_cell].include?(type)
          # A fresh top-level inline-bearing container: the raw-HTML skip stack resets here (an
          # unclosed skipped start tag skips to the end of the block, modes.md 3.7.3).
          html_holder[:stack] = []
        end

        node.each { |child| walk(child, chars, line_starts, spans, html_holder) }
      end
      private_class_method :walk

      def self.handle_html_block(node, chars, line_starts, spans)
        sp = node.source_position
        start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
        end_offset = offset_of(line_starts, sp[:end_line], sp[:end_column]) + 1
        return if end_offset <= start_offset

        text = chars[start_offset...end_offset].join
        Html.html_spans(text).each do |s|
          spans << Spans::Span.new(start_offset + s.start, start_offset + s.end)
        end
      end
      private_class_method :handle_html_block

      def self.handle_html_inline(node, chars, line_starts, html_holder)
        sp = node.source_position
        start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
        end_offset = offset_of(line_starts, sp[:end_line], sp[:end_column]) + 1
        raw = chars[start_offset...end_offset]
        name, closing, self_closing = Html.read_tag(raw) || [nil, nil, nil]
        return if name.nil?

        stack = html_holder[:stack]
        if closing
          if !stack.empty? && stack[-1] == name
            stack.pop
          end
        elsif !self_closing && Html::SKIPPED_ELEMENTS.include?(name)
          stack << name
        end
      end
      private_class_method :handle_html_inline
    end
  end
end

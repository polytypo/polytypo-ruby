# frozen_string_literal: true

require_relative "spans"
require_relative "html"
require_relative "yaml"
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
      # indented code (comrak represents both as :code_block), inline code spans, and thematic
      # breaks (no prose content). Frontmatter is NOT in this list and is not a node type here:
      # comrak's front_matter_delimiter extension is never enabled, because since spec 1.8.0 the
      # block's extent is modes.md 3.7.3a's scan and not a parser's opinion of it.
      SKIP_WHOLE_TYPES = %i[code code_block thematic_break].freeze

      # A leaf whose Segment/source_position directly delineates literal, processable prose --
      # comrak's AST is segment-based like goldmark's: structural bytes (emphasis delimiters,
      # link brackets/destination, table pipes and the delimiter row, list markers, blockquote
      # markers, heading hashes, fence lines and info strings) are consumed during parsing and
      # never represented as a node's own source_position at all, so no gap-filling step is
      # needed here -- emitting a span for exactly every :text node's source_position already
      # reconstructs precisely the processable prose, nothing more (same discovery as the Go
      # port's goldmark-based adapter).
      TEXT_LEAF_TYPES = %i[text].freeze

      SPACE = " "
      TAB = "\t"
      CR = "\r"
      LF = "\n"
      BOM = "\uFEFF"
      FRONTMATTER_DELIMITERS = ["---", "+++"].freeze

      # What detect_frontmatter found: +end+, one past the closing delimiter line's terminator;
      # the delimiter it used; and the content range -- from after the opening delimiter line's
      # terminator to the code point that begins the closing delimiter line (modes.md 3.7.4).
      # Both delimiter lines and every line terminator lie outside that content range. The block
      # always begins at the document's first code point, or at the second when a byte-order mark
      # was stepped over, and both are masked, so its start needs no member of its own.
      FrontmatterBlock = Struct.new(:end, :delimiter, :content_start, :content_end)

      # modes.md 3.7.3a (spec 1.8.0). WHERE THE BLOCK BEGINS AND ENDS IS DECIDED HERE, not by
      # comrak's front_matter_delimiter extension: that extension requires both delimiter lines
      # to match the literal string exactly, so a fence carrying one trailing space was not a
      # block and its metadata was typeset as prose (polytypo/polytypo#58) -- the damage 3.7.3
      # exists to prevent, reached by an invisible character no author typed on purpose.
      #
      # ONE SCAN, ONE ANSWER: this is the authority for both the body's skip (3.7.3) and the
      # content range frontmatter_keys names (3.7.4). Two locators is how a skip and an option
      # come to disagree about the same three lines, and it cost this runtime a second parse of
      # the whole document as well (polytypo/polytypo#59).
      #
      # The steps, in the section's own order: the document must BEGIN with the delimiter, with
      # no leading blank line and no indentation, a single leading U+FEFF stepped over first (a
      # byte-order mark is not content, and reading it as content denies the block to every file
      # some Windows editors write); the rest of that line may be U+0020 and U+0009 and nothing
      # else, so "--- yaml" is not an opener and "----" is not a delimiter; the closing line is
      # the first later line whose FIRST code point begins the same delimiter, followed by only
      # U+0020 and U+0009 -- indentation disqualifies it exactly as it disqualifies the opener,
      # "..." closes nothing, and neither does a delimiter of the other kind; with no such line
      # there is no block.
      #
      # Offsets are code-point indices into +chars+, like every Span in this runtime.
      def self.detect_frontmatter(chars)
        start = chars[0] == BOM ? 1 : 0
        delimiter = FRONTMATTER_DELIMITERS.find { |d| delimiter_at?(chars, start, d) }
        return nil if delimiter.nil?

        line_end, next_start = line_bounds(chars, start)
        return nil unless spaces_and_tabs_only?(chars, start + delimiter.length, line_end)

        find_closing_line(chars, delimiter, next_start)
      end
      private_class_method :detect_frontmatter

      def self.find_closing_line(chars, delimiter, content_start)
        cursor = content_start
        while cursor < chars.length
          line_end, next_start = line_bounds(chars, cursor)
          if delimiter_at?(chars, cursor, delimiter) &&
             spaces_and_tabs_only?(chars, cursor + delimiter.length, line_end)
            return FrontmatterBlock.new(next_start, delimiter, content_start, cursor)
          end
          cursor = next_start
        end
        nil
      end
      private_class_method :find_closing_line

      def self.delimiter_at?(chars, i, delimiter)
        delimiter.each_char.with_index.all? { |ch, k| chars[i + k] == ch }
      end
      private_class_method :delimiter_at?

      # modes.md 3.7.3a step 5. A LINE ENDS AS COMMONMARK ENDS ONE -- at U+000A, at a U+000D not
      # followed by U+000A, or at the end of input -- and the terminator is never part of the
      # line. Returns [line_end, next_line_start]: a CRLF document gives the same block as the
      # same bytes with LF, a final "---\r" with no U+000A still closes its block, and a document
      # written with lone U+000D endings has lines at all.
      #
      # DELIBERATELY NOT 3.8.4's LF-only model, which Yaml.yaml_spans keeps for the block's
      # content: the block is a Markdown construct and ends its lines the way the language around
      # it does. 3.8.4 is a deliberate simplification rather than what YAML says (1.2.2 5.4 admits
      # a lone U+000D too), and widening it here would change "yaml" mode for every caller, so the
      # two models stay different on purpose -- the cost is modes.md 7.13's: inside a lone-U+000D
      # block frontmatter_keys yields nothing at all. Harmonising them silently changes one.
      def self.line_bounds(chars, from)
        i = from
        i += 1 while i < chars.length && chars[i] != LF && chars[i] != CR
        return [i, i] if i >= chars.length

        [i, chars[i] == CR && chars[i + 1] == LF ? i + 2 : i + 1]
      end
      private_class_method :line_bounds

      def self.spaces_and_tabs_only?(chars, from, to)
        (from...to).all? { |i| chars[i] == SPACE || chars[i] == TAB }
      end
      private_class_method :spaces_and_tabs_only?

      # modes.md 3.7.3a: THE PARSER IS HANDED THE BLOCK MASKED OUT -- the block, both delimiter
      # lines included and the leading U+FEFF of step 1 with them, replaced by U+0020 with line
      # terminators kept as they are, so nothing inside it can form or close a construct in the
      # body. The mask runs from 0: the only code point that can precede the delimiter is that
      # mark.
      #
      # THE INVARIANT IS POSITIONAL ALIGNMENT IN THE UNIT THIS RUNTIME MAPS PARSER OFFSETS BACK
      # THROUGH, which is not the same as "one U+0020 per index unit". comrak reports line and
      # column in CODE POINTS under `sourcepos_chars: true`, and build_line_starts resolves them
      # against the original document, so code-point alignment is all this runtime owes -- one
      # space per character gives it, and in Ruby, whose strings are sequences of code points,
      # byte-length preservation cannot even be expressed. A runtime that hands its parser's BYTE
      # offsets straight through owes byte-length preservation instead, and masking an astral
      # character to a single space would shorten its source by three.
      #
      # Suppressing the block's spans after the parse is NOT a substitute for masking, and is
      # measured wrong in the spec's own table: a fenced-code line inside a metadata value pairs
      # with the body's own fence, and the body's code block and its prose swap roles. No
      # span-level check can see that, because the damage is in what the parser concluded before
      # any span existed. The two are not alternatives -- 3.7.3a requires both, and the clip in
      # emit_span is the other half.
      def self.mask_frontmatter(source, block)
        return source if block.nil?

        segment = source[0, block.end].each_char.map { |ch| ch == LF || ch == CR ? ch : SPACE }
        masked = source.dup
        masked[0, block.end] = segment.join
        masked
      end
      private_class_method :mask_frontmatter

      # A LOCAL WORKAROUND FOR A MEASURED commonmarker 2.10.0 DEFECT, not a spec rule. With
      # `sourcepos_chars: true` comrak converts its byte columns to code-point columns, and on a
      # document whose lines end in a LONE U+000D the conversion does not reach them: measured on
      # line 3 of such a document, "Body has “quotes” here." comes back with end_column 27, its
      # byte length, instead of 23 -- the very number the option exists to remove. The same
      # document with LF or CRLF endings is converted correctly.
      #
      # U+000D not followed by U+000A is replaced by U+000A for the parser's copy only. The three
      # line endings are the same construct in CommonMark, the replacement is one code point for
      # one, so every source position still addresses the original document -- which is what the
      # output is emitted from, carriage returns and all.
      # Does the 3.8.4 line containing +index+ carry a U+000D that is not followed by U+000A? The
      # line is LF-delimited, because this is the content's own line model (3.8.4), not 3.7.3a's.
      def self.lone_cr_line?(content, index)
        from = (content.rindex(LF, index) || -1) + 1
        to = content.index(LF, index) || content.length
        i = content.index(CR, from)
        while i && i < to
          return true if content[i + 1] != LF

          i = content.index(CR, i + 1)
        end
        false
      end
      private_class_method :lone_cr_line?

      def self.normalize_lone_cr(source)
        i = source.index(CR)
        return source if i.nil?

        normalized = source.dup
        while i
          normalized[i] = LF if normalized[i + 1] != LF
          i = normalized.index(CR, i + 1)
        end
        normalized
      end
      private_class_method :normalize_lone_cr

      # modes.md 3.7.4, spec 1.7.0. The frontmatter block's own spans, which form a SECOND TEXT
      # UNIT: the pipeline runs over them separately from the body's, so an unbalanced mark in a
      # metadata field can never pair with one in the first paragraph, and the option cannot
      # change a byte outside the block.
      #
      # Spans come from the scan of modes.md 3.8 -- frontmatter IS YAML, and implementing that
      # grammar twice is how two implementations of one spec drift -- with +keys+ as step 8's key
      # predicate. The block is the construct markdown_spans masks out (3.7.3, the same
      # detect_frontmatter scan), so the option only ever adds spans where the skip removed them:
      # no source position belongs to both units. A TOML block yields nothing, with the option or
      # without it -- its quoting is a second grammar this scan does not claim (modes.md 7.13).
      #
      # The content range comes from detect_frontmatter, the same scan markdown_spans skips by
      # (3.7.3a, spec 1.8.0). Locating the block needs no parser at all, which is why this method
      # no longer parses the document a second time.
      #
      # A CONTENT LINE CARRYING A U+000D NOT FOLLOWED BY U+000A YIELDS NO SPANS (3.7.4), per line
      # and not per block, exactly as 3.8.4 step 1 declines a line containing U+0009: a stray
      # U+000D inside one quoted value costs that value and not the whole block. The two line
      # models meet here and do not compose -- 3.7.3a step 5 finds the block in a lone-U+000D
      # document and 3.8.4's LF-only scan then reads the whole of it as ONE line, so such a
      # document loses every span, which is the price of not widening 3.8.4 (that would change
      # "yaml" mode for every caller). Measured, letting it through is not merely inert: marks
      # pair across mapping lines, an unlisted line inside a listed key's scalar takes the
      # locale's spacing, and the U+000D lands inside a span, which 3.8.4 forbids.
      def self.frontmatter_spans(source, keys)
        return [] if keys.empty?

        cp = Polytypo::Engine::Codepoints.to_codepoints(source)
        chars = cp.map { |c| [c].pack("U") }
        block = detect_frontmatter(chars)
        return [] if block.nil? || block.delimiter != "---"
        return [] if block.content_end <= block.content_start

        content = chars[block.content_start...block.content_end].join
        spans = Yaml.yaml_spans(content, keys)
        spans = spans.reject { |span| lone_cr_line?(content, span.start) } if content.include?(CR)
        spans.map do |span|
          Spans::Span.new(span.start + block.content_start, span.end + block.content_start)
        end
      end

      # Locates the processable spans of a Markdown document. dialect must already be validated
      # via resolve_dialect (== "commonmark"); this function does not re-check it.
      #
      # The frontmatter block is located by detect_frontmatter and masked out of the source the
      # parser sees (3.7.3a), so comrak needs no frontmatter concept and is never given its
      # front_matter_delimiter option: a masked document has no frontmatter left to find, and
      # the extent is this runtime's scan rather than an extension's exact-match opinion of it.
      #
      # frontmatter_end carries 3.7.3a's second requirement: NO SPAN MAY LIE INSIDE THE BLOCK,
      # whatever the parser did with the masked text. Masking is what makes that true for comrak
      # -- measured, it emits no node inside the masked range -- and the spec keeps the rule
      # anyway because it is not true of every parser: tree-sitter-markdown reads a final
      # all-space line with no terminator as a paragraph and would emit a span over the closing
      # delimiter itself.
      def self.markdown_spans(source)
        require "commonmarker"

        cp = Polytypo::Engine::Codepoints.to_codepoints(source)
        chars = cp.map { |c| [c].pack("U") }
        line_starts = build_line_starts(chars)
        block = detect_frontmatter(chars)
        parser_source = normalize_lone_cr(mask_frontmatter(source, block))

        spans = []
        ParseError.wrap do
          doc = Commonmarker.parse(parser_source, options: { parse: { sourcepos_chars: true } })
          walk(doc, chars, line_starts, spans, { stack: [], frontmatter_end: block.nil? ? 0 : block.end })
        end
        spans
      end

      # line_starts[i] is the 0-based code-point index at which comrak's 1-based line i begins.
      # comrak counts CommonMark line endings, which are U+000A, U+000D, and U+000D U+000A --
      # measured, not assumed: a document with lone U+000D endings reports its body on line 5,
      # and an LF-only table would have no entry to map that to.
      def self.build_line_starts(chars)
        starts = [0]
        chars.each_with_index do |ch, i|
          next unless ch == LF || (ch == CR && chars[i + 1] != LF)

          starts << (i + 1)
        end
        starts
      end
      private_class_method :build_line_starts

      def self.offset_of(line_starts, line, column)
        line_starts[line - 1] + (column - 1)
      end
      private_class_method :offset_of

      # modes.md 3.7.3a's second requirement: NO SPAN MAY LIE INSIDE THE BLOCK, whatever the parser
      # did with the masked text. A span that overlaps the block is CLIPPED to the part outside it
      # and dropped when nothing is left -- the block's own characters must not reach the rules,
      # and body prose past the block must not be lost to a parser's mistake about where the block
      # ended. It never fires with comrak, which emits no node inside the masked range -- measured
      # by counting clips over every markdown fixture's input and output, 216 spans, none clipped
      # -- and it is implemented anyway because the spec states it of every runtime:
      # tree-sitter-markdown reads a final all-space line with no terminator as a paragraph.
      def self.emit_span(spans, start_offset, end_offset, state)
        start_offset = state[:frontmatter_end] if start_offset < state[:frontmatter_end]
        return if end_offset <= start_offset

        spans << Spans::Span.new(start_offset, end_offset)
      end
      private_class_method :emit_span

      def self.walk(node, chars, line_starts, spans, state)
        type = node.type
        return if SKIP_WHOLE_TYPES.include?(type)

        if type == :html_block
          handle_html_block(node, chars, line_starts, spans, state)
          return
        end

        if type == :html_inline
          handle_html_inline(node, chars, line_starts, state)
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
          emit_span(spans, start_offset, end_offset, state) if state[:stack].empty?
          return
        end

        if %i[paragraph heading table_cell].include?(type)
          # A fresh top-level inline-bearing container: the raw-HTML skip stack resets here (an
          # unclosed skipped start tag skips to the end of the block, modes.md 3.7.3).
          state[:stack] = []
        end

        node.each { |child| walk(child, chars, line_starts, spans, state) }
      end
      private_class_method :walk

      def self.handle_html_block(node, chars, line_starts, spans, state)
        sp = node.source_position
        start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
        end_offset = offset_of(line_starts, sp[:end_line], sp[:end_column]) + 1
        return if end_offset <= start_offset

        text = chars[start_offset...end_offset].join
        Html.html_spans(text).each do |s|
          emit_span(spans, start_offset + s.start, start_offset + s.end, state)
        end
      end
      private_class_method :handle_html_block

      def self.handle_html_inline(node, chars, line_starts, state)
        sp = node.source_position
        start_offset = offset_of(line_starts, sp[:start_line], sp[:start_column])
        end_offset = offset_of(line_starts, sp[:end_line], sp[:end_column]) + 1
        raw = chars[start_offset...end_offset]
        name, closing, self_closing = Html.read_tag(raw) || [nil, nil, nil]
        return if name.nil?

        stack = state[:stack]
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

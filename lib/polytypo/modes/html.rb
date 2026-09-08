# frozen_string_literal: true

require_relative "spans"
require_relative "parse_error"
require_relative "../engine/codepoints"

module Polytypo
  module Modes
    # HTML span extraction via a minimal, hand-rolled, position-tracking tokenizer -- not
    # `nokogiri` (ARCHITECTURE.md section 2 names it for Ruby, but verified this session that
    # neither its DOM (`Nokogiri::XML::Text#line`, line number only, no column) nor its SAX
    # callbacks (no position argument at all) give the exact character-level offsets the span
    # model needs). Mirrors what Python's `html.parser` and Go's `x/net/html` low-level
    # `Tokenizer` already do for the same reason: neither is a full HTML5 tree-construction
    # implementation either, and this does not need to be one.
    #
    # Operates directly on Ruby's code-point-indexed String -- no separate byte/char offset
    # conversion is needed here the way Go's port needed one for its byte-oriented tokenizer.
    module Html
      # modes.md 3.6, exhaustive and CLOSED: extending it is a spec change, not an implementation
      # decision. svg/math are here because in MathML a quotation mark, a hyphen and a prime are
      # operators and identifiers -- substituting a curly glyph changes what the expression means.
      SKIPPED_ELEMENTS = %w[code pre kbd samp var script style textarea svg math].freeze

      # HTML5 void elements: never pushed onto the element stack, since an author is not required
      # to close them and this tokenizer never synthesizes a matching end tag for one.
      VOID_ELEMENTS = %w[area base br col embed hr img input link meta param source track wbr].freeze

      TAG_NAME_STOP = [">", "/", " ", "\t", "\n", "\r", "\f"].freeze

      def self.ascii_alpha?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
      end
      private_class_method :ascii_alpha?

      def self.ascii_alnum?(ch)
        ascii_alpha?(ch) || (ch >= "0" && ch <= "9")
      end
      private_class_method :ascii_alnum?

      def self.hex_digit?(ch)
        (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F")
      end
      private_class_method :hex_digit?

      # Byte ranges [start, end) of every well-formed character reference in chars (a code-point
      # array slice) -- &name;, &#1234;, &#x2014; -- as spec/rules/modes.md 3.6 requires them
      # treated: opaque units, split out of the surrounding text span so their exact source
      # spelling survives untouched. "Well-formed" is syntactic (shape only, matching the
      # html5lib/Python html.parser precedent this project's other ports follow), not validated
      # against the registered named-character-reference table: a bare & that begins no
      # well-formed reference is deliberately left inside its span (modes.md 3.6: "Tom & Jerry's
      # \"book\"" must not lose the pairing of its quotation marks to a spurious boundary).
      def self.find_entity_refs(chars)
        refs = []
        n = chars.length
        i = 0
        while i < n
          unless chars[i] == "&"
            i += 1
            next
          end
          start = i
          j = i + 1
          if j < n && chars[j] == "#" && j + 1 < n && (chars[j + 1] == "x" || chars[j + 1] == "X")
            k = j + 2
            k += 1 while k < n && hex_digit?(chars[k])
            if k > j + 2 && k < n && chars[k] == ";"
              refs << [start, k + 1]
              i = k + 1
              next
            end
          elsif j < n && chars[j] == "#"
            k = j + 1
            k += 1 while k < n && chars[k] >= "0" && chars[k] <= "9"
            if k > j + 1 && k < n && chars[k] == ";"
              refs << [start, k + 1]
              i = k + 1
              next
            end
          elsif j < n && ascii_alpha?(chars[j])
            k = j + 1
            k += 1 while k < n && ascii_alnum?(chars[k])
            if k < n && chars[k] == ";"
              refs << [start, k + 1]
              i = k + 1
              next
            end
          end
          i += 1
        end
        refs
      end
      private_class_method :find_entity_refs

      # Parses "<name ...>", "</name>" or "<name .../>" (as an array of chars) into
      # [name, closing, self_closing]. Comments, declarations and processing instructions
      # ("<!--", "<!", "<?") have no element name and return name == nil.
      def self.read_tag(chars)
        return nil if chars.empty? || chars[0] != "<"

        i = 1
        closing = i < chars.length && chars[i] == "/"
        i += 1 if closing
        return nil if i >= chars.length || chars[i] == "!" || chars[i] == "?"
        return nil unless ascii_alpha?(chars[i])

        name_start = i
        i += 1 while i < chars.length && !TAG_NAME_STOP.include?(chars[i])
        name = chars[name_start...i].join.downcase
        self_closing = chars.join.rstrip.end_with?("/>")
        [name, closing, self_closing]
      end
      # Public: also used by Markdown for its inline-raw-HTML tag-stack handling.

      def self.last_stack_index(stack, tag)
        stack.rindex(tag)
      end
      private_class_method :last_stack_index

      # Locates the processable spans of an HTML document. The tokenizer is used only to locate
      # spans and is then discarded (modes.md 4: "the document is never serialised") --
      # attributes, tag syntax and entity spelling are never touched.
      def self.html_spans(source)
        cp = Polytypo::Engine::Codepoints.to_codepoints(source)
        chars = cp.map { |c| [c].pack("U") }
        n = chars.length

        spans = []
        stack = []
        skip_depth = 0
        i = 0

        ParseError.wrap do
          while i < n
            if chars[i] == "<"
              tag_end = find_tag_end(chars, i)
              if tag_end.nil?
                # A bare "<" with no closing ">" before EOF: the rest of the document is text.
                emit_text(spans, chars, i, n, skip_depth)
                i = n
                next
              end

              tag_chars = chars[i...tag_end]
              parsed = read_tag(tag_chars)
              if parsed
                name, closing, self_closing = parsed
                if closing
                  idx = last_stack_index(stack, name)
                  if idx
                    popped = stack[idx..]
                    stack = stack[0...idx]
                    popped.each { |n2| skip_depth -= 1 if SKIPPED_ELEMENTS.include?(n2) }
                  end
                elsif self_closing || VOID_ELEMENTS.include?(name)
                  # Opens and closes atomically; no persistent stack effect regardless of the
                  # tag's identity, since there is no subsequent content inside it to skip.
                else
                  stack << name
                  skip_depth += 1 if SKIPPED_ELEMENTS.include?(name)
                end
              end
              # Comments/declarations/processing instructions (parsed.nil?) have no stack effect.
              i = tag_end
            else
              text_end = i
              text_end += 1 while text_end < n && chars[text_end] != "<"
              emit_text(spans, chars, i, text_end, skip_depth)
              i = text_end
            end
          end
        end

        spans
      end

      # Finds the index just past the ">" that closes the tag starting at chars[start] == "<",
      # honoring comments ("<!--" ... "-->") and quoted attribute values so a ">" inside either
      # does not end the tag early. Returns nil if unterminated.
      def self.find_tag_end(chars, start)
        n = chars.length
        if chars[start, 4] == ["<", "!", "-", "-"]
          close = index_of_sequence(chars, ["-", "-", ">"], start + 4)
          return close.nil? ? nil : close + 3
        end

        i = start + 1
        quote = nil
        while i < n
          ch = chars[i]
          if quote
            quote = nil if ch == quote
          elsif ch == "\"" || ch == "'"
            quote = ch
          elsif ch == ">"
            return i + 1
          end
          i += 1
        end
        nil
      end
      private_class_method :find_tag_end

      def self.index_of_sequence(chars, seq, from)
        n = chars.length
        m = seq.length
        i = from
        while i + m <= n
          return i if chars[i, m] == seq

          i += 1
        end
        nil
      end
      private_class_method :index_of_sequence

      def self.emit_text(spans, chars, from, to, skip_depth)
        return if skip_depth != 0 || to <= from

        slice = chars[from...to]
        refs = find_entity_refs(slice)
        cursor = 0
        refs.each do |ref_start, ref_end|
          spans << Spans::Span.new(from + cursor, from + ref_start) if ref_start > cursor
          cursor = ref_end
        end
        spans << Spans::Span.new(from + cursor, to) if cursor < slice.length
      end
      private_class_method :emit_text
    end
  end
end

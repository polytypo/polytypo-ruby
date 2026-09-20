# frozen_string_literal: true

module Polytypo
  module Modes
    # spec/rules/modes.md 3.8. "yaml" differs from the other two document modes twice over.
    #
    # It uses NO PARSER (3.8.1): two of the five ecosystems' YAML libraries cannot report the
    # source offsets the round-trip guarantee needs, so the scan below is specified rather than
    # delegated and is written the same way in every runtime.
    #
    # And the caller names the keys (3.8.2). YAML is a data format with islands of prose in it --
    # the inverse of HTML and Markdown -- and nothing in its syntax separates "description:" from
    # "run:". A keyless draft of this file rewrote "if !" as "if!" inside a workflow's shell
    # script; there is no content test that would not, because shell and template expressions are
    # written in words.
    #
    # It also SKIPS BY DEFAULT -- the inverse of 3.6's closed skip list. A construct this scan
    # does not recognise with certainty yields no spans, so the worst outcome of a gap in it is
    # prose left untypeset, never a changed byte.
    module Yaml
      SPACE = " "
      TAB = "\t"
      LF = "\n"
      CR = "\r"
      DECLINING_KEY_CHARS = ['"', "'", "{", "[", "&", "*", "!", "#"].freeze
      NON_SCALAR_VALUE_CHARS = ["#", "&", "*", "!", "{", "["].freeze

      Line = Struct.new(:start, :end)

      # Offsets are code-point indices, like every Span in this runtime (ARCHITECTURE.md 4.2).
      def self.yaml_spans(source, keys)
        chars = source.chars
        lines = split_lines(chars)
        spans = []
        li = 0
        li = scan_line(chars, lines, li, keys, spans) while li < lines.length
        spans
      end

      # 3.8.4: a line ends at U+000A, and A U+000D IMMEDIATELY BEFORE IT IS NOT PART OF THE LINE
      # -- it is a terminator like the U+000A itself, so it lies outside every span and comes back
      # untouched. Without that clause a CRLF file behaves differently from the same bytes with
      # LF: the block header reads as "|\r" and is unrecognised, and a plain scalar carries the
      # carriage return inside its span. Five runtimes split lines with five different standard
      # library calls, so the treatment has to be stated rather than inherited.
      def self.split_lines(chars)
        lines = []
        start = 0
        end_of = ->(i) { i > start && chars[i - 1] == CR ? i - 1 : i }
        chars.each_with_index do |ch, i|
          next unless ch == LF

          lines << Line.new(start, end_of.call(i))
          start = i + 1
        end
        lines << Line.new(start, end_of.call(chars.length)) if start < chars.length
        lines
      end
      private_class_method :split_lines

      def self.first_non_space(chars, line)
        i = line.start
        i += 1 while i < line.end && chars[i] == SPACE
        i
      end
      private_class_method :first_non_space

      def self.blank?(chars, line)
        first_non_space(chars, line) == line.end
      end
      private_class_method :blank?

      def self.tab?(chars, line)
        (line.start...line.end).any? { |i| chars[i] == TAB }
      end
      private_class_method :tab?

      # 3.8.4 step 3. "---" and "..." at the head of a line, bare or introducing a node: the
      # trailing-content form is declined too, so "--- key: value" never yields a key of
      # "--- key".
      def self.document_marker?(chars, from, to)
        return false if to - from < 3

        c = chars[from]
        return false unless ["-", "."].include?(c)
        return false unless chars[from + 1] == c && chars[from + 2] == c

        from + 3 == to || chars[from + 3] == SPACE
      end
      private_class_method :document_marker?

      # A colon that ends the line or is followed by U+0020 -- the only colon YAML reads as an
      # indicator.
      def self.indicator_colon?(chars, j, to)
        return false unless chars[j] == ":"

        j + 1 == to || chars[j + 1] == SPACE
      end
      private_class_method :indicator_colon?

      def self.sequence_dash?(chars, j, to)
        return false unless chars[j] == "-"

        j + 1 == to || chars[j + 1] == SPACE
      end
      private_class_method :sequence_dash?

      # The value run of 3.8.4 step 7: every following line that is blank or indented more than
      # the key line. THOSE LINES ARE NEVER SCANNED AGAIN -- without that, a multi-line quoted
      # scalar, a multi-line flow collection and a folded plain scalar all leak their continuation
      # lines back into the scan as if they were mappings, and a span can end up holding a
      # scalar's own closing delimiter.
      def self.value_run_end(chars, lines, li, indent)
        k = li + 1
        while k < lines.length
          nxt = lines[k]
          break if !blank?(chars, nxt) && first_non_space(chars, nxt) - nxt.start <= indent

          k += 1
        end
        k
      end
      private_class_method :value_run_end

      # One step of 3.8.4. Returns the index of the next line to scan.
      def self.scan_line(chars, lines, li, keys, spans)
        line = lines[li]
        skip_line = li + 1

        # step 1 -- blank, or a tab anywhere, which makes indentation undecidable.
        start = first_non_space(chars, line)
        return skip_line if start == line.end || tab?(chars, line)

        indent = start - line.start

        # steps 2 and 3 -- comment, directive, document marker.
        return skip_line if ["#", "%"].include?(chars[start])
        return skip_line if document_marker?(chars, start, line.end)

        # step 4 -- block sequence entries are consumed, not skipped; "- - key: v" nests.
        i = start
        while i < line.end && sequence_dash?(chars, i, line.end)
          i += 2
          i += 1 while i < line.end && chars[i] == SPACE
        end
        return skip_line if i >= line.end

        # step 5 -- find the key. A colon NOT followed by U+0020 or the line end is an ordinary
        # key character, so "a:b: v" has the key "a:b"; stating that is what keeps five scanners
        # agreeing.
        key_start = i
        colon = -1
        (i...line.end).each do |j|
          return skip_line if DECLINING_KEY_CHARS.include?(chars[j])

          if indicator_colon?(chars, j, line.end)
            colon = j
            break
          end
        end
        return skip_line if colon.negative?

        key_end = colon
        key_end -= 1 while key_end > key_start && chars[key_end - 1] == SPACE
        return skip_line if key_end <= key_start

        # step 6 -- an empty value means a nested node, whose lines ARE scanned on their own.
        v = colon + 1
        v += 1 while v < line.end && chars[v] == SPACE
        return skip_line if v >= line.end

        # step 7 -- the line carries an inline value, so its continuation lines belong to it.
        nxt = value_run_end(chars, lines, li, indent)

        # step 8 -- the key must be listed. Checked before the value's form, so an unlisted key
        # costs nothing to decline: this is what makes "run:", "if:" and "image:" unreachable.
        return nxt unless keys.include?(chars[key_start...key_end].join)

        # step 9 -- the scalar form.
        value = chars[v]
        return nxt if NON_SCALAR_VALUE_CHARS.include?(value)

        if ["|", ">"].include?(value)
          block_scalar(chars, line, lines[(li + 1)...nxt], indent, v, spans)
        elsif ['"', "'"].include?(value)
          quoted_scalar(chars, line, v, spans) if nxt == li + 1
        elsif nxt == li + 1
          plain_scalar(chars, line, v, spans)
        end
        nxt
      end
      private_class_method :scan_line

      # 3.8.5. One span per non-blank content line, starting after the block's own indentation.
      # The header, the indentation and every line terminator lie outside every span -- including
      # the run of line terminators at the end that the chomping indicator governs, which is why
      # "|", "|-", "|+", ">", ">-" and ">+" are handled identically here.
      def self.block_scalar(chars, line, run_lines, indent, v, spans)

        # The header: at most one chomping indicator and at most one indentation indicator, in
        # either order, then optional spaces and an optional comment. Anything else is
        # unrecognised.
        h = v + 1
        explicit_indent = 0
        chomping = false
        while h < line.end
          c = chars[h]
          if ["-", "+"].include?(c) && !chomping
            chomping = true
            h += 1
          elsif c >= "1" && c <= "9" && explicit_indent.zero?
            explicit_indent = c.ord - "0".ord
            h += 1
          else
            break
          end
        end
        h += 1 while h < line.end && chars[h] == SPACE
        return if h < line.end && chars[h] != "#"

        # One definition of the run, and three conditions that make the whole block yield no
        # spans.
        content = []
        content_indent = -1
        run_lines.each do |nxt|
          next if blank?(chars, nxt) # blank lines belong to the block and yield no span

          # A tab makes indentation undecidable; an explicit indicator that disagrees with the
          # block as written, or a later line dedented inside it, is ambiguous rather than
          # guessable. All three make the WHOLE block yield no spans -- bail rather than choose.
          break content_indent = -1 if tab?(chars, nxt)

          next_indent = first_non_space(chars, nxt) - nxt.start
          if content_indent.negative?
            content_indent = explicit_indent.positive? ? indent + explicit_indent : next_indent
          end
          break content_indent = -1 if next_indent < content_indent

          content << nxt
        end
        return if content_indent <= 0

        content.each do |c_line|
          from = c_line.start + content_indent
          spans << Spans::Span.new(from, c_line.end) if c_line.end > from
        end
      end
      private_class_method :block_scalar

      # 3.8.6. The span is the content between the quotes. Both bails exist so that source
      # characters and content characters are the same thing, which the offset model of 3.1
      # requires -- the same constraint that makes an HTML character reference an opaque unit in
      # 3.6. No colon test applies here: quoting neutralises the colon, and applying the
      # plain-scalar test would decline `title: "Chapter 1: the beginning"`.
      def self.quoted_scalar(chars, line, v, spans)
        quote = chars[v]
        close = -1
        j = v + 1
        while j < line.end
          c = chars[j]
          return if quote == '"' && c == "\\"
          return if quote == "'" && c == "'" && j + 1 < line.end && chars[j + 1] == "'"

          if c == quote
            close = j
            break
          end
          j += 1
        end
        return if close.negative?

        after = close + 1
        after += 1 while after < line.end && chars[after] == SPACE
        return if after < line.end && chars[after] != "#"

        spans << Spans::Span.new(v + 1, close) if close > v + 1
      end
      private_class_method :quoted_scalar

      # 3.8.6. In a plain scalar ":" and "#" are still live: U+0020 beside either of them is what
      # turns a scalar into a mapping indicator or a comment, and `dashes` emits U+0020 in every
      # "-spaced" locale. Lifting both out as opaque units puts the dash token at a span
      # extremity, where the edge-growth rule of 3.4 discards the replacement that emits one.
      def self.plain_scalar(chars, line, v, spans)
        # The scalar ends before a trailing comment, so a colon inside that comment is not the
        # scalar's and must not decline it.
        to = line.end
        (v...line.end).each do |j|
          if chars[j] == "#" && j > v && chars[j - 1] == SPACE
            to = j - 1
            break
          end
        end
        to -= 1 while to > v && chars[to - 1] == SPACE
        return if to <= v

        # Compact nesting is not a value: "key: - item" opens a sequence, and "key: a .:" is a
        # mapping whose key is "a ." -- a plain scalar can never contain a colon in that position.
        return if sequence_dash?(chars, v, line.end)
        return if (v...to).any? { |j| indicator_colon?(chars, j, line.end) }

        segment = v
        (v..to).each do |j|
          next unless j == to || [":", "#"].include?(chars[j])

          spans << Spans::Span.new(segment, j) if j > segment
          segment = j + 1
        end
      end
      private_class_method :plain_scalar
    end
  end
end

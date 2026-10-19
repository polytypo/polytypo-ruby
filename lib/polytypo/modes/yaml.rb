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
        drop_carriage_return_regions(chars, lines, spans)
      end

      # 3.8.4's carriage-return region: a line containing a U+000D yields no spans, and neither does
      # any later line up to the first one that is non-empty, does not begin with U+0020 and
      # contains none. It removes spans and never adds one.
      def self.drop_carriage_return_regions(chars, lines, spans)
        in_region = false
        declined = lines.map do |line|
          if lone_cr?(chars, line)
            in_region = true
          elsif line.end > line.start && chars[line.start] != " "
            in_region = false
          end
          in_region
        end
        return spans unless declined.any?

        li = 0
        spans.reject do |span|
          li += 1 while li + 1 < lines.length && span.start >= lines[li + 1].start
          declined[li]
        end
      end
      private_class_method :drop_carriage_return_regions

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

      # 3.8.4 step 7: a line of the value run that is not blank. Blank lines alone are not one.
      def self.continuation?(chars, lines, li, run_end)
        ((li + 1)...run_end).any? { |k| !blank?(chars, lines[k]) }
      end
      private_class_method :continuation?

      def self.tab?(chars, line)
        (line.start...line.end).any? { |i| chars[i] == TAB }
      end
      private_class_method :tab?

      # A U+000D the line definition did not take for a terminator, i.e. one that is not part of
      # a CRLF and does not end the input. It would otherwise land inside a span.
      def self.lone_cr?(chars, line)
        (line.start...line.end).any? { |i| chars[i] == CR }
      end
      private_class_method :lone_cr?

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

      # 3.8.4 step 5: the index of the quote that closes the one at q, or -1. In a double-quoted
      # scalar a U+005C and the code point after it never close the quote, which decodes nothing:
      # no YAML escape ends in anything that would be a closing quote. A quote not closed on the
      # line returns -1.
      def self.closing_quote(chars, line, q)
        quote = chars[q]
        j = q + 1
        while j < line.end
          c = chars[j]
          if quote == '"' && c == "\\"
            j += 2
          elsif c != quote
            j += 1
          elsif quote == "'" && j + 1 < line.end && chars[j + 1] == "'"
            j += 2
          else
            return j
          end
        end
        -1
      end
      private_class_method :closing_quote

      # 3.8.4 step 3: the next line that begins in column 0 with a document marker.
      def self.document_run_end(chars, lines, li)
        k = li + 1
        k += 1 while k < lines.length && !document_marker?(chars, lines[k].start, lines[k].end)
        k
      end
      private_class_method :document_run_end

      # 3.8.4 step 5's own-line node: everything up to the first later line that is non-empty and
      # does not begin with U+0020, because the scan does not track the key above.
      def self.own_line_run_end(chars, lines, li, indent)
        return document_run_end(chars, lines, li) if indent.zero?

        k = li + 1
        while k < lines.length
          nxt = lines[k]
          break if nxt.end > nxt.start && chars[nxt.start] != SPACE

          k += 1
        end
        k
      end
      private_class_method :own_line_run_end

      # 3.8.4 step 4: "-", "?" or ":" followed by U+0020 or the line end.
      def self.node_marker?(chars, j, to)
        return false unless ["-", "?", ":"].include?(chars[j])

        j + 1 == to || chars[j + 1] == SPACE
      end
      private_class_method :node_marker?

      # 3.8.4 step 5. Returns [colon, key_end, declined, open_quote]; colon is -1 for a line with
      # no key, which is a node line.
      def self.locate_key(chars, line, i)
        first = chars[i]
        if ['"', "'"].include?(first)
          close = closing_quote(chars, line, i)
          return [-1, -1, false, true] if close.negative?

          p = close + 1
          p += 1 while p < line.end && chars[p] == SPACE
          return [p, close + 1, true, false] if p < line.end && indicator_colon?(chars, p, line.end)

          return [-1, -1, false, false]
        end
        return [-1, -1, false, false] if ["{", "[", "&", "*", "!"].include?(first)

        declined = false
        (i...line.end).each do |j|
          c = chars[j]
          break if c == "#" && chars[j - 1] == SPACE

          if indicator_colon?(chars, j, line.end)
            key_end = j
            key_end -= 1 while key_end > i && chars[key_end - 1] == SPACE
            return [j, key_end, declined, false]
          end
          declined = true if DECLINING_KEY_CHARS.include?(c)
        end
        [-1, -1, false, false]
      end
      private_class_method :locate_key

      # 3.8.4 step 7: whether a declined key's value can continue on the next line.
      def self.declined_value_open?(chars, line, v)
        value = chars[v]
        return true if ["|", ">", "{", "[", "&", "!"].include?(value)
        return false unless ['"', "'"].include?(value)

        close = closing_quote(chars, line, v)
        return true if close.negative?

        p = close + 1
        p += 1 while p < line.end && chars[p] == SPACE
        p < line.end && chars[p] != "#"
      end
      private_class_method :declined_value_open?

      # One step of 3.8.4. Returns the index of the next line to scan.
      def self.scan_line(chars, lines, li, keys, spans)
        line = lines[li]
        skip_line = li + 1

        # step 1 -- blank. A tab makes indentation undecidable, so the line and whatever it
        # absorbs yield no spans, but steps 2 to 7 still decide what it absorbs.
        start = first_non_space(chars, line)
        return skip_line if start == line.end

        quiet = tab?(chars, line)
        indent = start - line.start

        # steps 2 and 3 -- comment, directive, document marker. A marker with a node after it
        # absorbs the document.
        return skip_line if ["#", "%"].include?(chars[start])

        if document_marker?(chars, start, line.end)
          p = start + 3
          p += 1 while p < line.end && chars[p] == SPACE
          return skip_line if p >= line.end || chars[p] == "#"

          return indent.zero? ? document_run_end(chars, lines, li) : skip_line
        end

        # step 4 -- node markers are consumed, not skipped; "- - key: v" nests.
        i = start
        while i < line.end && node_marker?(chars, i, line.end)
          i += 2
          i += 1 while i < line.end && chars[i] == SPACE
        end
        return skip_line if i >= line.end || chars[i] == "#"

        # step 5 -- find the key. A colon NOT followed by U+0020 or the line end is an ordinary
        # key character, so "a:b: v" has the key "a:b"; stating that is what keeps five scanners
        # agreeing.
        colon, key_end, declined, open_quote = locate_key(chars, line, i)

        # No key: the line is a node of its own, and it absorbs its value run. One that opens a
        # flow collection, a block scalar or a quote and sits on a line of its own absorbs the
        # region.
        if colon.negative?
          own_line = i == start && (open_quote || ["{", "[", "|", ">"].include?(chars[i]))
          return own_line_run_end(chars, lines, li, indent) if own_line

          return value_run_end(chars, lines, li, indent)
        end

        # step 6 -- an empty value means a nested node, whose lines ARE scanned on their own.
        v = colon + 1
        v += 1 while v < line.end && chars[v] == SPACE
        return skip_line if v >= line.end

        # step 7 -- the line carries an inline value, so its continuation lines belong to it. A
        # declined key's value absorbs them only if it can continue on the next line.
        if declined
          return declined_value_open?(chars, line, v) ? value_run_end(chars, lines, li, indent) : skip_line
        end

        nxt = value_run_end(chars, lines, li, indent)

        # step 8 -- the key must be listed. Checked before the value's form, so an unlisted key
        # costs nothing to decline: this is what makes "run:", "if:" and "image:" unreachable.
        return nxt unless keys.include?(chars[i...key_end].join)
        return nxt if quiet

        # step 9 -- the scalar form.
        value = chars[v]
        return nxt if NON_SCALAR_VALUE_CHARS.include?(value)

        if ["|", ">"].include?(value)
          block_scalar(chars, line, lines[(li + 1)...nxt], indent, v, spans)
        elsif ['"', "'"].include?(value)
          quoted_scalar(chars, line, v, spans) unless continuation?(chars, lines, li, nxt)
        elsif !continuation?(chars, lines, li, nxt)
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

        # One definition of the run, and four conditions that make the whole block yield no
        # spans.
        content = []
        content_indent = -1
        run_lines.each do |nxt|
          next if blank?(chars, nxt) # blank lines belong to the block and yield no span

          # A tab makes indentation undecidable, and a lone U+000D would land inside a span; an
          # explicit indicator that disagrees with the block as written, or a later line dedented
          # inside it, is ambiguous rather than guessable. All of them make the WHOLE block yield
          # no spans -- bail rather than choose.
          break content_indent = -1 if tab?(chars, nxt) || lone_cr?(chars, nxt)

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

      # 3.8.6. The span is the content between the quotes. A backslash in a double-quoted scalar
      # bails, so that source characters and content characters are the same thing, which the
      # offset model of 3.1 requires. In a single-quoted scalar each doubled apostrophe is an
      # opaque two-code-point unit that lies outside every span, the same treatment an HTML
      # character reference gets in 3.6; the scalar's range is split around it. No colon test
      # applies here: quoting neutralises the colon, and applying the plain-scalar test would
      # decline `title: "Chapter 1: the beginning"`.
      def self.quoted_scalar(chars, line, v, spans)
        quote = chars[v]
        starts = []
        close = -1
        segment = v + 1
        j = v + 1
        while j < line.end
          c = chars[j]
          return if quote == '"' && c == "\\"

          if c == quote
            if quote == "'" && j + 1 < line.end && chars[j + 1] == "'"
              starts << [segment, j] if j > segment
              segment = j + 2
              j += 2
              next
            end
            close = j
            break
          end
          j += 1
        end
        return if close.negative?

        after = close + 1
        after += 1 while after < line.end && chars[after] == SPACE
        return if after < line.end && chars[after] != "#"

        starts << [segment, close] if close > segment
        starts.each { |from, to| spans << Spans::Span.new(from, to) }
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

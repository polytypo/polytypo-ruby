# frozen_string_literal: true

require_relative "../edits"
require_relative "../sentinels"
require_relative "../unicode_util"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # spec/rules/spaces.md. No regex anywhere (ARCHITECTURE.md section 4.1): a single
      # left-to-right scan over the code-point array with explicit lookaround by index. Reads no
      # locale data (spec/rules/spaces.md section 2): behaviour is identical in every locale.
      module Spaces
        SPACE = 0x20

        LF = 0x0A
        CR = 0x0D
        VT = 0x0B
        FF = 0x0C
        NEL = 0x85
        LS = 0x2028
        PS = 0x2029

        COMMA = 0x2C
        FULL_STOP = 0x2E
        SEMICOLON = 0x3B
        COLON = 0x3A
        EXCLAMATION = 0x21
        QUESTION = 0x3F
        ELLIPSIS = 0x2026

        PAREN_OPEN = 0x28
        PAREN_CLOSE = 0x29
        SQUARE_OPEN = 0x5B
        SQUARE_CLOSE = 0x5D
        CURLY_OPEN = 0x7B
        CURLY_CLOSE = 0x7D

        HYPHEN_MINUS = 0x2D
        CARET = 0x5E
        SOLIDUS = 0x2F
        REVERSE_SOLIDUS = 0x5C
        VERTICAL_LINE = 0x7C
        ASTERISK = 0x2A
        DIGIT_ZERO = 0x30
        DIGIT_NINE = 0x39
        LETTER_D_UPPER = 0x44
        LETTER_D_LOWER = 0x64
        LETTER_P_UPPER = 0x50
        LETTER_P_LOWER = 0x70
        LETTER_O_UPPER = 0x4F
        LETTER_O_LOWER = 0x6F

        # cp[i], or NONE if i is out of bounds -- the spec's own boundary value.
        def self.at(cp, i)
          return NONE if i.negative? || i >= cp.length

          cp[i]
        end

        # BREAK (spaces.md 3.1), including LINE_MARKER: a member of BREAK for every rule,
        # everywhere (modes.md 3.2).
        def self.break?(value)
          value == LF || value == CR || value == VT || value == FF ||
            value == NEL || value == LS || value == PS || value == LINE_MARKER
        end

        # STRIP-BEFORE: exactly six code points. U+2026 is deliberately absent -- with it,
        # "Wait ..." would keep its space here, `ellipsis` would yield "Wait …", and a second
        # pipeline pass would then strip that space, a composition divergence (spaces.md 3.4).
        def self.strip_before?(value)
          value == COMMA || value == FULL_STOP || value == SEMICOLON ||
            value == COLON || value == EXCLAMATION || value == QUESTION
        end

        def self.dotlike?(value)
          value == FULL_STOP || value == ELLIPSIS
        end

        def self.open_bracket?(value)
          value == PAREN_OPEN || value == SQUARE_OPEN || value == CURLY_OPEN
        end

        def self.close_bracket?(value)
          value == PAREN_CLOSE || value == SQUARE_CLOSE || value == CURLY_CLOSE
        end

        def self.matching_closer(open)
          return PAREN_CLOSE if open == PAREN_OPEN
          return SQUARE_CLOSE if open == SQUARE_OPEN

          CURLY_CLOSE
        end

        # spaces.md 3.3: "- [ ] item" must not become "- [] item". The run may still collapse to
        # length 1.
        def self.empty_bracket_guarded?(left, right)
          open_bracket?(left) && right == matching_closer(left)
        end

        # spaces.md 3.4. A run of dots is a different token from a terminal full stop -- a
        # relative path, a truncation, a typed ellipsis -- and deleting the space before it
        # merges the run with a preceding abbreviation dot ("See ../docs" -> "See../docs").
        #
        # `e` indexes `right` in the input array, and the run is measured there. Measuring it
        # after any edit had been applied would break the Chicago spaced ellipsis
        # "Hello . . .", where every dot is a lone dot at decision time and all three spaces
        # must still strip.
        #
        # Spec 1.2.0's word-start clause: a single dot directly followed by a letter or an ASCII
        # digit starts a token (".NET", ".env", ".5"), so "Use .NET" keeps its space. A span
        # boundary marker after the dot is neither, so "a .</em>" still strips.
        def self.lone_dot?(cp, e)
          return true if at(cp, e) != FULL_STOP

          after = at(cp, e + 1)
          return false if UnicodeUtil.letter?(after) || digit_ascii?(after)

          !dotlike?(after)
        end

        def self.digit_ascii?(value)
          value >= DIGIT_ZERO && value <= DIGIT_NINE
        end

        # spaces.md 3.6: the recognised "mouth" glyphs of a Western text emoticon.
        def self.emoticon_mouth?(value)
          value == PAREN_OPEN || value == PAREN_CLOSE || value == SQUARE_OPEN ||
            value == SQUARE_CLOSE || value == LETTER_D_UPPER || value == LETTER_D_LOWER ||
            value == LETTER_P_UPPER || value == LETTER_P_LOWER ||
            value == LETTER_O_UPPER || value == LETTER_O_LOWER ||
            value == SOLIDUS || value == REVERSE_SOLIDUS ||
            value == VERTICAL_LINE || value == ASTERISK
        end

        # spaces.md 3.6, the emoticon guard's eye side. A colon or semicolon immediately
        # followed by an optional "nose" and a recognised "mouth" is the eye of a Western text
        # emoticon (":-)", ":)", ";-)"), not sentence punctuation, and the space in front of it
        # must survive.
        #
        # The mouth must not itself run into a letter or an ASCII digit -- ":Deal" is a colon
        # before a capitalised word, not a face -- which is the one check needed to keep this
        # from firing on ordinary prose. `e` indexes `right`, exactly as `lone_dot?` does.
        def self.emoticon_eye_fires?(cp, e)
          eye = at(cp, e)
          return false unless eye == COLON || eye == SEMICOLON

          i = e + 1
          nose = at(cp, i)
          i += 1 if nose == HYPHEN_MINUS || nose == CARET

          return false unless emoticon_mouth?(at(cp, i))

          i += 1
          after = at(cp, i)
          !UnicodeUtil.letter?(after) && !digit_ascii?(after)
        end

        # spaces.md 3.6, the mouth side. "(" and "[" are EMOTICON-MOUTH members and
        # OPEN-BRACKET members at once, so without this the opening-bracket clause deleted the
        # space after an emoticon the eye side had just recognised: "a :( b" became "a :(b",
        # and then "a:(b" on a second pass, because a letter after the mouth stops the eye side
        # firing.
        #
        # The walk mirrors the eye side's, backwards from `s`, and needs no trailing check: the
        # code point after the mouth is the space run itself, which is neither a letter nor a
        # digit. A nose with no eye behind it is not a face -- EMOTICON-NOSE and EMOTICON-EYE
        # are disjoint, so the walk cannot mistake one for the other.
        def self.emoticon_mouth_fires?(cp, s)
          return false unless emoticon_mouth?(at(cp, s - 1))

          j = s - 2
          nose = at(cp, j)
          j -= 1 if nose == HYPHEN_MINUS || nose == CARET

          eye = at(cp, j)
          eye == COLON || eye == SEMICOLON
        end

        # spaces.md 3.2 step 5: the replacement length is a pure function of the two bounding
        # code points, computed once. A two-pass "collapse then strip" formulation would need a
        # fixed-point loop, which two runtimes would iterate differently.
        def self.replacement_length(cp, s, e, left, right)
          # The guard is a clause of this decision, not a "skip the run" branch: "(  )"
          # collapses to "( )" (spaces.md 3.3, normative reading).
          return 1 if empty_bracket_guarded?(left, right)
          return 0 if open_bracket?(left) && !emoticon_mouth_fires?(cp, s)
          return 0 if close_bracket?(right)
          return 0 if strip_before?(right) && lone_dot?(cp, e) && !emoticon_eye_fires?(cp, e)

          1
        end

        # locale_data is unused: order.json declares "localeData": [] for this rule.
        def self.scan(cp, _locale_data, _ctx)
          n = cp.length
          edits = []
          i = 0

          while i < n
            if at(cp, i) != SPACE
              i += 1
              next
            end

            s = i
            e = s
            e += 1 while e < n && at(cp, e) == SPACE
            k = e - s

            left = at(cp, s - 1)
            right = at(cp, e)

            # Boundary guard (3.2 step 4): indentation, Markdown hard breaks and text-unit
            # edges are structural. A span boundary marker counts as NONE here -- the one place
            # in the whole spec where a marker is not opaque content, per modes.md 3.3.
            if left == NONE || Polytypo::Engine.marker?(left) || break?(left) ||
               right == NONE || Polytypo::Engine.marker?(right) || break?(right)
              i = e
              next
            end

            length = replacement_length(cp, s, e, left, right)
            if length != k
              replacement = length.zero? ? [] : [SPACE]
              edits << Edit.new(s, e, replacement, "spaces")
            end
            i = e
          end

          edits
        end
      end
    end

    Registry.register("spaces", ->(cp, locale_data, ctx) { Rules::Spaces.scan(cp, locale_data, ctx) })
  end
end

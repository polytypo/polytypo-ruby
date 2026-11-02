# frozen_string_literal: true

require_relative "dash_shared"
require_relative "../edits"
require_relative "../sentinels"
require_relative "../unicode_util"

module Polytypo
  module Engine
    module Rules
      # `dash.parenthetical = "em-paired"` -- spec/rules/dashes.md 3.4a. The pair is written with a
      # space outside it and none inside (`Llego —por fin— a casa`), which no per-token rule can
      # express: which stroke opens and which closes is a property of the sentence, not of the
      # token. A sentence is converted only when it holds exactly two counted strokes and both are
      # eligible; anything else is left as typed. Mirrors dashes-paired.ts in the JS reference
      # implementation.
      module DashesPaired
        # One counted DASH run of a segment: its span [s, e), outer spacing, the flanking indices
        # after the joiner walk, and whether it may take part in a conversion.
        Run = Struct.new(:s, :e, :lsp, :rsp, :left, :right, :eligible, keyword_init: true)

        TERMINALS = [0x2e, 0x3f, 0x21, 0x2026].freeze

        module_function

        def terminal?(cp)
          TERMINALS.include?(cp)
        end

        # A terminal ends a segment only before a space (U+0020 or a no-break space, which `nbsp`
        # puts there later), a line break, a marker or the end of input.
        def ends_segment?(cp, i)
          return false unless terminal?(cp[i])
          return true if i + 1 >= cp.length

          nxt = cp[i + 1]
          nxt == DashShared::SPACE || DashShared.no_break_space?(nxt) || DashShared.break?(nxt) ||
            Polytypo::Engine.marker?(nxt)
        end

        def wants_space?(cp)
          Polytypo::Engine::UnicodeUtil.letter?(cp) || DashShared.digit?(cp)
        end

        # dashes.md 3.2 steps 5-7: content on the same line, no dash or space beside the stroke's
        # outer spacing, and not part of a cluster holding another dash run.
        def neighbours_clean?(cp, s, e, left, right)
          left_cp = cp[left]
          right_cp = cp[right]
          return false if DashShared.break?(left_cp) || DashShared.break?(right_cp)
          return false if DashShared.inert_dash?(left_cp) || DashShared.inert_dash?(right_cp)
          return false if DashShared.dash?(left_cp) || DashShared.dash?(right_cp)
          return false if left_cp == DashShared::SPACE || DashShared.no_break_space?(left_cp)
          return false if right_cp == DashShared::SPACE || DashShared.no_break_space?(right_cp)

          !DashShared.cluster_inert?(cp, s, e)
        end

        # Returns nil when the run is not a stroke at all, otherwise a Run (eligible or not).
        def classify(cp, s, e)
          n = cp.length
          k = e - s
          return nil if k > 3

          lsp = s.positive? && cp[s - 1] == DashShared::SPACE ? 1 : 0
          rsp = e < n && cp[e] == DashShared::SPACE ? 1 : 0
          first = cp[s]
          is_hyphen_shaped = first == DashShared::HYPHEN_MINUS || first == DashShared::HYPHEN ||
                             first == DashShared::MINUS_SIGN
          # A hyphen inside a word is a compound, not a stroke.
          return nil if k == 1 && is_hyphen_shaped && lsp.zero? && rsp.zero?
          # The hyphen of `+/-`, which `symbols` (order 80) turns into a plus-minus sign: counting
          # it would let that later rule change the number of strokes in the segment.
          return nil if k == 1 && first == DashShared::HYPHEN_MINUS && s >= 2 && cp[s - 1] == 0x2f && cp[s - 2] == 0x2b

          left = s - 1 - lsp
          right = e + rsp
          counted = lambda do |eligible|
            Run.new(s: s, e: e, lsp: lsp, rsp: rsp, left: left, right: right, eligible: eligible)
          end
          return counted.call(false) if left.negative? || right >= n

          join_start = left + 1
          join_end = right
          left -= 1 while left >= 0 && cp[left] == DashShared::WORD_JOINER
          right += 1 while right < n && cp[right] == DashShared::WORD_JOINER
          return counted.call(false) if left.negative? || right >= n

          crossed_joiner = left + 1 != join_start || right != join_end

          return nil unless DashShared.range_flanks(cp, left, right).nil?
          return counted.call(false) if crossed_joiner

          return counted.call(false) unless neighbours_clean?(cp, s, e, left, right)

          # A stroke spaced on one side only is eligible solely as the one em dash that is already
          # half of the target form; `-mente`, `pre-`, `--force` and `- item` are not dashes.
          return counted.call(false) if lsp != rsp && !(k == 1 && first == DashShared::EM_DASH)
          # P4: a tight stroke between two Roman numerals is a range already in its correct form.
          return counted.call(false) if lsp.zero? && rsp.zero? && Dashes.roman_flanked?(cp, left, right)
          # P5: an authored lone en dash is declined in every locale.
          return counted.call(false) if k == 1 && first == DashShared::EN_DASH

          counted.call(true)
        end

        def scan(cp)
          n = cp.length
          edits = []
          segment = []
          i = 0

          while i < n
            if DashShared.dash?(cp[i])
              s = i
              e = s
              e += 1 while e < n && DashShared.dash?(cp[e])
              i = e
              run = classify(cp, s, e)
              segment << run unless run.nil?
              next
            end

            if ends_segment?(cp, i)
              emit_pair(cp, segment[0], segment[1], edits) if segment.length == 2
              segment = []
            end
            i += 1
          end
          emit_pair(cp, segment[0], segment[1], edits) if segment.length == 2

          edits
        end

        def emit_pair(cp, a, b, edits)
          return unless a.eligible && b.eligible
          return if a.lsp.zero? && a.rsp == 1 # the first stroke is shaped like a closer
          return if b.lsp == 1 && b.rsp.zero? # the second stroke is shaped like an opener
          return if (a.e...b.s).any? { |j| DashShared.break?(cp[j]) }

          insert_before = a.lsp.zero? && wants_space?(cp[a.left])
          insert_after = b.rsp.zero? && wants_space?(cp[b.right])
          return if insert_before && DashShared.spacing_transition_blocked_left?(cp, a.left)
          return if insert_after && DashShared.spacing_transition_blocked_right?(cp, b.right)

          opener = a.lsp == 1 || insert_before ? [DashShared::SPACE, DashShared::EM_DASH] : [DashShared::EM_DASH]
          closer = b.rsp == 1 || insert_after ? [DashShared::EM_DASH, DashShared::SPACE] : [DashShared::EM_DASH]

          [[a, opener], [b, closer]].each do |run, replacement|
            span_start = run.s - run.lsp
            span_end = run.e + run.rsp
            next if DashShared.same_content?(cp, span_start, span_end, replacement)

            edits << Polytypo::Engine::Edit.new(span_start, span_end, replacement, "dashes")
          end
        end
      end
    end
  end
end

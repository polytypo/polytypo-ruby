# frozen_string_literal: true

require_relative "dash_shared"
require_relative "../edits"
require_relative "../registry"
require_relative "../unicode_util"

module Polytypo
  module Engine
    module Rules
      # `ranges` -- spec/rules/ranges.md, order 25. Explicit opt-in: off by default
      # (order.json's "default": "off" for this rule id; the pipeline's rule-plan resolution, not
      # this file, is what enforces that). Split out of `dashes` (spec 0.5.0) -- see ranges.md 1
      # and dashes.md 7.11 for why this is opt-in rather than a bounded structural fix: separating
      # a genuine numeric range (`5-10`) from a compound label sharing the identical shape
      # (`Figure 5-10`) needs the preceding word, which is exactly the open-ended, per-locale
      # context this project's rules are built never to consult.
      #
      # This module's own behaviour does not depend on whether the rule is enabled -- enable/disable
      # is the pipeline's concern (a rule's scan function only runs when it is active).
      #
      # Explicit index-based scanning only: no regex anywhere, and every index addresses the
      # code-point array, never a native string (ARCHITECTURE.md 4.1, 4.2).
      module Ranges
        SOLIDUS = 0x2f

        module_function

        # ranges.md 3.3 G5: equal-length ASCII digit runs compare lexicographically, so no integer
        # arithmetic (and no locale-dependent parsing) is needed.
        def non_decreasing?(cp, left_start, right_start, length)
          (0...length).each do |i|
            l = cp[left_start + i]
            r = cp[right_start + i]
            return true if l < r
            return false if l > r
          end
          true
        end

        # ranges.md 3.2, G1-G5, over the flanks and digit runs 3.2a's walk produced. before/after
        # read past a matched outer closed-up symbol, so G1-G3 judge the text in front of the
        # whole member rather than the symbol itself -- which is what declines "US$15-$20" on G1.
        def guards_pass?(cp, flanks)
          left = flanks.left
          right = flanks.right
          a = flanks.a
          b = flanks.b

          before_from = flanks.outer_left || a
          after_from = flanks.outer_right || b
          before = DashShared.effective_neighbour(cp, before_from - 1, -1)
          after = DashShared.effective_neighbour(cp, after_from + 1, 1)

          # G1 -- no letter adjacency.
          return false if Polytypo::Engine::UnicodeUtil.letter?(before)

          # G2 -- no chain: an ISO date, an ISBN or a phone number always trips this. This guard
          # reads the input as it stood before this rule (or `dashes`) made any edit in this
          # pipeline pass -- ranges.md 4's own reasoning for why `ranges` must run before `dashes`.
          return false if DashShared.dash_union?(before)
          return false if DashShared.dash_union?(after)

          # G3 -- not part of a decimal or a path.
          return false if before == DashShared::FULL_STOP || before == DashShared::COMMA || before == SOLIDUS
          return false if after == SOLIDUS

          # G4 -- run lengths: equal, or the directional (1,2) branch with no leading zero on Rrun.
          left_length = left - a + 1
          right_length = b - right + 1
          return true if left_length == 1 && right_length == 2 && cp[right] != DashShared::DIGIT_ZERO
          return false if left_length != right_length

          # G5 -- non-decreasing (sound only because G4 guarantees equal length in this branch).
          non_decreasing?(cp, a, right, left_length)
        end

        def scan(cp, locale_data, _ctx)
          edits = []
          style = locale_data["dash"]["range"]

          DashShared.find_tokens(cp).each do |token|
            # ranges.md 3.2, 3.2a -- a candidate iff both flanks are DIGIT once a matched
            # closed-up symbol has been walked over. Anything else is `dashes`' territory, and
            # `dashes` declines a candidate unconditionally too (operator decision, spec 0.5.0).
            flanks = DashShared.range_flanks(cp, token.left, token.right)
            next if flanks.nil?

            next unless guards_pass?(cp, flanks)

            # "none": the locale has no verified range convention, so nothing is substituted --
            # not a fallback to dash.parenthetical, nothing (ranges.md 2).
            next if style == "none"

            if DashShared.spaced_style?(style)
              # T1: a tight token may not become spaced across a digit run that has a far dash.
              # T1/T2 read the walked flanks: ranges.md 3.2a makes cp[L']/cp[R'] what every
              # shared guard sees once a closed-up symbol has been consumed.
              next if token.lsp.zero? && token.rsp.zero? &&
                      DashShared.spacing_transition_blocked?(cp, flanks.left, flanks.right)

              # T2: the emitted U+0020 must not land where `spaces` (order 10) would delete it.
              next if DashShared.strip_before_or_close_bracket?(cp[flanks.right])
              next if DashShared.open_bracket?(cp[flanks.left])
            end

            # ranges.md 3.3.1: never make an edit whose entire content is invisible. Try the
            # unbound replacement first; only add the joiner pair if the dash itself is genuinely
            # changing.
            unbound = DashShared.build_replacement(style, false)
            only_binding_would_change = !DashShared.spaced_style?(style) &&
                                         DashShared.same_content?(cp, token.span_start, token.span_end, unbound)
            bind = !DashShared.spaced_style?(style) && !only_binding_would_change
            replacement = bind ? DashShared.build_replacement(style, true) : unbound

            next if DashShared.same_content?(cp, token.span_start, token.span_end, replacement)

            edits << Polytypo::Engine::Edit.new(token.span_start, token.span_end, replacement, "ranges")
          end

          edits
        end
      end

      Polytypo::Engine::Registry.register("ranges", ->(cp, locale_data, ctx) { Ranges.scan(cp, locale_data, ctx) })
    end
  end
end

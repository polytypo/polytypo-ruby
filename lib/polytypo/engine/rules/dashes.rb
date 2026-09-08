# frozen_string_literal: true

require_relative "dash_shared"
require_relative "../edits"
require_relative "../registry"
require_relative "../unicode_util"

module Polytypo
  module Engine
    module Rules
      # `dashes` -- spec/rules/dashes.md, order 30. Parenthetical-dash processing only, as of spec
      # 0.5.0: numeric/date-range recognition moved to the `ranges` rule (order 25, off by
      # default), which owns `dash.range` and shares this rule's token-scanning and guard
      # machinery via DashShared. See dashes.md 1 and 7.11, and ranges.md 1, for why the split
      # happened and why range detection is opt-in rather than fixed structurally.
      #
      # A digit-flanked dash token is declined here unconditionally -- never reinterpreted as a
      # parenthetical dash -- regardless of whether `ranges` is enabled (operator decision, spec
      # 0.5.0). That was already true of every prior spec version: the range/parenthetical
      # branches have always been mutually exclusive per token, on the same "both flanks DIGIT"
      # test that now decides which rule a token belongs to rather than which branch of one rule
      # it takes.
      #
      # Explicit index-based scanning only: no regex anywhere, and every index addresses the
      # code-point array, never a native string (ARCHITECTURE.md 4.1, 4.2).
      module Dashes
        ROMAN_I = 0x49
        ROMAN_V = 0x56
        ROMAN_X = 0x58
        ROMAN_L = 0x4c
        ROMAN_C = 0x43
        ROMAN_D = 0x44
        ROMAN_M = 0x4d

        module_function

        # dashes.md 3.1 ROMAN: the seven uppercase Roman-numeral letters only. Lower-case forms
        # are not members -- see dashes.md 3.4 P4.
        def roman?(cp)
          cp == ROMAN_I || cp == ROMAN_V || cp == ROMAN_X || cp == ROMAN_L || cp == ROMAN_C ||
            cp == ROMAN_D || cp == ROMAN_M
        end

        # dashes.md 3.4 P4 -- the Roman-numeral veto. A tight dash between two word-bounded ROMAN
        # runs is a range already in its correct Russian form (`в XV—XVII веках`); `ranges` cannot
        # see it, because ranges.md 3.2 needs a DIGIT on each side, so without this the
        # parenthetical branch would space out input that was already right.
        #
        # A veto only: it never converts. Admitting ROMAN runs as range candidates would also fix
        # `XV-XVII`, but it fires on all-caps words built from the same letters (`MIX`, `CIVIL`),
        # and converting is the direction that damages -- see dashes.md 7.10.
        def roman_flanked?(cp, left, right)
          n = cp.length

          return false unless roman?(cp[left]) && roman?(cp[right])

          a = left
          a -= 1 while a.positive? && roman?(cp[a - 1])
          return false if a.positive? && Polytypo::Engine::UnicodeUtil.letter?(cp[a - 1])

          b = right
          b += 1 while b + 1 < n && roman?(cp[b + 1])
          return false if b + 1 < n && Polytypo::Engine::UnicodeUtil.letter?(cp[b + 1])

          true
        end

        def scan(cp, locale_data, _ctx)
          edits = []
          style = locale_data["dash"]["parenthetical"]

          DashShared.find_tokens(cp).each do |token|
            # A digit-flanked token is `ranges`' territory, never `dashes`' -- declined
            # unconditionally, whether or not `ranges` is enabled (operator decision, spec 0.5.0).
            next if DashShared.digit?(token.left_cp) && DashShared.digit?(token.right_cp)

            # dashes.md 3.4 P5 -- authored en-dash mark-identity veto (spec 0.6.0). A run
            # consisting of exactly one U+2013 is declined unconditionally: every locale, tight or
            # spaced, regardless of dash.parenthetical's target glyph.
            next if token.e - token.s == 1 && cp[token.s] == DashShared::EN_DASH

            # dashes.md 3.4 P1 -- a bare hyphen-shaped stroke must be spaced (the compound-word
            # guard): well-known, e-mail, Jean-Luc, well-being, and their U+2010/U+2212 spellings.
            if token.e - token.s == 1 &&
               [DashShared::HYPHEN_MINUS, DashShared::HYPHEN, DashShared::MINUS_SIGN].include?(cp[token.s]) &&
               token.lsp.zero?
              next
            end

            # dashes.md 3.4 P4 -- Roman-numeral veto.
            next if token.lsp.zero? && token.rsp.zero? && roman_flanked?(cp, token.left, token.right)

            # "none": the locale has no verified convention, so nothing is substituted.
            next if style == "none"

            if DashShared.spaced_style?(style)
              # T1: a tight token may not become spaced across a digit run that has a far dash.
              next if token.lsp.zero? && token.rsp.zero? &&
                      DashShared.spacing_transition_blocked?(cp, token.left, token.right)

              # T2: the emitted U+0020 must not land where `spaces` (order 10) would delete it.
              next if DashShared.strip_before_or_close_bracket?(token.right_cp)
              next if DashShared.open_bracket?(token.left_cp)
            end

            # `dashes` never binds: an interrupting dash is exactly where a line may break
            # (dashes.md 3.3.1's binding is `ranges`-only). Every token this rule accepts has
            # crossed_joiner=false (find_tokens never returns a crossed-joiner, non-digit-flanked
            # token), so the plain s-lsp/e+rsp span is always exactly the token's own span here.
            replacement = DashShared.build_replacement(style, false)
            span_start = token.s - token.lsp
            span_end = token.e + token.rsp
            next if DashShared.same_content?(cp, span_start, span_end, replacement)

            edits << Polytypo::Engine::Edit.new(span_start, span_end, replacement, "dashes")
          end

          edits
        end
      end

      Polytypo::Engine::Registry.register("dashes", ->(cp, locale_data, ctx) { Dashes.scan(cp, locale_data, ctx) })
    end
  end
end

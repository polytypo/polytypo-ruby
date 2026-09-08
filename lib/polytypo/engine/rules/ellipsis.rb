# frozen_string_literal: true

require_relative "../edits"
require_relative "../sentinels"
require_relative "../registry"

module Polytypo
  module Engine
    module Rules
      # spec/rules/ellipsis.md. No regex anywhere (ARCHITECTURE.md section 4.1): a single
      # left-to-right scan over the code-point array, deciding each maximal DOTLIKE run as a
      # pure function of the run itself and the one code point to its left.
      module Ellipsis
        DOT = 0x2E
        ELL = 0x2026
        EXCLAMATION = 0x21
        QUESTION = 0x3F

        # cp[i], or NONE if i is out of bounds -- the spec's own boundary value.
        def self.at(cp, i)
          return NONE if i.negative? || i >= cp.length

          cp[i]
        end

        def self.dotlike?(value)
          value == DOT || value == ELL
        end

        def self.terminal?(value)
          value == EXCLAMATION || value == QUESTION
        end

        # Whether cp[s...e] is already exactly target, so a would-be no-op edit is never
        # emitted.
        def self.same_run?(cp, s, e, target)
          return false if e - s != target.length

          target.each_with_index do |want, j|
            return false if at(cp, s + j) != want
          end
          true
        end

        # ellipsis.md 3.3 steps 4-6. nil means "emit nothing"; otherwise the final form of the
        # whole run.
        def self.run_target(k, q, left, abbreviated)
          if k == 2 && q.zero?
            # The two-dot run is unconditionally inert where "?.." is the correct output form;
            # that is what stops "?.." <-> "?…" from oscillating (ellipsis.md 5).
            return nil if abbreviated
            return [ELL] if terminal?(left)

            return nil
          end
          return nil if k == 1 && q.zero?

          # k = 1 with an existing U+2026, or any run of 2+ containing one: normalise, then
          # decide the abbreviated form on the same span (ellipsis.md 3.3 step 6).
          return [DOT, DOT] if abbreviated && terminal?(left)

          [ELL]
        end

        def self.scan(cp, locale_data, _ctx)
          n = cp.length
          abbreviated = locale_data["ellipsis"]["abbreviatedAfterTerminal"]
          edits = []
          i = 0

          while i < n
            unless dotlike?(at(cp, i))
              i += 1
              next
            end

            s = i
            e = s
            q = 0
            while e < n && dotlike?(at(cp, e))
              q += 1 if at(cp, e) == ELL
              e += 1
            end
            k = e - s
            left = at(cp, s - 1)

            # One decision per run, one edit per run (ellipsis.md 3.3 step 6).
            target = run_target(k, q, left, abbreviated)
            edits << Edit.new(s, e, target, "ellipsis") if !target.nil? && !same_run?(cp, s, e, target)
            i = e
          end

          edits
        end
      end
    end

    Registry.register("ellipsis", ->(cp, locale_data, ctx) { Rules::Ellipsis.scan(cp, locale_data, ctx) })
  end
end

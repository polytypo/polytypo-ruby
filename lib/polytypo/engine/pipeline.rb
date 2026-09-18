# frozen_string_literal: true

require_relative "edits"
require_relative "locale"
require_relative "origin"
require_relative "registry"
require_relative "../errors"

module Polytypo
  module Engine
    # Per-call context every rule reads, alongside the code-point array and the locale data.
    RuleContext = Struct.new(:mode, :dialect, :locale, keyword_init: true)

    # Resolves the locale, builds the rule plan, and runs each enabled rule in
    # spec/rules/order.json order over a code-point array, applying its edits before the next
    # rule sees it. No module-level mutable state beyond the immutable, load-once-on-first-use
    # spec data in Registry/Locale (ARCHITECTURE.md section 7).
    module Pipeline
      # Defaults + opt-out overrides. rules_option is opt-out only (ARCHITECTURE.md section 7):
      # it may only disable a default-on rule or enable the one default-off rule ("ranges"). An
      # unknown key raises POLYTYPO_UNKNOWN_RULE.
      def self.resolve_rule_plan(rules_option)
        defaults = Registry.rule_defaults
        enabled = defaults.dup
        (rules_option || {}).each do |rule_id, flag|
          unless defaults.key?(rule_id)
            raise Polytypo::Error.new(Polytypo::CODE_UNKNOWN_RULE, "unknown rule id: #{rule_id.inspect}")
          end

          enabled[rule_id] = flag ? true : false
        end
        Registry.rule_order.select { |id| enabled[id] }
      end

      # Builds the rule plan, then resolves the locale and loads its data -- the setup step
      # shared by the text pipeline and the span-runner (html/markdown modes). Order matters and
      # is public, tested behaviour: an unknown-rule error must win over an unknown-locale error
      # when both are present (mirrors every other port exactly).
      def self.prepare(locale, rules_option)
        plan = resolve_rule_plan(rules_option)
        resolved_locale = Locale.resolve(locale)
        locale_data = Locale.locale_data_raw(resolved_locale)
        [resolved_locale, locale_data, plan]
      end

      # Runs each enabled rule in order.json order over cp, applying its edits before the next
      # rule sees the array. Shared by text mode and the span-runner (modes.md 3.5), which
      # interposes the two boundary filters of modes.md 3.4 between rule and apply.
      def self.run_rules(cp, plan, locale_data, ctx)
        current = cp
        plan.each do |rule_id|
          fn = Registry.rule(rule_id)
          edits = fn.call(current, locale_data, ctx)
          next if edits.empty?

          current = Edits.apply_edits(current, edits, rule_id)
        end
        current
      end

      # run_rules, keeping the edits instead of discarding them (analyze.md section 1: same
      # pipeline, same order, reporting rather than applying). The origin map travels alongside
      # the array so every change comes back in input coordinates, and +filter_edits+ is the hook
      # the span-runner needs for modes.md 3.4's boundary filters, passed as a block -- text mode
      # passes none and gets the identity.
      def self.run_rules_recording(cp, plan, locale_data, ctx, origin, input_length)
        current = cp
        current_origin = origin
        changes = []
        plan.each do |rule_id|
          fn = Registry.rule(rule_id)
          produced = fn.call(current, locale_data, ctx)
          edits = block_given? ? yield(current, produced) : produced
          next if edits.empty?

          changes.concat(Origin.record_changes(current, edits, current_origin, input_length, rule_id))
          current_origin = Origin.apply_edits_to_origin(current_origin, edits)
          current = Edits.apply_edits(current, edits, rule_id)
        end
        changes
      end
    end
  end
end

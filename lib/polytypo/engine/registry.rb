# frozen_string_literal: true

require "json"

module Polytypo
  module Engine
    # Rule order and defaults, derived from lib/polytypo/data/rules/order.json at load time --
    # never hand-duplicated (ARCHITECTURE.md section 4.5: order.json is the single source of
    # truth, never registration order, never Hash-iteration order).
    module Registry
      DATA_DIR = File.join(__dir__, "..", "data")

      def self.order_data
        @order_data ||= JSON.parse(File.read(File.join(DATA_DIR, "rules", "order.json")))
      end
      private_class_method :order_data

      # Rule ids in ascending pipeline order.
      def self.rule_order
        @rule_order ||= order_data["rules"].sort_by { |r| r["order"] }.map { |r| r["id"] }
      end

      # Rule id -> default enabled/disabled (only "ranges" defaults to false). order.json's
      # "default" field is the string "on"/"off", not a JSON boolean.
      def self.rule_defaults
        @rule_defaults ||= order_data["rules"].to_h { |r| [r["id"], r["default"] == "on"] }
      end

      @rules = {}

      # Adds a rule implementation to the registry. Called from each rule file's own load,
      # mirroring the other ports' static-registration pattern -- requiring the rules directory
      # is enough, with no separate caller-side step.
      def self.register(rule_id, callable)
        @rules[rule_id] = callable
      end

      def self.rule(rule_id)
        @rules.fetch(rule_id)
      end

      def self.known_rule_ids
        rule_defaults.keys
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "codepoints"
require_relative "../errors"

module Polytypo
  module Engine
    # Locale resolution (spec/rules/locale-resolution.md) and locale data loading. Resolution is
    # specified centrally and index-based -- no regex, no host locale, no platform
    # locale-negotiation library (ARCHITECTURE.md sections 4.1, 4.4, 4.7). Data is embedded in the
    # installed gem (lib/polytypo/data/), read once and memoized -- resolution itself stays a pure
    # function of (locale, registry), never mutated after first load.
    module Locale
      DATA_DIR = File.join(__dir__, "..", "data")

      HYPHEN = 0x2d
      UNDERSCORE = 0x5f
      UPPER_A = 0x41
      UPPER_Z = 0x5a
      LOWER_A = 0x61
      LOWER_Z = 0x7a
      CASE_GAP = 0x20

      def self.registry
        @registry ||= JSON.parse(File.read(File.join(DATA_DIR, "locales", "registry.json")))
      end

      def self.locale_data_raw(locale_id)
        @locale_data_raw ||= {}
        @locale_data_raw[locale_id] ||=
          JSON.parse(File.read(File.join(DATA_DIR, "locales", "#{locale_id}.json")))
      end

      def self.lower_ascii?(cp)
        cp >= LOWER_A && cp <= LOWER_Z
      end
      private_class_method :lower_ascii?

      def self.upper_ascii?(cp)
        cp >= UPPER_A && cp <= UPPER_Z
      end
      private_class_method :upper_ascii?

      # spec/rules/locale-resolution.md 3.2. ASCII arithmetic only: no downcase/upcase, no ICU,
      # no host locale, so a Turkish process resolves "EN-us" exactly as a Finnish one does
      # (ARCHITECTURE.md 4.4).
      def self.canonicalize(tag)
        c = Codepoints.to_codepoints(tag).map { |cp| cp == UNDERSCORE ? HYPHEN : cp }
        m = c.length
        if m >= 2
          [0, 1].each { |j| c[j] += CASE_GAP if upper_ascii?(c[j]) }
        end
        if m == 5 && c[2] == HYPHEN
          [3, 4].each { |j| c[j] -= CASE_GAP if lower_ascii?(c[j]) }
        end
        c
      end
      private_class_method :canonicalize

      # spec/rules/locale-resolution.md 3.3. Exactly two accepted shapes, tested by index rather
      # than by pattern (ARCHITECTURE.md 4.1).
      def self.accepted_shape?(c)
        case c.length
        when 2
          lower_ascii?(c[0]) && lower_ascii?(c[1])
        when 5
          lower_ascii?(c[0]) && lower_ascii?(c[1]) && c[2] == HYPHEN &&
            upper_ascii?(c[3]) && upper_ascii?(c[4])
        else
          false
        end
      end
      private_class_method :accepted_shape?

      # Alias values are concrete locales by registry invariant (locale-resolution.md 2). A
      # violation is a spec-data bug, reported rather than trusted.
      def self.alias_target(tag)
        reg = registry
        return nil unless reg["aliases"].key?(tag)

        target = reg["aliases"][tag]
        unless reg["locales"].include?(target)
          raise Polytypo::Error.new(
            Polytypo::CODE_MALFORMED_LOCALE_DATA,
            "registry alias #{tag.inspect} points at #{target.inspect}, which is not a declared locale"
          )
        end
        target
      end
      private_class_method :alias_target

      # Exact match before alias, so a registry that wrongly lists a tag in both cannot make
      # lookup order observable (locale-resolution.md 3.4).
      def self.lookup(tag)
        return tag if registry["locales"].include?(tag)

        alias_target(tag)
      end
      private_class_method :lookup

      # Exact match, then the registry alias table, then the language subtag alone once with no
      # chain. Never a platform locale negotiator (ARCHITECTURE.md 4.7). An empty or malformed tag
      # has no accepted shape and falls through to the same unknown-locale error as any other
      # unresolvable tag.
      def self.resolve(tag)
        unless tag.is_a?(String) && !tag.empty?
          raise Polytypo::Error.new(
            Polytypo::CODE_UNKNOWN_LOCALE,
            "the locale option is required and must be a non-empty string; received #{tag.inspect}"
          )
        end

        c = canonicalize(tag)
        if accepted_shape?(c)
          canonical = Codepoints.from_codepoints(c)
          direct = lookup(canonical)
          return direct unless direct.nil?

          if c.length == 5
            base = Codepoints.from_codepoints(c[0, 2])
            resolved = lookup(base)
            return resolved unless resolved.nil?
          end
        end

        raise Polytypo::Error.new(
          Polytypo::CODE_UNKNOWN_LOCALE,
          "unknown locale #{tag.inspect}. Known locales: #{registry['locales'].join(', ')}."
        )
      end

      def self.locale_data(tag)
        locale_data_raw(resolve(tag))
      end
    end
  end
end

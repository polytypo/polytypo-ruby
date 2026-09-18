# frozen_string_literal: true

require_relative "spans"
require_relative "../engine/edits"
require_relative "../engine/pipeline"
require_relative "../engine/registry"

module Polytypo
  module Modes
    # modes.md 3.5. The pipeline runs once, over the marker-separated concatenation of every
    # processable span -- not per span (would pair quotation marks in isolation), and not over a
    # naive concatenation (would manufacture adjacencies the document does not have).
    module Runner
      # The same sequence as Engine::Pipeline.run_rules, with the two boundary filters of
      # modes.md 3.4 interposed.
      def self.run_rules_over_spans(cp, plan, locale_data, ctx)
        current = cp
        plan.each do |rule_id|
          fn = Engine::Registry.rule(rule_id)
          edits = fn.call(current, locale_data, ctx)
          filtered = Spans.filter_boundary_edits(current, edits, Spans.span_ranges_of(current))
          next if filtered.empty?

          current = Engine::Edits.apply_edits(current, filtered, rule_id)
        end
        current
      end
      private_class_method :run_rules_over_spans

      # The output is the input with a set of disjoint substring replacements applied and nothing
      # else (modes.md 4). A span whose content the rules did not change contributes no
      # replacement, so a document needing no changes comes back byte-identical.
      #
      # source_cp is the whole input already converted to code points; spans address it by
      # code-point index.
      def self.run_over_spans(source_cp, spans, plan, locale_data, ctx)
        normalized = Spans.normalize_spans(spans)
        return source_cp.pack("U*") if normalized.empty?

        concatenated = Spans.concatenate_spans(source_cp, normalized)
        transformed = run_rules_over_spans(concatenated, plan, locale_data, ctx)
        pieces = Spans.split_on_marker(transformed, normalized.length)

        out = []
        cursor = 0
        normalized.each_with_index do |span, i|
          piece = pieces[i]
          original = source_cp[span.start...span.end]
          out.concat(source_cp[cursor...span.start])
          out.concat(piece == original ? original : piece)
          cursor = span.end
        end
        out.concat(source_cp[cursor..])
        out.pack("U*")
      end

      # run_over_spans, reporting instead of applying (analyze.md section 1). The span table
      # supplies the origin map, so every change comes back in DOCUMENT coordinates -- analyze.md
      # section 6 names a runtime that reports span-local offsets here as the mistake that passes
      # every text-mode test.
      def self.analyze_over_spans(source_cp, spans, plan, locale_data, ctx)
        normalized = Spans.normalize_spans(spans)
        return [] if normalized.empty?

        Engine::Pipeline.run_rules_recording(
          Spans.concatenate_spans(source_cp, normalized),
          plan, locale_data, ctx,
          Spans.origin_of_spans(normalized),
          source_cp.length
        ) { |current, edits| Spans.filter_boundary_edits(current, edits, Spans.span_ranges_of(current)) }
      end
    end
  end
end

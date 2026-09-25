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
        emit(source_cp, replacements_of_unit(source_cp, spans, plan, locale_data, ctx))
      end

      # modes.md 3.1 and 3.5 step 3 (spec 1.7.0). A document has one text unit, except in
      # "markdown" with frontmatter_keys, where the frontmatter block's spans form a unit of their
      # own. The pipeline runs once per unit and the two edit sets are disjoint, because no span of
      # one unit lies inside the other -- which is what the body's walk skipping the block
      # guarantees. Only step 5 is shared: the source is emitted once, in document order.
      def self.run_over_units(source_cp, units, plan, locale_data, ctx)
        replacements = units.flat_map do |spans|
          replacements_of_unit(source_cp, spans, plan, locale_data, ctx)
        end
        emit(source_cp, replacements.sort_by { |span, _piece| span.start })
      end

      # analyze_over_spans per text unit (modes.md 3.1), reported in document order.
      def self.analyze_over_units(source_cp, units, plan, locale_data, ctx)
        units.flat_map { |spans| analyze_over_spans(source_cp, spans, plan, locale_data, ctx) }
             .sort_by(&:start)
      end

      # One text unit: the marker-separated concatenation, the pipeline, and the pieces it
      # produced, paired with the spans they replace.
      def self.replacements_of_unit(source_cp, spans, plan, locale_data, ctx)
        normalized = Spans.normalize_spans(spans)
        return [] if normalized.empty?

        concatenated = Spans.concatenate_spans(source_cp, normalized)
        transformed = run_rules_over_spans(concatenated, plan, locale_data, ctx)
        pieces = Spans.split_on_marker(transformed, normalized.length)
        normalized.each_with_index.map { |span, i| [span, pieces[i]] }
      end
      private_class_method :replacements_of_unit

      # modes.md 4: the source with disjoint replacements applied at recorded offsets, and nothing
      # else changed.
      def self.emit(source_cp, replacements)
        out = []
        cursor = 0
        replacements.each do |span, piece|
          original = source_cp[span.start...span.end]
          out.concat(source_cp[cursor...span.start])
          out.concat(piece == original ? original : piece)
          cursor = span.end
        end
        out.concat(source_cp[cursor..])
        out.pack("U*")
      end
      private_class_method :emit

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

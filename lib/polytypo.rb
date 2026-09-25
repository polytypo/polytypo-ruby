# frozen_string_literal: true

require_relative "polytypo/version"
require_relative "polytypo/errors"
require_relative "polytypo/engine/codepoints"
require_relative "polytypo/engine/origin"
require_relative "polytypo/engine/pipeline"
require_relative "polytypo/engine/rules" # side effect: registers all 9 rules
require_relative "polytypo/modes/spans"
require_relative "polytypo/modes/runner"
require_relative "polytypo/modes/html"
require_relative "polytypo/modes/yaml"

# polytypo normalizes typography across languages: locale-correct quotes, dashes, ellipses,
# apostrophes, symbols and no-break spaces, from a spec shared across every polytypo runtime
# (github.com/polytypo/polytypo). See spec/CONFORMANCE.md there for exactly what this runtime
# implements.
module Polytypo
  # Applies polytypo's rule pipeline to +input+ and returns the result.
  #
  # +locale+ is required, with no default -- an unknown locale raises Polytypo::Error with
  # CODE_UNKNOWN_LOCALE; there is never a fallback to English. +mode+ is "text" (default),
  # "html", "markdown" or "yaml". +dialect+ is required iff mode is "markdown" ("commonmark";
  # "mdx" is not implemented by this runtime). +keys+ is required iff mode is "yaml" and names
  # the mapping keys whose scalar values are prose (modes.md 3.8.2) -- it has no default, because
  # nothing in YAML's syntax separates "description:" from "run:". +rules+ is an opt-out Hash
  # keyed by rule id.
  #
  # Pure: no I/O, no environment, no clock, no globals, no class-level mutable state --
  # thread-safe and reentrant, callable concurrently from any number of Threads with no external
  # synchronization (ARCHITECTURE.md section 7).
  #
  # Only `mode: "text"`/`"html"` ever touch this file's own requires; `mode: "markdown"` lazily
  # requires "commonmarker" from within Modes::Markdown, never at load time of this file.
  def self.transform(input, locale:, mode: "text", dialect: nil, keys: nil, rules: nil, narrow_nbsp: nil,
                     frontmatter_keys: nil)
    resolved_mode = resolve_mode(mode)
    narrow_target = Engine.resolve_narrow_target(narrow_nbsp)

    case resolved_mode
    when "text"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      transform_text(input, locale, rules, narrow_target)
    when "html"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      transform_html(input, locale, rules, narrow_target)
    when "yaml"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      transform_yaml(input, locale, keys, rules, narrow_target)
    else # "markdown"
      transform_markdown(input, locale, dialect, rules, narrow_target, frontmatter_keys)
    end
  end

  # Runs the same pipeline as .transform and reports what it would do instead of doing it
  # (spec/rules/analyze.md), returning an Array of Polytypo::Engine::Change. Offsets are
  # code-point offsets into +input+ in every mode -- into the document, in "html" and "markdown"
  # mode, not into a span.
  #
  # What it guarantees: the list is empty exactly when .transform would return the input
  # unchanged, every +rule_id+ was enabled for the call, and every offset is inside the input.
  # What it does not: the list is a report, not a patch -- two rules may touch the same original
  # range, so replaying it is not guaranteed to reproduce .transform's output. Call .transform
  # for the text (analyze.md sections 4 and 5).
  #
  # Pure and thread-safe on the same terms as .transform.
  def self.analyze(input, locale:, mode: "text", dialect: nil, keys: nil, rules: nil, narrow_nbsp: nil,
                   frontmatter_keys: nil)
    resolved_mode = resolve_mode(mode)
    narrow_target = Engine.resolve_narrow_target(narrow_nbsp)

    case resolved_mode
    when "text"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      analyze_text(input, locale, rules, narrow_target)
    when "html"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      analyze_html(input, locale, rules, narrow_target)
    when "yaml"
      if dialect
        raise Error.new(CODE_INVALID_DIALECT, '"dialect" is only valid when mode is "markdown"')
      end
      analyze_yaml(input, locale, keys, rules, narrow_target)
    else # "markdown"
      analyze_markdown(input, locale, dialect, rules, narrow_target, frontmatter_keys)
    end
  end

  def self.resolve_mode(mode)
    case mode
    when nil, "text"
      "text"
    when "html", "markdown", "yaml"
      mode
    else
      raise Error.new(CODE_INVALID_MODE,
                      "unknown mode #{mode.inspect}. Expected \"text\", \"html\", \"markdown\" or \"yaml\"")
    end
  end
  private_class_method :resolve_mode

  def self.transform_text(input, locale, rules, narrow_target)
    _resolved, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    cp = Engine::Codepoints.to_codepoints(input)
    ctx = Engine::RuleContext.new(mode: "text", dialect: nil, locale: locale,
                                  narrow_target: narrow_target)
    result = Engine::Pipeline.run_rules(cp, plan, locale_data, ctx)
    Engine::Codepoints.from_codepoints(result)
  end
  private_class_method :transform_text

  def self.transform_html(input, locale, rules, narrow_target)
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    spans = Modes::Html.html_spans(input)
    ctx = Engine::RuleContext.new(mode: "html", dialect: nil, locale: resolved_locale,
                                  narrow_target: narrow_target)
    cp = Engine::Codepoints.to_codepoints(input)
    Modes::Runner.run_over_spans(cp, spans, plan, locale_data, ctx)
  end
  private_class_method :transform_html

  # "yaml" mode: the only pipeline here with no parser dependency at all -- span selection is the
  # specified scan of modes.md 3.8, not a library. There is likewise no CODE_MALFORMED_INPUT
  # counterpart: with no declared grammar to violate, a file that is not YAML yields few spans or
  # none and comes back byte for byte (modes.md 3.8.3). The only raise this mode adds is +keys+,
  # which is about the call and not the input.
  def self.transform_yaml(input, locale, keys, rules, narrow_target)
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    resolved_keys = Engine.resolve_yaml_keys(keys)
    spans = Modes::Yaml.yaml_spans(input, resolved_keys)
    ctx = Engine::RuleContext.new(mode: "yaml", dialect: nil, locale: resolved_locale,
                                  narrow_target: narrow_target)
    cp = Engine::Codepoints.to_codepoints(input)
    Modes::Runner.run_over_spans(cp, spans, plan, locale_data, ctx)
  end
  private_class_method :transform_yaml

  def self.transform_markdown(input, locale, dialect, rules, narrow_target, frontmatter_keys = nil)
    # Validation order is public, tested behaviour, identical across every runtime: rules (an
    # unknown rule id), then locale (an unknown locale), then dialect, then frontmatter_keys, then
    # parsing (modes.md 3.7.4).
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    require_relative "polytypo/modes/markdown"
    Modes::Markdown.resolve_dialect(dialect)
    resolved_keys = Engine.resolve_frontmatter_keys(frontmatter_keys)
    ctx = Engine::RuleContext.new(mode: "markdown", dialect: dialect, locale: resolved_locale,
                                  narrow_target: narrow_target)
    cp = Engine::Codepoints.to_codepoints(input)
    Modes::Runner.run_over_units(cp, markdown_units(input, resolved_keys), plan, locale_data, ctx)
  end

  # modes.md 3.7.4: the body, and -- only when the caller named frontmatter keys -- the
  # frontmatter block as a second text unit. With frontmatter_keys nil this is exactly the single
  # unit every document had before spec 1.7.0, which is why no released output can move.
  def self.markdown_units(input, resolved_keys)
    body = Modes::Markdown.markdown_spans(input)
    return [body] if resolved_keys.nil?

    [Modes::Markdown.frontmatter_spans(input, resolved_keys), body]
  end
  private_class_method :markdown_units
  private_class_method :transform_markdown

  def self.analyze_text(input, locale, rules, narrow_target)
    _resolved, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    cp = Engine::Codepoints.to_codepoints(input)
    ctx = Engine::RuleContext.new(mode: "text", dialect: nil, locale: locale,
                                  narrow_target: narrow_target)
    Engine::Pipeline.run_rules_recording(cp, plan, locale_data, ctx, (0...cp.length).to_a, cp.length)
  end
  private_class_method :analyze_text

  def self.analyze_html(input, locale, rules, narrow_target)
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    spans = Modes::Html.html_spans(input)
    ctx = Engine::RuleContext.new(mode: "html", dialect: nil, locale: resolved_locale,
                                  narrow_target: narrow_target)
    Modes::Runner.analyze_over_spans(Engine::Codepoints.to_codepoints(input), spans, plan, locale_data, ctx)
  end
  private_class_method :analyze_html

  # analyze.md section 1, "yaml" mode: offsets are into the document, not into a span
  # (analyze.md section 6).
  def self.analyze_yaml(input, locale, keys, rules, narrow_target)
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    resolved_keys = Engine.resolve_yaml_keys(keys)
    spans = Modes::Yaml.yaml_spans(input, resolved_keys)
    ctx = Engine::RuleContext.new(mode: "yaml", dialect: nil, locale: resolved_locale,
                                  narrow_target: narrow_target)
    Modes::Runner.analyze_over_spans(Engine::Codepoints.to_codepoints(input), spans, plan, locale_data, ctx)
  end
  private_class_method :analyze_yaml

  def self.analyze_markdown(input, locale, dialect, rules, narrow_target, frontmatter_keys = nil)
    # Validation order is public, tested behaviour and is shared with .transform: rules, then
    # locale, then dialect, then frontmatter_keys, then parsing (analyze.md section 4, A1).
    resolved_locale, locale_data, plan = Engine::Pipeline.prepare(locale, rules)
    require_relative "polytypo/modes/markdown"
    Modes::Markdown.resolve_dialect(dialect)
    resolved_keys = Engine.resolve_frontmatter_keys(frontmatter_keys)
    ctx = Engine::RuleContext.new(mode: "markdown", dialect: dialect, locale: resolved_locale,
                                  narrow_target: narrow_target)
    Modes::Runner.analyze_over_units(Engine::Codepoints.to_codepoints(input),
                                     markdown_units(input, resolved_keys), plan, locale_data, ctx)
  end
  private_class_method :analyze_markdown
end

# frozen_string_literal: true

require "polytypo"

# spec/rules/modes.md 3.8 -- the "yaml" mode's span selection, its required keys option, and the
# accepted misses of section 7.11. The scan is specified rather than delegated (3.8.1), so a spec
# here is one of the few things standing between five hand-written scanners and five different
# answers.
# Lint/ConstantDefinitionInBlock: a constant inside an RSpec block leaks into Object, so the
# default key list is a method, not a constant.
def prose_keys
  %w[description summary title a b c k n inner use]
end

RSpec.describe "yaml mode (spec/rules/modes.md 3.8)" do
  def yaml(source, locale = "en-US", keys = prose_keys)
    Polytypo.transform(source, locale: locale, mode: "yaml", keys: keys)
  end

  def span_text(source, keys = prose_keys)
    Polytypo::Modes::Yaml.yaml_spans(source, keys.to_set).map { |s| source[s.start...s.end] }
  end

  def code_of(**opts)
    Polytypo.transform("a: one two\n", **opts)
    "NO RAISE"
  rescue Polytypo::Error => e
    e.code
  end

  describe "the keys option (3.8.2)" do
    it "is required, with no default" do
      expect(code_of(locale: "en-US", mode: "yaml")).to eq(Polytypo::CODE_INVALID_OPTION)
      expect(code_of(locale: "en-US", mode: "yaml", keys: "description")).to eq(Polytypo::CODE_INVALID_OPTION)
      expect(code_of(locale: "en-US", mode: "yaml", keys: ["ok", 7])).to eq(Polytypo::CODE_INVALID_OPTION)
    end

    it "accepts an empty list and then processes nothing" do
      expect(yaml("description: one...two\n", "en-US", [])).to eq("description: one...two\n")
    end

    it "processes a listed key and leaves an unlisted one byte for byte" do
      source = "description: one...two\nrun: three...four\n"
      expect(yaml(source, "en-US", ["description"])).to eq("description: one…two\nrun: three...four\n")
    end

    it "matches the same key name at any depth" do
      source = "description: one...\nnested:\n  description: two...\n"
      expect(yaml(source, "en-US", ["description"]))
        .to eq("description: one…\nnested:\n  description: two…\n")
    end

    it "matches code point for code point, with no case folding" do
      expect(span_text("Description: one two\n", ["description"])).to eq([])
      expect(span_text("Description: one two\n", ["Description"])).to eq(["one two"])
    end

    it "ignores trailing spaces between the key and its colon" do
      expect(span_text("description  : one two\n", ["description"])).to eq(["one two"])
    end

    it "never matches a key carrying a declining character, at any position" do
      expect(span_text(%("description": one two\n), ["description"])).to eq([])
      expect(span_text("a!b: one two\n", ["a!b"])).to eq([])
    end

    it "reads a colon not followed by a space as an ordinary key character" do
      expect(span_text("a:b: one two\n", ["a:b"])).to eq(["one two"])
      expect(span_text("a:b: one two\n", ["a"])).to eq([])
    end

    it "is ignored in the other three modes" do
      expect(Polytypo.transform("a...b", locale: "en-US", keys: ["a"])).to eq("a…b")
    end
  end

  describe "what is processable (3.8.4)" do
    it "processes a plain, a quoted and a block scalar value" do
      source = %(a: one two\nb: "three four"\nc: |\n  five six\n)
      expect(span_text(source)).to eq(["one two", "three four", "five six"])
    end

    it "never processes a key" do
      expect(yaml("a...b: one...two\n", "en-US", ["a...b"])).to eq("a...b: one…two\n")
    end

    it "consumes block sequence entries rather than skipping them, and they nest" do
      expect(span_text("- a: one two\n- - b: three four\n")).to eq(["one two", "three four"])
    end

    it "leaves comments, directives and both document-marker forms alone" do
      expect(span_text("%YAML 1.2\n---\n# a comment\na: one two\n...\n")).to eq(["one two"])
      expect(span_text("--- a: one two\n")).to eq([])
    end

    it "scans a nested node under an empty value, but not an inline value's continuation" do
      expect(span_text("a:\n  b: one two\n")).to eq(["one two"])
      expect(span_text("a: inline value\n  b: one two\n")).to eq([])
    end
  end

  describe "continuation lines are consumed, never rescanned (3.8.4 step 7)" do
    {
      "a multi-line quoted scalar" => %(a: "hello\n  b: some prose "word" here"\n),
      "a multi-line flow mapping" => "a: {\n  b: hello world,\n  c: x\n}\n",
      "a multi-line flow sequence" => "a: [\n  one two...,\n  three\n]\n",
      "a multi-line plain scalar" => "a: one two...\n  b: three four...\n"
    }.each do |name, source|
      it "yields no spans anywhere inside #{name}" do
        expect(span_text(source)).to eq([])
        expect(yaml(source)).to eq(source)
      end
    end
  end

  describe "skip by default (3.8.3)" do
    {
      "a bare sequence item" => "- Some prose here...\n",
      "a flow sequence" => "a: [one two..., three]\n",
      "a flow mapping" => "a: {b: one two...}\n",
      "an anchor" => "a: &anchor one two...\n",
      "an alias" => "a: *anchor\n",
      "a tag" => "a: !!str one two...\n",
      "a double-quoted scalar with an escape" => %(a: "one \\"two\\"... three"\n),
      "a single-quoted scalar with an escaped quote" => "a: 'it''s one two...'\n",
      "a tab anywhere on the line" => "a:\tone two...\n",
      "a compact nested sequence" => "a: - one two...\n",
      "a compact nested mapping" => "a: one two .:\n",
      "an unterminated quoted scalar" => %(a: "one two...\n),
      "a value that is only a comment" => "a: # one two...\n"
    }.each do |name, source|
      it "yields no spans for #{name}, and returns it byte for byte" do
        expect(span_text(source)).to eq([])
        expect(yaml(source)).to eq(source)
      end
    end

    it "returns a file that is not YAML at all unchanged, and never raises on input" do
      source = "{{ not yaml at all ... }}\n\t\tmixed\tindentation\n"
      expect(yaml(source)).to eq(source)
    end
  end

  describe "block scalars (3.8.5)" do
    %w[| |- |+ > >- >+].each do |header|
      it "gives #{header} identical spans and identical trailing bytes" do
        source = "a: #{header}\n  one two...\n\n\nz: 1\n"
        expect(span_text(source)).to eq(["one two..."])
        expect(yaml(source)).to eq("a: #{header}\n  one two…\n\n\nz: 1\n")
      end
    end

    it "accepts a trailing comment on the header" do
      expect(span_text("a: | # note\n  one two\n")).to eq(["one two"])
    end

    it "keeps the indentation outside the span and extra indentation inside it" do
      expect(span_text("a: |\n  one two\n    three four\n")).to eq(["one two", "  three four"])
    end

    it "never collapses a content line's leading spaces" do
      expect(yaml("a: |\n  one two\n    three  four\n")).to eq("a: |\n  one two\n    three four\n")
    end

    it "honours an explicit indentation indicator" do
      expect(span_text("a: |2\n   one two\n")).to eq([" one two"])
    end

    {
      "an explicit indicator disagreeing with the block" => "a: |4\n  one two\n",
      "a tab on a content line" => "a: |\n  one two\n  three\tfour\n",
      "a later content line dedented inside the block" => "a: |\n    deep one two\n  shallow three\n",
      "an unrecognised header" => "a: |x\n  one two\n"
    }.each do |name, source|
      it "yields no spans for the whole block when there is #{name}" do
        expect(span_text(source)).to eq([])
        expect(yaml(source)).to eq(source)
      end
    end

    it "ends the block at the first line indented no more than the key" do
      expect(span_text("a: |\n  one two\nb: three four\n")).to eq(["one two", "three four"])
    end

    it "pairs quotation marks across a block scalar's lines" do
      expect(yaml(%(a: |\n  He said "hi"\n  and left\n))).to eq("a: |\n  He said “hi”\n  and left\n")
    end

    it "gives CRLF the same spans as LF and keeps its carriage returns" do
      expect(span_text("a: |\r\n  one two...\r\n")).to eq(["one two..."])
      expect(yaml("a: |\r\n  one two...\r\n")).to eq("a: |\r\n  one two…\r\n")
    end
  end

  describe "quoted and plain scalars (3.8.6)" do
    it "does not apply the plain-scalar colon test to a quoted scalar" do
      expect(span_text(%(a: "Chapter 1: the beginning"\n))).to eq(["Chapter 1: the beginning"])
    end

    it "strips a trailing comment before testing the scalar for a colon" do
      expect(span_text("a: some prose # note: here\n")).to eq(["some prose"])
    end

    it "splits a plain scalar at a colon and at a hash" do
      expect(span_text("a: one:two three\n")).to eq(%w[one] + ["two three"])
      expect(span_text("a: one#two three\n")).to eq(%w[one] + ["two three"])
    end

    it "declines a growing replacement against a colon or a hash" do
      expect(yaml("k: a:--b\n", "de-DE")).to eq("k: a:--b\n")
      expect(yaml("k: a--#b\n", "de-DE")).to eq("k: a--#b\n")
    end

    it "still applies a contraction at the same position" do
      expect(yaml("k: a--#b\n", "en-US")).to eq("k: a—#b\n")
      expect(yaml("k: a:--b\n", "en-US")).to eq("k: a:—b\n")
    end

    it "declines three dashes by the character clause of 3.4" do
      expect(yaml("k: a:---b\n", "de-DE")).to eq("k: a:---b\n")
      expect(yaml("k: a---#b\n", "de-DE")).to eq("k: a---#b\n")
    end
  end

  describe "span partition stability (modes.md 5 item 2)" do
    it "does not lose a span because a rule changed what is inside it" do
      source = "a: ${{ steps.pin.outputs.sha }}\n"
      once = yaml(source)
      expect(span_text(once).length).to eq(span_text(source).length)
      expect(yaml(once)).to eq(once)
    end
  end

  describe "the round-trip guarantee (modes.md 4)" do
    it "returns a document needing no changes byte for byte" do
      source = "a: one two\nb: 'it''s'\nc: [x, y]\n#comment\n"
      expect(yaml(source)).to eq(source)
    end

    it "preserves quoting, indentation and non-ASCII around an edit" do
      expect(yaml(%(a: "Une note... précise"\n), "fr")).to eq(%(a: "Une note… précise"\n))
    end

    it "is idempotent on a document it does change" do
      source = %(a: The "book"... and more\nb: |\n  He said -- loudly\n)
      once = yaml(source)
      expect(once).not_to eq(source)
      expect(yaml(once)).to eq(once)
    end
  end
end

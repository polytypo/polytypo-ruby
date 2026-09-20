# frozen_string_literal: true

require "spec_helper"
require "json"

# spec/rules/analyze.md -- the contract is A1...A5; the decomposition is observation.
#
# Mirrors the JS, Python and Go ports' own analyze suites case for case, including the two that
# are cheap to get wrong (analyze.md section 6): A3 over the whole vendored corpus, and document
# offsets under the mode adapters.
RSpec.describe "Polytypo.analyze" do
  rule_order = %w[spaces ellipsis ranges dashes hyphen quotes apostrophe symbols nbsp].freeze

  def rule_ids(changes)
    changes.map(&:rule_id)
  end

  describe "A1 -- accepts and rejects exactly what .transform does" do
    it "raises POLYTYPO_UNKNOWN_LOCALE for an unknown locale" do
      expect { Polytypo.analyze("x", locale: "xx") }
        .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_UNKNOWN_LOCALE) }
    end

    it "raises POLYTYPO_UNKNOWN_RULE before it raises about the locale" do
      expect { Polytypo.analyze("x", locale: "xx", rules: { "nope" => true }) }
        .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_UNKNOWN_RULE) }
    end

    it "raises POLYTYPO_INVALID_MODE for an unknown mode" do
      expect { Polytypo.analyze("x", locale: "en-US", mode: "asciidoc") }
        .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_INVALID_MODE) }
    end

    it "requires a dialect in markdown mode, as .transform does" do
      expect { Polytypo.analyze("x", locale: "en-US", mode: "markdown") }
        .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_INVALID_DIALECT) }
    end

    it "rejects a dialect outside markdown mode" do
      expect { Polytypo.analyze("x", locale: "en-US", dialect: "commonmark") }
        .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_INVALID_DIALECT) }
    end
  end

  describe "A2 -- pure" do
    it "returns the same list for the same arguments" do
      input = 'She said "hi" -- really...'
      expect(Polytypo.analyze(input, locale: "en-US")).to eq(Polytypo.analyze(input, locale: "en-US"))
    end

    it "does not change what .transform returns" do
      input = 'She said "hi" -- really...'
      before = Polytypo.transform(input, locale: "en-US")
      Polytypo.analyze(input, locale: "en-US")
      expect(Polytypo.transform(input, locale: "en-US")).to eq(before)
    end
  end

  describe "A3 -- empty exactly when .transform changes nothing" do
    it "is empty for text that needs nothing" do
      expect(Polytypo.analyze("Nothing to do here.", locale: "en-US")).to eq([])
    end

    it "is non-empty for text that needs something" do
      expect(Polytypo.analyze("Wait...", locale: "en-US")).not_to be_empty
    end

    it "agrees with .transform on every canonical fixture" do
      fixtures_dir = File.expand_path("../lib/polytypo/data/fixtures", __dir__)
      files = Dir.glob(File.join(fixtures_dir, "*.json")).reject { |f| f.end_with?("locale-resolution.json") }
      raise "no fixture files found" if files.empty?

      offenders = []
      files.sort.each do |path|
        data = JSON.parse(File.read(path))
        data["cases"].each do |c|
          next if c["throws"] || c["dialect"] == "mdx"

          opts = { locale: data["locale"], mode: c["mode"] }
          opts[:dialect] = c["dialect"] if c["dialect"]
          opts[:rules] = c["rules"] if c["rules"]
          opts[:keys] = c["keys"] if c["keys"]

          changed = Polytypo.transform(c["in"], **opts) != c["in"]
          reported = !Polytypo.analyze(c["in"], **opts).empty?
          offenders << "#{data["locale"]}/#{c["id"]}" if changed != reported
        end
      end
      expect(offenders).to eq([])
    end
  end

  describe "A4 -- only rules that were enabled for the call" do
    it "never reports a rule the caller disabled" do
      ids = rule_ids(Polytypo.analyze('She said "hi"...', locale: "en-US", rules: { "quotes" => false }))
      expect(ids).not_to include("quotes")
      expect(ids).to include("ellipsis")
    end

    it "never reports ranges unless it was turned on" do
      input = "chapters 3-5"
      expect(rule_ids(Polytypo.analyze(input, locale: "en-US"))).not_to include("ranges")
      expect(rule_ids(Polytypo.analyze(input, locale: "en-US", rules: { "ranges" => true }))).to include("ranges")
    end
  end

  describe "A5 -- offsets are code points inside the input" do
    it "stays within bounds on a string with astral characters" do
      input = 'A 😀 says "hi" and waits...'
      length = input.codepoints.length
      Polytypo.analyze(input, locale: "en-US").each do |change|
        expect(change.start).to be >= 0
        expect(change.end).to be <= length
        expect(change.start).to be <= change.end
      end
    end

    it "reports code-point offsets" do
      # The emoji is one code point here and two UTF-16 units in the JS runtime; both report 6,
      # which is what makes the offsets portable rather than string-representation-specific.
      first = Polytypo.analyze('😀 and "this"', locale: "en-US").first
      expect(first.rule_id).to eq("quotes")
      expect(first.start).to eq(6)
    end

    # analyze.md section 6: the mistake that passes every text-mode test.
    it "reports document offsets in html mode, not span-local ones" do
      input = '<p class="x">Wait...</p>'
      first = Polytypo.analyze(input, locale: "en-US", mode: "html").first
      expect(first.rule_id).to eq("ellipsis")
      expect(first.start).to eq(input.index("..."))
      expect(first.before).to eq("...")
      expect(first.after).to eq("…")
    end

    it "reports document offsets in a later span too" do
      # Three spans, a non-ASCII character before the change, and the change in the third span:
      # the two markers are the only code points in the joined array with no origin, so a doubled
      # or dropped one shifts this offset and nothing in a one- or two-span document would
      # notice, and "café" puts the UTF-8 byte offset one ahead of the code-point one, so a byte
      # offset leaking out of the span adapter cannot pass either.
      input = "<p>café</p><p>two</p><p>Wait... three</p>"
      first = Polytypo.analyze(input, locale: "en-US", mode: "html").first
      expect(first.rule_id).to eq("ellipsis")
      expect(first.start).to eq(input.index("..."))
      expect(input[0...input.index("...")].bytesize).to eq(first.start + 1)
    end

    it "reports document offsets in markdown mode too" do
      input = "# Title\n\nWait... here\n"
      first = Polytypo.analyze(input, locale: "en-US", mode: "markdown", dialect: "commonmark").first
      expect(first.start).to eq(input.index("..."))
    end
  end

  describe "section 3 -- pipeline order, and section 5 -- overlap" do
    it "reports rules in spec order" do
      ids = rule_ids(Polytypo.analyze('She said "hi" -- wait...', locale: "en-US"))
      expect(ids).to eq(ids.sort_by { |id| rule_order.index(id) })
    end

    it "reports both rules when they touch the same original range" do
      # The French case analyze.md section 5 is written around: two rules, one original index.
      # `spaces` removes the space at 3-4 and `nbsp` inserts at 4-4, in front of the colon the
      # caller wrote at 4 -- the second change's position is the colon's, not the deleted space's.
      changes = Polytypo.analyze("Oui : non", locale: "fr")
      expect(rule_ids(changes)).to eq(%w[spaces nbsp])
      expect([changes[0].before, changes[0].after]).to eq([" ", ""])
      expect([changes[0].start, changes[0].end]).to eq([3, 4])
      expect(changes[1].after).to eq(" ")
      expect([changes[1].start, changes[1].end]).to eq([4, 4])
    end
  end
end

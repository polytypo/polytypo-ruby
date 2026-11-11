# frozen_string_literal: true

require "spec_helper"
require "prop_check"
require "json"

# spec/rules/quote-punctuation.md (spec 1.21.0). The rule is off by default, so every call opts in
# unless it says it does not. Inputs are the author's text; outputs are the whole pipeline's, so
# `quotes`' conversion and this rule's move are seen together.
RSpec.describe "quote-punctuation" do
  include PropCheck

  on = { "quote-punctuation" => true }.freeze

  def us(text, **opts)
    Polytypo.transform(text, locale: "en-US", rules: { "quote-punctuation" => true }, **opts)
  end

  registry = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/locales/registry.json", __dir__)))
  locales = registry["locales"]

  describe "registration and data" do
    it "sits between quotes and apostrophe and defaults to off" do
      order = Polytypo::Engine::Registry.rule_order
      expect(order.index("quote-punctuation")).to eq(order.index("quotes") + 1)
      expect(order.index("apostrophe")).to eq(order.index("quote-punctuation") + 1)
      expect(Polytypo::Engine::Registry.rule_defaults["quote-punctuation"]).to be(false)
    end

    it "is declared inside by en-US alone" do
      inside = locales.select do |tag|
        Polytypo::Engine::Locale.locale_data_raw(tag)["quotes"]["punctuationPlacement"] == "inside"
      end
      expect(inside).to eq(["en-US"])
    end
  end

  describe "locale data validation" do
    def load_with(placement_json)
      raw = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/locales/en-US.json", __dir__)))
      raw["quotes"].delete("punctuationPlacement")
      raw["quotes"]["punctuationPlacement"] = placement_json unless placement_json == :missing
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(/fake-loc\.json\z/).and_return(JSON.generate(raw))
      Polytypo::Engine::Locale.locale_data_raw("fake-loc")
    ensure
      Polytypo::Engine::Locale.instance_variable_get(:@locale_data_raw)&.delete("fake-loc")
    end

    def malformed
      raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_MALFORMED_LOCALE_DATA) }
    end

    it "accepts inside and none" do
      expect(load_with("inside")["quotes"]["punctuationPlacement"]).to eq("inside")
      expect(load_with("none")["quotes"]["punctuationPlacement"]).to eq("none")
    end

    it "rejects a missing field" do
      expect { load_with(:missing) }.to malformed
    end

    it "rejects an unknown value or a wrong type" do
      ["outside", "", "Inside", nil, true, 1, ["inside"]].each do |bad|
        expect { load_with(bad) }.to malformed
      end
    end
  end

  describe "worked examples" do
    it "moves a comma and a full stop inside the closing mark" do
      expect(us('She said "hello", then left.')).to eq("She said “hello,” then left.")
      expect(us('He called it "done". Then he left.')).to eq("He called it “done.” Then he left.")
      expect(us('Call it "ready".')).to eq("Call it “ready.”")
      expect(us("Call it \"ready\".\nNext")).to eq("Call it “ready.”\nNext")
      expect(us('The "first", the "second".')).to eq("The “first,” the “second.”")
      expect(us('Both "a", "b" and "c".')).to eq("Both “a,” “b” and “c.”")
    end

    it "does not treat a complete sentence in the quotation as special" do
      expect(us('"Go home".')).to eq("“Go home.”")
    end

    it "leaves text that is already inside alone" do
      expect(us("She said “hello,” then left.")).to eq("She said “hello,” then left.")
    end

    it "moves for an unpaired curly closing mark (accepted cost)" do
      expect(us("Broken pair”, then")).to eq("Broken pair,” then")
    end

    it "declines after a non-letter, and for every other punctuation mark" do
      expect(us('"Stop!".')).to eq("“Stop!”.")
      expect(us('It said "wait…".')).to eq("It said “wait…”.")
      expect(us('Use "e.g.", then')).to eq("Use “e.g.”, then")
      expect(us('"Route 66".')).to eq("“Route 66”.")
      expect(us("\"He said 'hi'\".")).to eq("“He said ‘hi’”.")
      expect(us('Say "a"; say "b": say "c"?')).to eq("Say “a”; say “b”: say “c”?")
    end

    it "declines unless the punctuation ends its clause" do
      expect(us('"file".txt')).to eq("“file”.txt")
      expect(us('He said ("hi".)')).to eq("He said (“hi”.)")
      expect(us('He said "wait"...')).to eq("He said “wait”…")
      expect(us("a “b”,”c”")).to eq("a “b”,”c”")
    end

    it "does not read the secondary close or the apostrophe" do
      expect(us("Check the dogs’, bowls and cats.")).to eq("Check the dogs’, bowls and cats.")
    end

    it "does nothing unless asked" do
      expect(Polytypo.transform('She said "hello", then left.', locale: "en-US"))
        .to eq("She said “hello”, then left.")
      expect(Polytypo.transform('She said "hello", then left.', locale: "en-US", rules: {}))
        .to eq("She said “hello”, then left.")
      expect(Polytypo.transform('She said "hello", then left.', locale: "en-US",
                                rules: { "quote-punctuation" => false }))
        .to eq("She said “hello”, then left.")
    end

    it "is a no-op in a locale whose placement is none" do
      expect(Polytypo.transform('She said "hello", then left.', locale: "en-GB", rules: on))
        .to eq("She said ‘hello’, then left.")
      expect(Polytypo.transform("Er sagte „Hallo“, dann ging er.", locale: "de-DE", rules: on))
        .to eq("Er sagte „Hallo“, dann ging er.")
    end
  end

  describe "code-point edge cases" do
    it "moves at the very end of the text and at the line breaks that count as spacing" do
      expect(us("a”.")).to eq("a.”")
      ["\n", "\r", " ", " ", "\t"].each do |space|
        expect(us("a”,#{space}b")).to eq("a,”#{space}b")
      end
    end

    it "declines when a quotation mark opens the text (nothing to its left)" do
      expect(us("”.")).to eq("”.")
      expect(us(",”.")).to eq(",”.")
    end

    it "treats an astral code point next to the mark as a non-letter or as content, not as a crash" do
      expect(us("😀”,")).to eq("😀”,")
      expect(us("😀 “a”, 😀")).to eq("😀 “a,” 😀")
      expect(us("a”,😀")).to eq("a”,😀")
      expect(us("a”. 😀")).to eq("a.” 😀")
      expect(us("𝒜”, x")).to eq("𝒜,” x")
    end

    it "declines across a digit, a bracket or a straight quote on the left" do
      expect(us("5”,")).to eq("5”,")
      expect(us(")”,")).to eq(")”,")
      expect(us('"a"')).to eq("“a”")
    end

    it "moves after a non-ASCII letter" do
      expect(us("naïve”, no")).to eq("naïve,” no")
      expect(us("я”. Next")).to eq("я.” Next")
    end

    it "does not move a stop that a following letter, digit or dot keeps in place" do
      expect(us("a”.b")).to eq("a”.b")
      expect(us("a”.1")).to eq("a”.1")
      expect(us("a”..")).to eq("a”..")
    end

    it "is length-preserving and never touches the rest of a processed text" do
      input = "the “first”, the “second”. Done"
      out = us(input)
      expect(out.codepoints.length).to eq(input.codepoints.length)
      expect(out).to eq("the “first,” the “second.” Done")
    end

    it "handles consecutive candidates after an edit (continues from i + 2)" do
      expect(us("a”, b”. c”")).to eq("a,” b.” c”")
    end
  end

  describe "modes, protect, analyze" do
    it "html: one text node moves, a span boundary on any of the three sides declines" do
      expect(us('<p>She said "hello", then left.</p>', mode: "html"))
        .to eq("<p>She said “hello,” then left.</p>")
      expect(us('<p>She said <em>"hello"</em>, then left.</p>', mode: "html"))
        .to eq("<p>She said <em>“hello”</em>, then left.</p>")
      expect(us('<p>She said "<em>hello</em>", then left.</p>', mode: "html"))
        .to eq("<p>She said “<em>hello</em>”, then left.</p>")
      expect(us('<p>She said "hello".</p><p>Next.</p>', mode: "html"))
        .to eq("<p>She said “hello”.</p><p>Next.</p>")
    end

    it "html: the end of the document is not a boundary" do
      expect(us('<p>Call it "ready".</p>', mode: "html")).to eq("<p>Call it “ready.”</p>")
    end

    it "markdown: a delimiter after the stop is a boundary" do
      expect(us(%(She said "hello", then left.\n), mode: "markdown", dialect: "commonmark"))
        .to eq("She said “hello,” then left.\n")
      expect(us('*He said "hi".* Next', mode: "markdown", dialect: "commonmark"))
        .to eq("*He said “hi”.* Next")
    end

    it "yaml: a processable scalar is one span" do
      expect(us('title: She said "hello", then left.', mode: "yaml", keys: ["title"]))
        .to eq("title: She said “hello,” then left.")
    end

    it "text protect: a protected run on either side blocks the move, one elsewhere does not" do
      locate = lambda do |input, needle|
        start = input[0, input.index(needle)].codepoints.length
        [[start, start + needle.codepoints.length]]
      end
      a = 'Set "file".${ext} now'
      expect(us(a, protect: locate.call(a, "${ext}"))).to eq("Set “file”.${ext} now")
      b = 'Use "${name}", then stop.'
      expect(us(b, protect: locate.call(b, "${name}"))).to eq("Use “${name}”, then stop.")
      c = 'Say "hi", then ${x}.'
      expect(us(c, protect: locate.call(c, "${x}"))).to eq("Say “hi,” then ${x}.")
    end

    it "analyze reports one change per move, tagged with the rule" do
      changes = Polytypo.analyze('The "first", the "second".', locale: "en-US", rules: on)
      expect(changes.count { |c| c.rule_id == "quote-punctuation" }).to eq(2)
    end

    it "analyze reports nothing for the rule when it is not enabled" do
      changes = Polytypo.analyze('The "first", the "second".', locale: "en-US")
      expect(changes.map(&:rule_id)).not_to include("quote-punctuation")
    end
  end

  describe "idempotency with the rule enabled" do
    g = PropCheck::Generators

    alphabet = ['"', "'", "“", "”", "‘", "’", "«", "»", "a", "B", "1", ",", ".", ";", "!", "…",
                " ", " ", "\n", "(", ")", "-", "—"]
    alphabet_gen = g.one_of(*alphabet.map { |c| g.constant(c) })
    text_gen = g.array(alphabet_gen, min: 0, max: 24).map(&:join)
    locale_gen = g.one_of(*locales.map { |l| g.constant(l) })

    it "holds over a biased alphabet, in every locale" do
      forall(locale: locale_gen, text: text_gen) do |locale:, text:|
        once = Polytypo.transform(text, locale: locale, rules: on)
        twice = Polytypo.transform(once, locale: locale, rules: on)
        expect(twice).to eq(once), "locale=#{locale} input=#{text.inspect} once=#{once.inspect} twice=#{twice.inspect}"
      end
    end

    it "holds over arbitrary printable ASCII plus a few Unicode letters, in every locale" do
      char_gen = g.one_of(*((" ".."~").to_a + %w[é и 中 ” “]).map { |c| g.constant(c) })
      arbitrary_gen = g.array(char_gen, min: 0, max: 40).map(&:join)
      forall(locale: locale_gen, text: arbitrary_gen) do |locale:, text:|
        once = Polytypo.transform(text, locale: locale, rules: on)
        expect(Polytypo.transform(once, locale: locale, rules: on)).to eq(once)
      end
    end

    it "holds over every string up to 6 characters of the rule's own alphabet in en-US" do
      sweep = ['"', "”", "“", "’", "a", "1", ",", ".", " "]
      broken = []
      moved = 0
      frontier = [""]
      6.times do
        next_frontier = []
        frontier.each do |prefix|
          sweep.each do |ch|
            input = prefix + ch
            next_frontier << input
            once = Polytypo.transform(input, locale: "en-US", rules: on)
            moved += 1 if once != Polytypo.transform(input, locale: "en-US")
            twice = Polytypo.transform(once, locale: "en-US", rules: on)
            broken << input.inspect if twice != once && broken.length < 10
          end
        end
        frontier = next_frontier
      end
      expect(broken).to eq([])
      expect(moved).to be > 1000
    end
  end
end

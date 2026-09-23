# frozen_string_literal: true

require "spec_helper"
require "prop_check"
require "json"

# transform(transform(x)) == transform(x) is a release blocker, not a bug report
# (docs/ARCHITECTURE.md section 6.3). Property-based over a biased alphabet (uniform random
# Unicode almost never produces the adjacent-quote-mark shapes that actually break a pipeline),
# plus bounded exhaustive sweeps, which a defect at this size cannot hide from. Mirrors the other
# three ports' own idempotency test suites.
RSpec.describe "idempotency" do
  include PropCheck

  g = PropCheck::Generators

  registry = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/locales/registry.json", __dir__)))
  locales = registry["locales"]

  locale_gen = g.one_of(*locales.map { |l| g.constant(l) })

  # The characters every rule reads: quote marks, strokes, spacing, digits, brackets, stops.
  hot_chars = [
    '"', "'", "“", "”", "‘", "’", "„", "‚",
    "«", "»", "‹", "›",
    "-", "‐", "‑", "–", "—", " ", " ", " ", "\n",
    ".", ",", ":", ";", "!", "?", "…", "(", ")", "[", "]",
    "0", "1", "9", "a", "B", "x", "é", "и", "k", "m", "%", "§", "№", "σ", "·"
  ]
  hot_char_gen = g.one_of(*hot_chars.map { |c| g.constant(c) })
  hot_text_gen = g.array(hot_char_gen, min: 0, max: 24).map(&:join)

  it "is idempotent over a hot alphabet" do
    forall(locale: locale_gen, text: hot_text_gen) do |locale:, text:|
      once = Polytypo.transform(text, locale: locale)
      twice = Polytypo.transform(once, locale: locale)
      expect(twice).to eq(once), "locale=#{locale} input=#{text.inspect} once=#{once.inspect} twice=#{twice.inspect}"
    end
  end

  it "is idempotent over arbitrary printable ASCII plus a few Unicode letters" do
    arbitrary_char_gen = g.one_of(*((" ".."~").to_a + %w[é и 中]).map { |c| g.constant(c) })
    arbitrary_text_gen = g.array(arbitrary_char_gen, min: 0, max: 40).map(&:join)

    forall(locale: locale_gen, text: arbitrary_text_gen) do |locale:, text:|
      once = Polytypo.transform(text, locale: locale)
      twice = Polytypo.transform(once, locale: locale)
      expect(twice).to eq(once)
    end
  end

  it "is a no-op with every rule disabled" do
    order = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/rules/order.json", __dir__)))
    all_off = order["rules"].to_h { |r| [r["id"], false] }

    forall(locale: locale_gen, text: hot_text_gen) do |locale:, text:|
      out = Polytypo.transform(text, locale: locale, rules: all_off)
      expect(out).to eq(text)
    end
  end

  # Both the input characters and the ones the rules produce: a pass over its own output is what
  # idempotency actually asserts.
  def bounded_strings(alphabet, max_length)
    frontier = [""]
    yield ""
    max_length.times do
      next_frontier = []
      frontier.each do |prefix|
        alphabet.each do |ch|
          candidate = prefix + ch
          next_frontier << candidate
          yield candidate
        end
      end
      frontier = next_frontier
    end
  end

  it "is idempotent over a bounded exhaustive sweep, every locale" do
    # `)` is here for apostrophe.md 3.3's case 2a (spec 1.5.0), under pipeline-idempotency.md 6's
    # standing obligation to widen the alphabet in the same change that fixes a defect its bound
    # cannot reach. It is the one CLOSEDELIM member the alphabet did not already hold: `”` was in
    # it as an emitted quote glyph and covers the quotation half of the class.
    alphabet = ['"', "'", "-", " ", ".", "1", "a", "«", "–", "”", ")"]
    broken = []
    locales.each do |locale|
      bounded_strings(alphabet, 4) do |text|
        next if broken.length >= 10

        once = Polytypo.transform(text, locale: locale)
        twice = Polytypo.transform(once, locale: locale)
        broken << "#{locale}: #{text.inspect} -> #{once.inspect} -> #{twice.inspect}" if twice != once
      end
    end
    expect(broken).to eq([])
  end

  it "is idempotent for mixed-kind straight marks (the shape that broke quotes' first attempt)" do
    alphabet = ['"', "'", "a", " ", "."]
    broken = []
    locales.each do |locale|
      bounded_strings(alphabet, 6) do |text|
        next if broken.length >= 10

        once = Polytypo.transform(text, locale: locale)
        twice = Polytypo.transform(once, locale: locale)
        broken << "#{locale}: #{text.inspect} -> #{once.inspect} -> #{twice.inspect}" if twice != once
      end
    end
    expect(broken).to eq([])
  end

  it "is idempotent around the html line-boundary marker" do
    alphabet = [" ", '"', "-", ".", "a", "1"]
    broken = []
    locales.each do |locale|
      lefts = []
      bounded_strings(alphabet, 2) { |s| lefts << s }
      rights = []
      bounded_strings(alphabet, 2) { |s| rights << s }

      lefts.each do |left|
        rights.each do |right|
          next if broken.length >= 10

          text = "#{left}<!--\n-->#{right}"
          once = Polytypo.transform(text, locale: locale, mode: "html")
          twice = Polytypo.transform(once, locale: locale, mode: "html")
          broken << "#{locale}: #{text.inspect} -> #{once.inspect} -> #{twice.inspect}" if twice != once
        end
      end
    end
    expect(broken).to eq([])
  end
end

# frozen_string_literal: true

require "spec_helper"

# spec/rules/ranges.md §3.2a (spec 1.3.0) -- a symbol repeated closed up on both members, and the
# dashes.md §3.2 step 8 amendment it forced.
RSpec.describe "ranges: closed-up symbols" do
  wj = "⁠"
  en = "–"
  em = "—"

  def ranges(text, locale = "en-US")
    Polytypo.transform(text, locale: locale, rules: { "ranges" => true })
  end

  describe "§3.2a candidacy" do
    it "admits a repeated prefix" do
      expect(ranges("$15-$20")).to eq("$15#{wj}#{en}#{wj}$20")
      expect(ranges("€15-€20", "de-DE")).to eq("€15#{wj}#{en}#{wj}€20")
    end

    it "admits a repeated suffix, the mirror case" do
      expect(ranges("35%-50%")).to eq("35%#{wj}#{en}#{wj}50%")
      expect(ranges("35%-50%", "ru")).to eq("35%#{wj}#{em}#{wj}50%")
      expect(ranges("15°-20°")).to eq("15°#{wj}#{en}#{wj}20°")
    end

    it "requires the same code point on both members" do
      expect(ranges("$15-€20")).to eq("$15-€20")
      expect(ranges("15-$20")).to eq("15-$20")
      expect(ranges("15%-20")).to eq("15%-20")
    end

    it "leaves the elided forms exactly as they were" do
      expect(ranges("$15-20")).to eq("$15#{wj}#{en}#{wj}20")
      expect(ranges("15-20%")).to eq("15#{wj}#{en}#{wj}20%")
    end

    it "consumes at most one code point per side" do
      expect(ranges("US$15-US$20")).to eq("US$15-US$20")
      expect(ranges("15°C-20°C")).to eq("15°C-20°C")
    end

    it "decides both flanks from the original indices, simultaneously" do
      expect(ranges("%15%-%20%")).to eq("%15%#{wj}#{en}#{wj}%20%")
    end

    it "converts a hyphen an author typed between an existing joiner pair" do
      expect(ranges("$15#{wj}-#{wj}$20")).to eq("$15#{wj}#{en}#{wj}$20")
    end
  end

  describe "CLOSED-SYMBOL is an enumeration, not a category" do
    it "admits a block member no other example names" do
      expect(ranges("₹15-₹20")).to eq("₹15#{wj}#{en}#{wj}₹20")
      expect(ranges("₴100-₴200")).to eq("₴100#{wj}#{en}#{wj}₴200")
    end

    it "refuses a currency sign outside the set" do
      # U+058F and U+FFE5 are Sc in Unicode's own classification and deliberately excluded.
      expect(ranges("֏15-֏20")).to eq("֏15-֏20")
      expect(ranges("￥15-￥20")).to eq("￥15-￥20")
    end
  end

  describe "dashes.md §3.2 step 8" do
    witnesses = ["a—$15-$20", "35%-50%—b", "a--15% - 20%", "$1 - $1--a"]

    %w[de-DE ru en-GB fi].each do |locale|
      it "is a fixed point on every witness in #{locale}" do
        witnesses.each do |text|
          once = Polytypo.transform(text, locale: locale, rules: { "ranges" => true })
          twice = Polytypo.transform(once, locale: locale, rules: { "ranges" => true })
          expect(twice).to eq(once)
        end
      end
    end

    it "composes both transparency positions on one side" do
      # Eleven tokens — out of reach of the canonical exhaustive sweep.
      ["a--$15% - $20%", "$15% - $20%--a", "a--$15% - $20%--b"].each do |text|
        once = ranges(text, "de-DE")
        expect(ranges(once, "de-DE")).to eq(once)
      end
    end

    it "makes the symbol shape behave exactly like its all-digit analogue" do
      expect(ranges("a—15-20", "de-DE")).to eq("a—15-20")
      expect(ranges("a—$15-$20", "de-DE")).to eq("a—$15-$20")
      expect(ranges("a--1 - 1", "de-DE")).to eq("a--1 - 1")
      expect(ranges("a--$1 - $1", "de-DE")).to eq("a--$1 - $1")
    end

    it "leaves a tight-parenthetical locale untouched, the boundary of the cost" do
      expect(Polytypo.transform("price--$50--drop", locale: "en-US")).to eq("price—$50—drop")
      expect(Polytypo.transform("Anstieg--50%--war", locale: "de-DE")).to eq("Anstieg--50%--war")
      expect(Polytypo.transform("Anstieg--50--war", locale: "de-DE")).to eq("Anstieg--50--war")
    end

    it "reads effective neighbours in T1's right branch, symbol or no symbol" do
      expect(ranges("a--15#{wj} - 20", "de-DE")).to eq("a--15#{wj} - 20")
      expect(ranges("a--$15#{wj}-#{wj}$20", "de-DE")).to eq("a--$15#{wj}-#{wj}$20")
    end
  end

  describe "the accepted cost, with default options" do
    it "no longer converts a spaced token between matched symbols" do
      expect(Polytypo.transform("$15 - $20", locale: "en-US")).to eq("$15 - $20")
    end

    it "still converts one between unmatched symbols, which never became a candidate" do
      expect(Polytypo.transform("$15 - €20", locale: "en-US")).to eq("$15—€20")
    end
  end
end

# frozen_string_literal: true

require "json"
require "polytypo"

# spec/rules/modes.md 3.4 -- the edge-growth rule's character clause (spec 1.3.0).
#
# Its normative sentence has always been "an edit is discarded if it would place code points at an
# extremity of its span that were not there before". The formalisation r > d is not that rule: it
# misses r == d. dashes P3 admits a run of two OR THREE, so "---" -> U+0020 en-dash U+0020 is
# 3 -> 3 and lands U+0020 on both extremities while the length test sees nothing. In "html",
# shipped at v1.0.0, that produced an element beginning and ending with a space it never held.
RSpec.describe "the edge-growth rule (spec/rules/modes.md 3.4)" do
  # Read from the locale data rather than named here: a hardcoded list rots silently as locales
  # are added, and it would also admit "el", whose dash.parenthetical is "none".
  spaced = Dir.glob(File.expand_path("../lib/polytypo/data/locales/*.json", __dir__)).filter_map do |path|
    next if File.basename(path) == "registry.json"

    data = JSON.parse(File.read(path))
    File.basename(path, ".json") if data.dig("dash", "parenthetical").to_s.end_with?("-spaced")
  end

  spaced.sort.each do |locale|
    it "declines three dashes at a span edge in #{locale}" do
      expect(Polytypo.transform("a<em>---</em>b", locale: locale, mode: "html")).to eq("a<em>---</em>b")
    end
  end

  it "still applies the same edit interior to a span" do
    expect(Polytypo.transform("<p>a---b</p>", locale: "de-DE", mode: "html")).to eq("<p>a – b</p>")
  end

  it "still converts at the edge in an em-tight locale, which emits no U+0020" do
    expect(Polytypo.transform("a<em>---</em>b", locale: "en-US", mode: "html")).to eq("a<em>—</em>b")
  end

  it "still applies a spaced edit that replaces a space with a space at an edge" do
    expect(Polytypo.transform("a<em>x --- y</em>b", locale: "de-DE", mode: "html")).to eq("a<em>x – y</em>b")
  end

  it "still declines two dashes at an edge, by the length clause" do
    expect(Polytypo.transform("a<em>--</em>b", locale: "de-DE", mode: "html")).to eq("a<em>--</em>b")
  end
end

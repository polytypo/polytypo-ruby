# frozen_string_literal: true

require "spec_helper"

# nbsp.md 3.3 step 4 (spec 1.3.0). text mode has no markup concept, so `fr` -- whose
# narrowBeforePunctuation lists ";" -- used to insert U+202F before the ";" that *ends* a
# character reference, and "Bonjour&#160;: oui" stopped being a reference at all. The conformance
# fixtures cover this (fr-nbsp-character-reference-*), but only once the vendored spec is
# refreshed; this spec is what fails today if the guard is removed.
RSpec.describe "N1/N2 character-reference guard" do
  def fr(input)
    Polytypo.transform(input, locale: "fr")
  end

  it "leaves a numeric character reference intact" do
    expect(fr("Bonjour&#160;: oui")).to eq("Bonjour&#160;: oui")
  end

  it "leaves a named character reference intact" do
    expect(fr("Tom &amp; Jerry")).to eq("Tom &amp; Jerry")
  end

  it "tests the shape of a reference, not the named-reference table" do
    expect(fr("a &notaname; b")).to eq("a &notaname; b")
  end

  it "still binds an ordinary semicolon" do
    expect(fr("Oui ; non")).to eq("Oui ; non")
  end

  it "does not fire when no ampersand closes the left walk" do
    expect(fr("Section 4; suite")).to eq("Section 4 ; suite")
  end
end

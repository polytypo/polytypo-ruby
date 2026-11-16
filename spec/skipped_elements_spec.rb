# frozen_string_literal: true

require "polytypo"

RSpec.describe "Polytypo::SKIPPED_ELEMENTS" do
  it "is the ten names in spec order (modes.md 3.6)" do
    expect(Polytypo::SKIPPED_ELEMENTS).to eq(%w[code pre kbd samp var script style textarea svg math])
  end

  it "cannot be modified through the reference" do
    expect(Polytypo::SKIPPED_ELEMENTS).to be_frozen
    expect(Polytypo::SKIPPED_ELEMENTS).to all(be_frozen)
  end

  it "leaves every named element's subtree alone" do
    Polytypo::SKIPPED_ELEMENTS.each do |tag|
      out = Polytypo.transform("<p>a...b</p><#{tag}>c...d</#{tag}>", locale: "en-US", mode: "html")
      expect(out).to eq("<p>a…b</p><#{tag}>c...d</#{tag}>")
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

# spec/rules/quotes.md 3.1 and 3.2 (spec 1.33.0): the inverted marks open a quotation, and a
# lone mark quoted by the other typewriter mark is a mention, not a quotation.
RSpec.describe "Polytypo quotes (spec 1.33.0)" do
  def run(text, locale)
    Polytypo.transform(text, locale: locale, mode: "text")
  end

  it "opens a quotation directly behind an inverted question or exclamation mark" do
    expect(run('¿"Sí"?', "es")).to eq("¿«Sí»?")
    expect(run('¡"Hola"!', "es")).to eq("¡«Hola»!")
    expect(run('¡"Hola"!', "en-US")).to eq("¡“Hola”!")
  end

  it "leaves a quoted lone mark as typed and pairs the rest" do
    expect(run("Press '\"' for a quote and 'x' for exit.", "en-US"))
      .to eq("Press '\"' for a quote and “x” for exit.")
  end

  it "does not disturb an earlier pair and stays a fixed point" do
    %w[en-US en-GB de-DE].each do |locale|
      out = run("'he' '\"'", locale)
      expect(out).to end_with(" '\"'")
      expect(run(out, locale)).to eq(out)
    end
  end
end

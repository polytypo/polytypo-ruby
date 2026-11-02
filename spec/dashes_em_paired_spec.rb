# frozen_string_literal: true

require "spec_helper"

# spec/rules/dashes.md §3.4a and §5.2a (spec 1.18.0) -- dash.parenthetical = "em-paired", decided
# per segment rather than per token. `es` is the one locale that carries it.
RSpec.describe "dashes: em-paired" do
  em = "—"

  def es(text)
    Polytypo.transform(text, locale: "es")
  end

  it "writes a spaced hyphen pair as an em dash pair, tight inside and spaced outside" do
    expect(es("Llegó - por fin - a casa")).to eq("Llegó #{em}por fin#{em} a casa")
  end

  it "closes up the inside of a pair that already has em dashes" do
    expect(es("Llegó #{em} por fin #{em} a casa")).to eq("Llegó #{em}por fin#{em} a casa")
  end

  it "inserts the outer space beside a letter or a digit" do
    expect(es("Llegó--por fin--a casa")).to eq("Llegó #{em}por fin#{em} a casa")
  end

  it "leaves a lone dash, three dashes and the dialogue dash as typed" do
    expect(es("Madrid - la capital")).to eq("Madrid - la capital")
    expect(es("a - b - c - d")).to eq("a - b - c - d")
    expect(es("#{em}Hola #{em}dijo#{em}.")).to eq("#{em}Hola #{em}dijo#{em}.")
  end

  it "does not pair strokes across a sentence terminal" do
    expect(es("Va - dijo. Y - luego")).to eq("Va - dijo. Y - luego")
  end

  it "is a fixed point" do
    once = es("Llegó - por fin - a casa")
    expect(es(once)).to eq(once)
  end

  it "is unchanged for a locale that does not carry the value" do
    expect(Polytypo.transform("a - b - c", locale: "en-US")).to eq("a#{em}b#{em}c")
  end
end

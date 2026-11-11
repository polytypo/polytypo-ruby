# frozen_string_literal: true

require "spec_helper"

# spec/rules/nbsp.md 3.7 -- N5 inserts for spacedUnits and deletes for closedUnits. Every such
# edit changes what a later pass sees, so the claim worth proving is the fixed point.
RSpec.describe "Polytypo nbsp units (spec 1.22.0)" do
  nbsp = "\u00A0"

  def run(text, locale, **opts)
    Polytypo.transform(text, locale: locale, mode: "text", **opts)
  end

  it "inserts U+00A0 for spacedUnits and deletes the space for closedUnits" do
    expect(run("Es sind 20km", "de-DE")).to eq("Es sind 20#{nbsp}km")
    expect(run("Rose 5 %", "en-US")).to eq("Rose 5%")
    expect(run("Rose 5#{nbsp}%", "ru")).to eq("Rose 5%")
  end

  it "leaves beforeUnits to conversion only" do
    expect(run("14 % nebo 20%", "cs")).to eq("14#{nbsp}% nebo 20%")
  end

  it "leaves compounds, file names, identifiers and operations alone" do
    %w[15cm-Norm foto-5kg.png /5km x_5kg H2km A4kg].each do |input|
      expect(run(input, "de-DE")).to eq(input)
    end
    expect(run("10 % 3", "en-US")).to eq("10 % 3")
  end

  atoms = ["5", "0", " ", nbsp, "%", "km", "°C", "kg", "-", ".", ",", "a", "_", "(", "–", "×"]

  %w[de-DE en-US en-GB ru el nl fr-CA hu cs sr].each do |locale|
    it "every string of up to 3 atoms is a fixed point after one pass (#{locale})" do
      walk = lambda do |prefix, depth|
        unless prefix.empty?
          once = run(prefix, locale)
          expect(run(once, locale)).to eq(once), "#{locale}: #{prefix.inspect} -> #{once.inspect}"
        end
        next if depth.zero?

        atoms.each { |atom| walk.call(prefix + atom, depth - 1) }
      end
      walk.call("", 3)
    end

    it "is a fixed point with ranges on (#{locale})" do
      range_atoms = ["1", "5", "%", "°C", "$", " ", nbsp, "-", "--", "–", "—", "km", "a"]
      rng = Random.new(22)
      2000.times do
        input = Array.new(rng.rand(4..16)) { range_atoms[rng.rand(range_atoms.length)] }.join
        once = run(input, locale, rules: { "ranges" => true })
        expect(run(once, locale, rules: { "ranges" => true })).to eq(once), "#{locale}: #{input.inspect}"
      end
    end
  end

  it "does not insert beside the right operand of a multiplication chain (3.7 step 5.5)" do
    expect(run("2 x 3kg", "de-DE")).to eq("2 x 3kg")
  end

  mul_atoms = ["2", "3", " ", nbsp, "\u202F", "x", "\u0445", "kg", "\u043A\u043C", "%"]
  { "de-DE" => 4, "ru" => 4, "cs" => 4 }.each do |locale, depth|
    it "multiplication-chain strings of up to #{depth} atoms are fixed points (#{locale})" do
      failure = nil
      walk = lambda do |prefix, left|
        unless prefix.empty?
          once = run(prefix, locale)
          failure ||= "#{locale}: #{prefix.inspect} -> #{once.inspect}" if run(once, locale) != once
        end
        return if left.zero? || failure

        mul_atoms.each { |atom| walk.call(prefix + atom, left - 1) }
      end
      walk.call("", depth)
      expect(failure).to be_nil
    end
  end
end

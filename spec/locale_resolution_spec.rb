# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "locale resolution" do
  data = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/fixtures/locale-resolution.json", __dir__)))
  cases = data["cases"]
  raise "locale-resolution fixture is empty" if cases.empty?

  probes = [
    'He said "so" -- and left...',
    "Pages 1999-2005, see  p. 7 .",
    "Really?.. 50 % (c) 2026"
  ]

  cases.each do |c|
    it c["id"] do
      tag = c["tagAbsent"] ? "" : c["tag"]

      if c["throws"]
        expect { Polytypo.transform("plain text", locale: tag) }
          .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(c["throws"]) }
        next
      end

      probes.each do |probe|
        via_tag = Polytypo.transform(probe, locale: tag)
        via_canonical = Polytypo.transform(probe, locale: c["resolves"])
        expect(escape_non_ascii(via_tag)).to eq(escape_non_ascii(via_canonical))
      end
    end
  end
end

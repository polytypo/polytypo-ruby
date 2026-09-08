# frozen_string_literal: true

require "spec_helper"
require "json"

# Exercises ARCHITECTURE.md section 7's thread-safety requirement -- the one property this
# runtime can actually test that JS structurally can't ("Go and Ruby ports will be called
# concurrently; JS will not care"). CRuby's GVL makes a data race less likely for pure CPU-bound
# code than Go's true parallelism, but "no shared mutable state" is worth proving directly rather
# than assumed from GVL folklore -- and this gem is expected to also run correctly under JRuby/
# TruffleRuby, which have no GVL at all.
RSpec.describe "concurrent Transform" do
  it "produces correct, uncorrupted output when called from many threads at once" do
    registry = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/locales/registry.json", __dir__)))
    locales = registry["locales"]
    inputs = [
      'She said, "it\'s fine" -- see 3-5 km.',
      'Elle a dit "bonjour" et "au revoir".',
      'Она сказала: "привет" - и ушла...',
      "",
      "plain text with no typography to fix"
    ]

    errors = Queue.new
    threads = Array.new(64) do |g|
      Thread.new do
        locale = locales[g % locales.length]
        input = inputs[g % inputs.length]
        20.times do
          Polytypo.transform(input, locale: locale)
        rescue StandardError => e
          errors << "thread #{g}: #{e.class}: #{e.message}"
        end
      end
    end
    threads.each(&:join)

    collected = []
    collected << errors.pop until errors.empty?
    expect(collected).to eq([])
  end
end

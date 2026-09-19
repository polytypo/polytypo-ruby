# frozen_string_literal: true

require "spec_helper"

# spec/rules/nbsp.md 3.1a -- `narrow_nbsp` moves NARROW-TARGET, it does not post-process.
RSpec.describe "Polytypo narrow_nbsp" do
  nbsp = " "
  nnbsp = " "

  def fr(text, **kwargs)
    Polytypo.transform(text, locale: "fr", **kwargs)
  end

  describe "what it changes" do
    it "writes U+00A0 where N2 would write U+202F" do
      text = "Un délai ? Vraiment ! Et puis ; voilà."
      expect(fr(text)).to eq("Un délai#{nnbsp}? Vraiment#{nnbsp}! Et puis#{nnbsp}; voilà.")
      expect(fr(text, narrow_nbsp: "nbsp"))
        .to eq("Un délai#{nbsp}? Vraiment#{nbsp}! Et puis#{nbsp}; voilà.")
    end

    it "normalises an authored narrow space at a claimed index" do
      expect(fr("Oui#{nnbsp}?", narrow_nbsp: "nbsp")).to eq("Oui#{nbsp}?")
      expect(fr("Oui#{nnbsp}?")).to eq("Oui#{nnbsp}?")
    end

    it "leaves an authored narrow space alone elsewhere" do
      expect(fr("mot#{nnbsp}mot", narrow_nbsp: "nbsp")).to eq("mot#{nnbsp}mot")
    end
  end

  describe "what it does not change" do
    it "claims the same indices under the same guards" do
      expect(fr("12:30 et http://x ; oui", narrow_nbsp: "nbsp")).to eq("12:30 et http://x#{nbsp}; oui")
    end

    it "leaves a sub-rule whose target was already U+00A0" do
      # N1 (the colon) and N8 (fr's primary pair, innerSpace "nbsp") do not move.
      expect(fr("Il a dit : « oui » ; puis ?", narrow_nbsp: "nbsp"))
        .to eq("Il a dit#{nbsp}: «#{nbsp}oui#{nbsp}»#{nbsp}; puis#{nbsp}?")
    end

    %w[en-US de-DE ru].each do |locale|
      it "is a no-op in #{locale}, which never emits U+202F" do
        text = "She said “hi” — really..."
        expect(Polytypo.transform(text, locale: locale, narrow_nbsp: "nbsp"))
          .to eq(Polytypo.transform(text, locale: locale))
      end
    end
  end

  describe "idempotency" do
    it "is a fixed point under the option" do
      ["Un délai ? Vraiment !", "Oui#{nnbsp}?", "Il a dit : « oui » ;"].each do |text|
        once = fr(text, narrow_nbsp: "nbsp")
        expect(fr(once, narrow_nbsp: "nbsp")).to eq(once)
      end
    end

    it "shows why: post-processing the default output is not one" do
      # A caller's gsub is stable only as long as it always runs. Feed it back through the
      # default pipeline and N2 converts it straight back.
      post_processed = fr("Un délai ?").gsub(nnbsp, nbsp)
      expect(post_processed).to eq("Un délai#{nbsp}?")
      expect(fr(post_processed)).to eq("Un délai#{nnbsp}?")
    end
  end

  describe "validation" do
    def code_of(**kwargs)
      Polytypo.transform("x", **kwargs)
      "NO THROW"
    rescue Polytypo::Error => e
      e.code
    end

    it "raises POLYTYPO_INVALID_OPTION for an unknown value" do
      expect(code_of(locale: "fr", narrow_nbsp: "wide")).to eq(Polytypo::CODE_INVALID_OPTION)
    end

    it "is checked after mode and before rules and locale" do
      expect(code_of(locale: "fr", mode: "yaml", narrow_nbsp: "wide")).to eq(Polytypo::CODE_INVALID_MODE)
      expect(code_of(locale: "fr", narrow_nbsp: "wide", rules: { "nope" => true }))
        .to eq(Polytypo::CODE_INVALID_OPTION)
      expect(code_of(locale: "xx", narrow_nbsp: "wide")).to eq(Polytypo::CODE_INVALID_OPTION)
    end

    it "raises even when nbsp is disabled, because the check belongs to the call" do
      expect(code_of(locale: "fr", narrow_nbsp: "wide", rules: { "nbsp" => false }))
        .to eq(Polytypo::CODE_INVALID_OPTION)
    end

    it "accepts the explicit default" do
      expect(fr("Un délai ?", narrow_nbsp: "narrow")).to eq("Un délai#{nnbsp}?")
    end
  end
end

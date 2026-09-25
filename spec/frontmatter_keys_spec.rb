# frozen_string_literal: true

require "polytypo"

# spec/rules/modes.md 3.7.4 -- "markdown" mode's optional frontmatter_keys (spec 1.7.0).
#
# The conformance fixtures cover what the option converts. This file covers what a fixture cannot
# express (the option throw, the ignored-elsewhere rule, the validation order) and the claim the
# section asks a port to test directly: the option cannot change a byte outside the frontmatter
# block, because that block is a text unit of its own.

def fm_doc
  %(---\ntitle: He said "hello" once\nslug: "a - b"\n---\n\nBody "quotes" - here.\n)
end

RSpec.describe "markdown frontmatter_keys (spec/rules/modes.md 3.7.4)" do
  def md(source, locale: "en-US", **opts)
    Polytypo.transform(source, locale: locale, mode: "markdown", dialect: "commonmark", **opts)
  end

  def code_of(source, **opts)
    Polytypo.transform(source, **opts)
    "NO THROW"
  rescue Polytypo::Error => e
    e.code
  end

  def body_of(source)
    index = source.index("\n---", 3)
    index.nil? ? source : source[(index + 4)..]
  end

  describe "what it processes" do
    it "processes a listed key's scalar and nothing else in the block" do
      expect(md(fm_doc, frontmatter_keys: ["title"]))
        .to eq(%(---\ntitle: He said “hello” once\nslug: "a - b"\n---\n\nBody “quotes”—here.\n))
    end

    it "absent means the pre-1.7.0 skip, byte for byte" do
      expect(md(fm_doc))
        .to eq(%(---\ntitle: He said "hello" once\nslug: "a - b"\n---\n\nBody “quotes”—here.\n))
    end

    it "treats an empty list as legal and yields no spans" do
      expect(md(fm_doc, frontmatter_keys: [])).to eq(md(fm_doc))
      expect(Polytypo::Modes::Markdown.frontmatter_spans(fm_doc, Set.new)).to eq([])
    end

    it "matches a bare name at any depth, and only a bare name" do
      nested = %(---\nseo:\n  title: a "b"\ntitle: c "d"\nother:\n  slug: e "f"\n---\n\nx\n)
      expect(md(nested, frontmatter_keys: ["title"]))
        .to eq(%(---\nseo:\n  title: a “b”\ntitle: c “d”\nother:\n  slug: e "f"\n---\n\nx\n))
    end

    it "leaves a TOML block alone, with the option or without it" do
      toml = %(+++\ntitle = "a - b"\n+++\n\nBody - here.\n)
      expect(md(toml, frontmatter_keys: ["title"])).to eq(%(+++\ntitle = "a - b"\n+++\n\nBody—here.\n))
      expect(Polytypo::Modes::Markdown.frontmatter_spans(toml, Set["title"])).to eq([])
    end

    it "adds no spans where there is no block" do
      [%(---\ntitle: a "b"\n\nBody\n), %(\n---\ntitle: a "b"\n---\n\nBody\n)].each do |source|
        expect(md(source, frontmatter_keys: ["title"])).to eq(md(source))
        expect(Polytypo::Modes::Markdown.frontmatter_spans(source, Set["title"])).to eq([])
      end
    end

    it "keeps both delimiters and every line terminator outside every span, CRLF included" do
      crlf = %(---\r\ntitle: a "b"\r\n---\r\n\r\nBody\r\n)
      spans = Polytypo::Modes::Markdown.frontmatter_spans(crlf, Set["title"])
      chars = crlf.chars
      expect(spans.map { |s| chars[s.start...s.end].join }).to eq([%(a "b")])
      expect(md(crlf, frontmatter_keys: ["title"])).to eq(%(---\r\ntitle: a “b”\r\n---\r\n\r\nBody\r\n))
    end
  end

  describe "the block is its own text unit" do
    it "cannot pair an unbalanced mark across the block" do
      source = %(---\ntitle: He said "hello\n---\n\nworld" she said\n)
      expect(md(source, frontmatter_keys: ["title"])).to eq(source)
      # The discriminator: as one unit those two marks do pair, which is what the rule refuses.
      expect(Polytypo.transform(%(title: He said "hello\n\nworld" she said\n), locale: "en-US"))
        .to eq(%(title: He said “hello\n\nworld” she said\n))
    end

    it "cannot change a byte outside the block, whatever the option is set to" do
      sources = [
        fm_doc,
        %(---\ntitle: "x"\n---\n\nBody - one "two" three...\n),
        %(---\nsummary: |\n  a - b\n  c - d\n---\n\nBody - e "f"...\n),
        %(---\ntitle: a\n---\nAbutting body "x" - y\n),
      ]
      sources.each do |source|
        [[], ["title"], %w[title slug summary seo]].each do |keys|
          expect(body_of(md(source, frontmatter_keys: keys)))
            .to eq(body_of(md(source))), "#{source.inspect} with #{keys.inspect}"
        end
      end
    end

    it "is idempotent under its own options, block and body together" do
      sources = [fm_doc, %(---\ntitle: a -- b "c"\nx: keep -- me\n---\n\nBody -- "d"\n)]
      %w[en-US de-DE fr ru].each do |locale|
        sources.each do |source|
          once = md(source, locale: locale, frontmatter_keys: %w[title summary])
          expect(md(once, locale: locale, frontmatter_keys: %w[title summary])).to eq(once)
        end
      end
    end
  end

  describe "validation" do
    it "raises the general option code when given and not an Array of Strings" do
      base = { locale: "en-US", mode: "markdown", dialect: "commonmark" }
      ["title", ["title", 7], 7, { "title" => true }].each do |value|
        expect(code_of(fm_doc, **base, frontmatter_keys: value)).to eq(Polytypo::CODE_INVALID_OPTION)
      end
      expect(code_of(fm_doc, **base, frontmatter_keys: ["title"])).to eq("NO THROW")
    end

    it "is checked after the dialect" do
      expect(code_of(fm_doc, locale: "en-US", mode: "markdown", frontmatter_keys: "bad"))
        .to eq(Polytypo::CODE_INVALID_DIALECT)
      expect(code_of(fm_doc, locale: "en-US", mode: "markdown", dialect: "mdx", frontmatter_keys: "bad"))
        .to eq(Polytypo::CODE_INVALID_DIALECT)
    end

    it "is ignored, and not validated, in the other three modes" do
      source = %(title: a "b"\n)
      expect(code_of(source, locale: "en-US", frontmatter_keys: "bad")).to eq("NO THROW")
      expect(code_of(source, locale: "en-US", mode: "html", frontmatter_keys: ["t"])).to eq("NO THROW")
      expect(code_of(source, locale: "en-US", mode: "yaml", keys: ["title"], frontmatter_keys: "bad"))
        .to eq("NO THROW")
      expect(Polytypo.transform(source, locale: "en-US", frontmatter_keys: ["title"]))
        .to eq(Polytypo.transform(source, locale: "en-US"))
    end
  end

  describe "analyze" do
    it "reports both units in document offsets, in order" do
      changes = Polytypo.analyze(fm_doc, locale: "en-US", mode: "markdown", dialect: "commonmark",
                                         frontmatter_keys: ["title"])
      starts = changes.map(&:start)
      expect(changes.length).to be > 1
      expect(starts).to eq(starts.sort)
      expect(starts.first).to be < fm_doc.index("\n---", 3)
      expect(changes.map(&:end).max).to be <= fm_doc.length
    end
  end
end

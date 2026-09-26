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

  # spec/rules/modes.md 3.7.3a (spec 1.8.0). The block's extent is this runtime's own scan, not
  # comrak's front_matter_delimiter extension: that extension required both fences to match the
  # literal string exactly, so one trailing space handed the metadata to the rules as prose
  # (polytypo/polytypo#58). The fixtures pin one trailing space, one trailing tab and the
  # negatives; what follows is the rest of the edge surface, and every example asserts BOTH halves
  # -- the body's skip and the option's content range -- because one scan answering both is the
  # claim the section makes.
  describe "where the block begins and ends (3.7.3a)" do
    def fenced(opener, closer, eol: "\n", title: %(a "b"), body: %(Body "c" here.))
      [opener, "title: #{title}", closer, "", body].map { |line| line + eol }.join
    end

    def spans_text(source, keys)
      chars = source.chars
      Polytypo::Modes::Markdown.frontmatter_spans(source, Set[*keys]).map { |s| chars[s.start...s.end].join }
    end

    def expect_block(source, opener, closer, eol: "\n")
      skipped = fenced(opener, closer, eol: eol, body: %(Body “c” here.))
      expect(md(source)).to eq(skipped)
      expect(spans_text(source, ["title"])).to eq([%(a "b")])
      expect(md(source, frontmatter_keys: ["title"]))
        .to eq(fenced(opener, closer, eol: eol, title: %(a “b”), body: %(Body “c” here.)))
    end

    it "admits several trailing spaces on the opening fence" do
      expect_block(fenced("---   ", "---"), "---   ", "---")
    end

    it "admits a trailing tab on either fence" do
      expect_block(fenced("---\t", "---\t"), "---\t", "---\t")
    end

    it "admits a mix of spaces and tabs, in any order" do
      expect_block(fenced("--- \t \t", "---\t "), "--- \t \t", "---\t ")
    end

    it "admits trailing whitespace on the closing fence alone" do
      expect_block(fenced("---", "--- "), "---", "--- ")
    end

    it "gives a CRLF document with a trailing space on its fence the same block as LF would" do
      source = fenced("--- ", "---", eol: "\r\n")
      # The span text carries no U+000D: it belongs to the terminator, which is outside every span.
      expect_block(source, "--- ", "---", eol: "\r\n")
      crlf = md(source, frontmatter_keys: ["title"])
      lf = md(fenced("--- ", "---"), frontmatter_keys: ["title"])
      expect(crlf.gsub("\r\n", "\n")).to eq(lf)
    end

    it "closes on a last line that carries no terminator" do
      source = %(--- \ntitle: a "b"\n--- )
      expect(md(source)).to eq(source)
      expect(spans_text(source, ["title"])).to eq([%(a "b")])
      expect(md(source, frontmatter_keys: ["title"])).to eq(%(--- \ntitle: a “b”\n--- ))
    end

    it "gives both halves the same answer where there is no block" do
      sources = [
        %(--- yaml\ntitle: a "b"\n---\n\nBody\n),    # step 2: not whitespace after the delimiter
        %(----\ntitle: a "b"\n----\n\nBody\n),       # a fourth dash is not whitespace either
        %( ---\ntitle: a "b"\n---\n\nBody\n),        # step 1: the document must BEGIN with it
        %(---\ntitle: a "b"\n ---\n\nBody\n),        # step 3: a closer is a line, not found in one
        %(---\ntitle: a "b"\n+++\n\nBody\n),         # step 3: the closer is the same delimiter
        %(---\ntitle: a "b"\n...\n\nBody\n),         # step 3: "..." closes nothing
        %(---\ntitle: a "b"\n\nBody\n)               # step 4: no closer, no block
      ]
      sources.each do |source|
        expect(spans_text(source, ["title"])).to eq([]), source.inspect
        expect(md(source, frontmatter_keys: ["title"])).to eq(md(source)), source.inspect
      end
    end

    it "treats an opener immediately followed by a closer as a block with no content" do
      source = %(--- \n---\n\nBody "c" here.\n)
      expect(spans_text(source, ["title"])).to eq([])
      expect(md(source, frontmatter_keys: ["title"])).to eq(%(--- \n---\n\nBody “c” here.\n))
    end

    it "steps over a single leading byte-order mark, offsets included" do
      source = %(﻿--- \ntitle: a "b"\n---\n\nBody "c" here.\n)
      expect(md(source)).to eq(%(﻿--- \ntitle: a "b"\n---\n\nBody “c” here.\n))
      # The mark shifts every offset in the block by one, which is what a fixture on the skip
      # path cannot catch: there a wrong extent costs prose, here it costs the right characters.
      expect(spans_text(source, ["title"])).to eq([%(a "b")])
      expect(md(source, frontmatter_keys: ["title"])).to eq(%(﻿--- \ntitle: a “b”\n---\n\nBody “c” here.\n))
    end

    it "skips a TOML block whole when its fence carries whitespace, and still yields no spans" do
      source = %(+++ \ntitle = "a - b"\n+++\n\nBody - here.\n)
      expect(md(source)).to eq(%(+++ \ntitle = "a - b"\n+++\n\nBody—here.\n))
      expect(spans_text(source, ["title"])).to eq([])
      expect(md(source, frontmatter_keys: ["title"])).to eq(md(source))
    end

    it "masks the block out of the source the parser sees" do
      # A fence inside a metadata value would otherwise pair with the body's own fence, and the
      # body's code block and its prose would swap roles. Suppressing spans cannot repair that:
      # the damage is in what the parser concluded.
      source = %(--- \nx: |\n  ```\n---\n\n```\ncode "q" here\n```\n\nBody "q" here.\n)
      masked = %(--- \nx: |\n  ```\n---\n\n```\ncode "q" here\n```\n\nBody “q” here.\n)
      expect(md(source)).to eq(masked)
      expect(md(source, frontmatter_keys: ["x"])).to eq(masked)
    end

    it "reads the block's lines as CommonMark does, with lone carriage returns" do
      source = %(---\rtitle: "Une note"\r---\r\rBody has "quotes" here.\r)
      expect(md(source)).to eq(%(---\rtitle: "Une note"\r---\r\rBody has “quotes” here.\r))
      # And a final U+000D with no U+000A still closes the block: end of input ends a line.
      expect(md(%(---\r\ntitle: "Une note"\r\n---\r))).to eq(%(---\r\ntitle: "Une note"\r\n---\r))
    end

    it "declines only the content line that carries the stray carriage return (3.7.4)" do
      # Per line, as 3.8.4 step 1 declines a line containing U+0009: a stray U+000D inside one
      # value costs that value, not the block. The content scan reads the ORIGINAL U+000D -- the
      # replacement that works around comrak's column defect is the parser's copy only.
      source = %(---\ntitle: a\r"b"\nsummary: c "d"\n---\n\nBody "e".\n)
      expect(spans_text(source, %w[title summary])).to eq([%(c "d")])
      expect(md(source, frontmatter_keys: %w[title summary]))
        .to eq(%(---\ntitle: a\r"b"\nsummary: c “d”\n---\n\nBody “e”.\n))
    end

    it "declines the content of a lone-carriage-return block outright (3.7.4)" do
      # The block is found by CommonMark's line model and the content read by 3.8.4's LF-only one,
      # which would see one line, pair marks across mapping lines and put the U+000D in a span.
      [%(---\rtitle: a "b"\r---\r\rBody "c".\r), %(---\rtitle: a "b"\rslug: "x"\r---\r\rBody "c".\r)].each do |source|
        expect(spans_text(source, ["title"])).to eq([]), source.inspect
        expect(md(source, frontmatter_keys: ["title"])).to eq(md(source)), source.inspect
      end
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

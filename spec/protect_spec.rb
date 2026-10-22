# frozen_string_literal: true

require "spec_helper"

# spec/rules/modes.md 3.9 (spec 1.13.0): `protect`, the caller's own skipped regions. The
# conformance runner covers the fixtures; this file covers what a fixture cannot express: the
# ranges moving with the edits (3.9.5), the validation order against options a fixture cannot
# vary, and analyze's obligations (3.9.6).
RSpec.describe "protect" do
  def invalid_option
    raise_error(Polytypo::Error) { |e| expect(e.code).to eq(Polytypo::CODE_INVALID_OPTION) }
  end

  # The protected runs located in the output, taken from the first call's own edits.
  def run_mapped(input, locale, protect)
    cp = input.codepoints
    holes = Polytypo::Engine::Protect.resolve(protect, cp.length)
    _resolved, locale_data, plan = Polytypo::Engine::Pipeline.prepare(locale, nil)
    ctx = Polytypo::Engine::RuleContext.new(mode: "text", dialect: nil, locale: locale,
                                            narrow_target: Polytypo::Engine::NARROW_NO_BREAK_SPACE)
    Polytypo::Engine::Protect.run_mapped(cp, holes, plan, locale_data, ctx)
  end

  describe "the worked example (modes.md 3.9)" do
    it "lets the dash see the hole as content" do
      expect(Polytypo.transform("${x} - Rules", locale: "en-US", protect: [[0, 4]])).to eq("${x}—Rules")
      expect(Polytypo.transform("${x} - Rules", locale: "en-GB", protect: [[0, 4]])).to eq("${x} – Rules")
    end

    it "treats nil, [] and absent as the same call" do
      text = "a - b... \"c\""
      plain = Polytypo.transform(text, locale: "en-US")
      expect(Polytypo.transform(text, locale: "en-US", protect: nil)).to eq(plain)
      expect(Polytypo.transform(text, locale: "en-US", protect: [])).to eq(plain)
      expect(Polytypo.analyze(text, locale: "en-US", protect: [])).to eq(Polytypo.analyze(text, locale: "en-US"))
    end

    it "indexes by code point: an astral character before and inside a hole" do
      emoji = "\u{1F600}"
      input = "#{emoji} ${#{emoji}} - x"
      start = input.codepoints.index("$".ord)
      out = Polytypo.transform(input, locale: "en-US", protect: [[start, start + 4]])
      expect(out).to eq("#{emoji} ${#{emoji}}—x")
      expect { Polytypo.transform(input, locale: "en-US", protect: [[start, input.codepoints.length + 1]]) }
        .to invalid_option
    end

    it "merges touching ranges into one run" do
      expect(Polytypo.transform("${a}${b} - x", locale: "en-US", protect: [[0, 4], [4, 8]]))
        .to eq(Polytypo.transform("${a}${b} - x", locale: "en-US", protect: [[0, 8]]))
    end
  end

  describe "refusals" do
    it "refuses every malformed range" do
      [
        "x", { start: 0, end: 1 }, [1], [[0, 1, 2]], [[0]], [[0.0, 1]], [[0, 1.5]], [["0", 1]],
        [[true, 2]], [{ "start" => 0, "end" => 1 }], [nil], [[-1, 2]], [[2, 2]], [[3, 2]],
        [[0, 4], [3, 6]], [[5, 7], [0, 2]], [[0, 99]]
      ].each do |value|
        expect { Polytypo.transform("abcdef", locale: "en-US", protect: value) }
          .to invalid_option, "transform #{value.inspect}"
        expect { Polytypo.analyze("abcdef", locale: "en-US", protect: value) }
          .to invalid_option, "analyze #{value.inspect}"
      end
    end

    it "refuses a non-empty list outside text mode and accepts []" do
      expect { Polytypo.transform("<p>a</p>", locale: "en-US", mode: "html", protect: [[0, 1]]) }.to invalid_option
      expect { Polytypo.analyze("<p>a</p>", locale: "en-US", mode: "html", protect: [[0, 1]]) }.to invalid_option
      expect { Polytypo.transform("a", locale: "en-US", mode: "markdown", dialect: "commonmark", protect: [[0, 1]]) }
        .to invalid_option
      expect { Polytypo.analyze("a", locale: "en-US", mode: "yaml", keys: ["a"], protect: [[0, 1]]) }.to invalid_option
      expect { Polytypo.transform("<p>a</p>", locale: "en-US", mode: "html", protect: "x") }.to invalid_option
      expect(Polytypo.transform("<p>a - b</p>", locale: "en-US", mode: "html", protect: [])).to eq("<p>a—b</p>")
    end
  end

  describe "validation order (modes.md 3.9.2)" do
    def code_of
      yield
    rescue Polytypo::Error => e
      e.code
    end

    it "reports an earlier option's error ahead of a malformed protect" do
      bad = [[3, 2]]
      expect(code_of { Polytypo.transform("abc", locale: "en-US", rules: { "nosuch" => true }, protect: bad) })
        .to eq(Polytypo::CODE_UNKNOWN_RULE)
      expect(code_of { Polytypo.transform("abc", locale: "xx", protect: bad) }).to eq(Polytypo::CODE_UNKNOWN_LOCALE)
      expect(code_of { Polytypo.transform("abc", locale: "en-US", narrow_nbsp: "x", protect: bad) })
        .to eq(Polytypo::CODE_INVALID_OPTION)
      expect(code_of { Polytypo.transform("abc", locale: "en-US", mode: "nope", protect: bad) })
        .to eq(Polytypo::CODE_INVALID_MODE)
      expect(code_of { Polytypo.analyze("abc", locale: "en-US", rules: { "nosuch" => true }, protect: bad) })
        .to eq(Polytypo::CODE_UNKNOWN_RULE)
    end

    it "reports dialect and keys errors ahead of a non-empty protect outside text mode" do
      expect(code_of { Polytypo.transform("a", locale: "en-US", mode: "markdown", dialect: "nope", protect: [[0, 1]]) })
        .to eq(Polytypo::CODE_INVALID_DIALECT)
      expect(code_of { Polytypo.analyze("a", locale: "en-US", mode: "markdown", dialect: "nope", protect: [[0, 1]]) })
        .to eq(Polytypo::CODE_INVALID_DIALECT)
      expect(code_of { Polytypo.transform("a: b", locale: "en-US", mode: "yaml", protect: [[0, 1]]) })
        .to eq(Polytypo::CODE_INVALID_OPTION)
      expect(code_of do
        Polytypo.transform("a", locale: "en-US", mode: "markdown", dialect: "commonmark",
                                frontmatter_keys: "x", protect: [[0, 1]])
      end).to eq(Polytypo::CODE_INVALID_OPTION)
    end
  end

  describe "analyze (modes.md 3.9.6, analyze.md 2 and 6)" do
    it "ends a change at the last replaced code point, not at the next one with an origin" do
      html = "<p>x--<code>cc</code>y</p>"
      change = Polytypo.analyze(html, locale: "en-US", mode: "html").find { |c| c.rule_id == "dashes" }
      expect([change.start, change.end]).to eq([4, 6])
      expect(Polytypo.transform(html, locale: "en-US", mode: "html")).to eq("<p>x—<code>cc</code>y</p>")
    end

    it "does the same beside a protected run" do
      change = Polytypo.analyze("x--${a}y", locale: "en-US", protect: [[3, 7]]).find { |c| c.rule_id == "dashes" }
      expect([change.start, change.end]).to eq([1, 3])
    end

    it "reports offsets into the input as passed, after an astral character" do
      emoji = "\u{1F600}"
      changes = Polytypo.analyze("#{emoji}--${a}", locale: "en-US", protect: [[3, 7]])
      expect(changes.map { |c| [c.start, c.end] }).to eq([[1, 3]])
    end
  end

  describe "sweep over templates with holes" do
    tokens = ["a", "bc", "1", " ", "  ", "-", "--", "---", "...", ".", ",", "!", "?", ":", ";", "–", "—",
              '"', "'", "“", "”", "‘", "’", "(", ")", "\n", "'s", "n't", "km", "%",
              "\u{1F600}", "é", "«", "»", "„"].freeze
    holes = ["${x}", "{n}", "<b>", "{a, plural, one {#}}", "'{b}'", "{\n}", "{ }", "\u{1F600}"].freeze
    locales = %w[en-US en-GB de-DE fr ru fi pl tr].freeze

    it "keeps every protected run, is a fixed point under moved ranges, and never reports across a run" do
      rng = Random.new(1_300)
      checked = 0
      locales.each do |locale|
        200.times do
          input = +""
          ranges = []
          rng.rand(3..10).times do
            if rng.rand < 0.2
              hole = holes[rng.rand(holes.length)]
              from = input.length
              input << hole
              ranges << [from, input.length]
            else
              input << tokens[rng.rand(tokens.length)]
            end
          end

          out, moved = run_mapped(input, locale, ranges)
          expect(out).to eq(Polytypo.transform(input, locale: locale, protect: ranges))
          cp = input.codepoints
          out_cp = out.codepoints
          merged = Polytypo::Engine::Protect.resolve(ranges, cp.length)
          merged.zip(moved).each do |(s, e), (ms, me)|
            expect(out_cp[ms...me]).to eq(cp[s...e]), "hole lost: #{input.inspect} -> #{out.inspect}"
          end

          expect(Polytypo.transform(out, locale: locale, protect: moved))
            .to eq(out), "not a fixed point: locale=#{locale} #{input.inspect} -> #{out.inspect}"

          changes = Polytypo.analyze(input, locale: locale, protect: ranges)
          expect(changes.empty?).to eq(out == input)
          changes.each do |c|
            expect(c.start).to be_between(0, cp.length)
            expect(c.end).to be_between(c.start, cp.length)
            merged.each do |s, e|
              expect(c.start < e && c.end > s).to be(false), "range overlaps a hole: #{input.inspect} #{c}"
            end
          end
          checked += 1
        end
      end
      expect(checked).to eq(locales.length * 200)
    end
  end
end

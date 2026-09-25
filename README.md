<p align="center">
  <img src="https://raw.githubusercontent.com/polytypo/polytypo/main/brand/logo/polytypo-lockup-stacked.svg" alt="polytypo" width="260">
</p>

<h1 align="center">polytypo</h1>

<p align="center">
  <a href="https://rubygems.org/gems/polytypo"><img src="https://img.shields.io/gem/v/polytypo.svg" alt="Gem version"></a>
  <a href="https://github.com/polytypo/polytypo-ruby/actions/workflows/ci.yml"><img src="https://github.com/polytypo/polytypo-ruby/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  Locale-correct quotes, dashes, ellipses, apostrophes, symbols and no-break spaces —<br>
  one portable spec, designed for byte-identical output across runtimes.
</p>

<p align="center">
  <strong>Try it live, no install: <a href="https://polytypo.dev/">polytypo.dev</a></strong>
</p>

This is the Ruby implementation. The full spec — all locales, all rules, worked examples in
each — lives in [polytypo/polytypo](https://github.com/polytypo/polytypo). This runtime supports
the `text`, `html` and `yaml` modes fully, and `markdown` for the `commonmark` dialect only — `mdx`
returns `POLYTYPO_INVALID_DIALECT` (no MDX/JSX parser is available for Ruby; see
[Supported dialects](#supported-dialects)).

## Install

```sh
gem install polytypo
```

Or in a Gemfile:

```ruby
gem "polytypo"
```

## Usage

```ruby
require "polytypo"

Polytypo.transform(%q{She said, "it's fine" -- but I wasn't sure...}, locale: "en-US")
# => "She said, “it’s fine”—but I wasn’t sure…"
```

Same input, one locale changed — quotes, dash spacing and all follow the target locale, not a
single hardcoded style:

```ruby
Polytypo.transform(%q{Sie sagte: "Alles gut" -- aber ich war mir nicht sicher...}, locale: "de-DE")
# => "Sie sagte: „Alles gut“ – aber ich war mir nicht sicher…"
```

HTML and Markdown are first-class modes, not an afterthought — tags, attributes and fenced code
are left alone; only text content is touched:

```ruby
Polytypo.transform(%q{<a title="test... wait">Wait... she said "go on."</a>}, locale: "en-US", mode: "html")
# => "<a title=\"test... wait\">Wait… she said “go on.”</a>"
```

`locale:` has no default anywhere and must always be passed explicitly — there is no silent
fallback to English. `mode:` defaults to `"text"` if omitted.

```ruby
Polytypo.transform(input, locale: "fr", mode: "markdown", dialect: "commonmark")
```

`yaml` mode is the one that asks something of you, and it asks for a reason. YAML is a data
format with prose in some of it, so you name the keys whose values are prose; there is no default
and no guess:

```ruby
Polytypo.transform("summary: Rates -- all of them...\nrun: git diff -- a--b\n",
                   locale: "en-US", mode: "yaml", keys: ["summary"])
# => "summary: Rates—all of them…\nrun: git diff -- a--b\n"
```

Nothing in YAML's syntax separates a sentence from a shell script: `description` holds one and
`run` holds the other, spelled identically. Quoting, indentation, anchors and a block scalar's
chomping indicator are never decoded and rewritten — the file is located, not re-emitted — so the
trailing newlines of a `|+` block come back exactly as you wrote them. An empty `keys:` array is
legal and processes nothing, and `yaml` mode needs no parser at all.

In `markdown` mode frontmatter is skipped whole by default, delimiters included — it is a
machine-read block, and `fr` would put a narrow no-break space in front of the colon of every
field in it. On a site whose frontmatter carries the headline that leaves the most visible string
on the page untouched, so name the keys you want processed:

```ruby
Polytypo.transform(
  %(---\ntitle: He said "hello" once\nslug: "he-said-hello"\n---\n\nThe body was typeset all along.\n),
  locale: "en-US", mode: "markdown", dialect: "commonmark", frontmatter_keys: ["title"]
)
# ---
# title: He said “hello” once
# slug: "he-said-hello"
# ---
#
# The body was typeset all along.
```

Without `frontmatter_keys:` nothing in the block changes, and a key you do not name never does. The
block is read with the same scan `yaml` mode uses, so it refuses the same constructs — a
single-quoted scalar containing `''` among them, which is how an apostrophe is written inside single
quotes, so `title: 'It''s a test'` comes back untouched. The block is also processed separately from
the body, which shows up in exactly one place: an unbalanced quotation mark in `title` cannot pair
with a mark in your first paragraph.

`require "polytypo"` never loads the native `commonmarker` extension unless you actually call
`Polytypo.transform` with `mode: "markdown"` — the require happens lazily, inside the markdown
pipeline only. A single `Polytypo.transform` module method (not separate
`polytypo/text`/`html`/`markdown` gems) is the idiomatic Ruby shape for this — Ruby's dynamic
`require` already gets you the same dependency isolation JS/Python's subpath split exists for,
without a separate namespace per mode.

`Polytypo.analyze` runs the same pipeline and reports what it would do instead of doing it — one
record per edit, each with the rule that made it and code-point offsets into the input you passed
(into the **document**, in `html`, `markdown` and `yaml` mode, not into a span):

```ruby
Polytypo.analyze(%q{Wait... "really"?}, locale: "en-US")
# => [#<data Polytypo::Change rule_id="ellipsis", start=4, end=7, before="...", after="…">,
#     #<data Polytypo::Change rule_id="quotes", start=8, end=9, before="\"", after="“">, ...]
```

It is a report, not a patch. The list is empty exactly when `Polytypo.transform` would return the
input unchanged, and every `rule_id` is a rule that was enabled for that call — but two rules may
touch the same original range (French `spaces` deletes the space before `:` and `nbsp` puts a
no-break one back), so replaying the list is not guaranteed to reproduce the output. Call
`Polytypo.transform` for the text. Full contract: `spec/rules/analyze.md`.

### Errors

Every error `Polytypo.transform` raises is a `Polytypo::Error` carrying one of seven stable
codes — check `#code`, not the message text, which is English and informative but not part of
the contract:

```ruby
begin
  Polytypo.transform("x", locale: "xx-ZZ")
rescue Polytypo::Error => e
  e.code # => "POLYTYPO_UNKNOWN_LOCALE"
end
```

## Supported dialects

`markdown` mode requires a `dialect:`, exactly as the spec requires (no default, detection is
forbidden). This runtime supports `dialect: "commonmark"` (CommonMark plus GFM — tables,
strikethrough, task lists, autolink literals). `dialect: "mdx"` is a real dialect the spec names,
but this runtime has no MDX/JSX parser for it and raises `Polytypo::Error` with
`POLYTYPO_INVALID_DIALECT` immediately rather than silently mishandling it — a narrower, honest
conformance claim, not a port defect.

## Thread safety

`Polytypo.transform` is a pure module method with no class-level mutable state: safe to call
concurrently from any number of `Thread`s with no external synchronization.

## Licence

MIT. See [LICENSE](LICENSE).

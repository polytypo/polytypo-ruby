# Vendored spec subset

This directory is a manually-synced copy of the subset of `polytypo/polytypo`'s canonical `spec/`
that this gem needs at runtime: `locales/`, `fixtures/`, `rules/order.json`, `rules/dashes.md`,
`schema/`, `VERSION`, `UNICODE`. It is **not** the canonical spec — the rest of the normative
prose (`spec/rules/*.md` beyond `dashes.md`) and `validate-spec.mjs` live only in
`polytypo/polytypo`.

Named `lib/polytypo/data/`, not `vendor/polytypo-spec/` like the JS/Python ports: a Ruby
gemspec's `files` list can include any path directly, so there is no need for a separate
`vendor/` staging copy plus a second, separately-generated package-data copy the way Python
needed (its build backend does not include arbitrary files without explicit config). This is the
one copy, shipped as part of the gem's own `lib/` payload and loaded via `File.read` relative to
`__dir__` at runtime — never a network or external-filesystem read.

Editing a file here does not change the spec; it only drifts this copy from canonical. When
canonical's `spec/` changes, re-copy the affected files here.

CI checks that it was done. `script/check-vendored-spec.sh` compares every file in this
directory against canonical `polytypo/polytypo` at tag `spec-v` + this directory's own
`VERSION`, and fails on any difference. Three details: the files this repository authors
itself are listed in `.not-canonical` and skipped; `locales/*.json` are compared with the
`sources` array dropped from both sides, which is the one field a vendored copy may
legitimately differ in; and a file here with no canonical counterpart is a failure, so a
canonical rename cannot pass unnoticed. Completeness is deliberately not checked — each
runtime vendors its own subset, and the subsets differ.

Before that check existed, this half of the tree went stale unnoticed in four of the five
ports at once: the data half is proved by the test suite, and nothing at all read the prose.
See `polytypo/polytypo` issue #56. How this vendoring will work
long-term (submodule, per-ecosystem spec package, or something else) is an open decision tracked
in `polytypo/polytypo`'s roadmap; this is the interim, manually-synced form — the same status
every other port's vendored copy has.

## `locales/*.json` here carry no `sources`

The canonical files do, and mandatorily — `spec/schema/locale.schema.json` makes `sources`
required with `minItems: 1`, and `validate-spec.mjs` fails a locale without a citation. This copy
drops that one field, because these exact files are what ships: no rule reads the citations, and
they are 94% of the locale payload by raw bytes (193 KB of 206 KB, against 13 KB of everything the
engine actually consults). Keeping them here would put a quarter-megabyte of citation prose in
every install of this package.

So this is one field narrower than the canonical file, deliberately, and it is not drift: the
directory was always "the subset it needs" (see the paragraph above). **The citations are
evidence and they are not weakened — read them in `polytypo/polytypo`'s own `spec/locales/`, or
on the project's Locales page, which renders them from those files.** Re-syncing this directory
means copying the canonical files and dropping `sources` again.

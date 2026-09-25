# Vendored spec subset

This directory is a manually-synced copy of a subset of `polytypo/polytypo`'s canonical `spec/`:
`locales/`, `fixtures/`, the whole of `rules/`, `schema/`, `VERSION` and `UNICODE`. The gem and its
specs read only part of that — the locale and fixture data, `rules/order.json` and
`rules/dashes.md`; the other twelve rule documents are carried as the normative prose for the
behaviour the data drives, next to the data. It is **not** the canonical spec: `validate-spec.mjs`
lives only in `polytypo/polytypo`, and so does the authority — a change starts there and arrives
here by re-copying, never the other way round.

Named `lib/polytypo/data/`, not `vendor/polytypo-spec/` like the JS/Python ports: a Ruby
gemspec's `files` list can include any path directly, so there is no need for a separate
`vendor/` staging copy plus a second, separately-generated package-data copy the way Python
needed (its build backend does not include arbitrary files without explicit config). This is the
one copy, shipped as part of the gem's own `lib/` payload and loaded via `File.read` relative to
`__dir__` at runtime — never a network or external-filesystem read.

Editing a file here does not change the spec; it only drifts this copy from canonical. When
canonical's `spec/` changes, re-copy the affected files here.

CI checks that it was done. `script/check-vendored-spec.sh` compares every file in this directory
against canonical `polytypo/polytypo` at tag `spec-v` + this directory's own `VERSION`, and fails
on any difference. Five details. The files this repository authors itself are listed in
`.not-canonical` and skipped — and a listed path that canonical *does* have is an error, so that
list cannot be used to keep a forked copy of a canonical file. A `locales/*.json` file is compared
in full when it carries its `sources` array, and against canonical minus that array when it does
not, which is the shipped form three of the five runtimes vendor; the script reads which case it
is off the file rather than being told. A file here with no canonical counterpart is a failure, so
a canonical rename cannot pass unnoticed. Completeness is checked from canonical's side rather
than this one: every file canonical has at that tag must be here unless `.not-vendored` names it,
so a vendored file that was deleted, or a canonical file that arrived later and was never copied,
fails naming itself, and an entry canonical does not have at that tag, or one that is also present
here, fails too. Here that list names `CONFORMANCE.md`, and nothing else. And the version itself
is checked: a tree faithful to the tag it claims while canonical has tagged a newer one is a
warning in CI and, with `--require-current`, a refusal in the release job, because a package must
not be published claiming a spec version canonical has moved past.

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

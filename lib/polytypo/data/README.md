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
canonical's `spec/` changes, re-copy the affected files here. How this vendoring will work
long-term (submodule, per-ecosystem spec package, or something else) is an open decision tracked
in `polytypo/polytypo`'s roadmap; this is the interim, manually-synced form — the same status
every other port's vendored copy has.

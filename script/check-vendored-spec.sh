#!/bin/sh
# Fails when this repository's vendored spec subset differs from canonical polytypo at the spec
# version the subset itself claims.
#
# Nothing else checks the prose half of that tree. The data half stays current because the test
# suite fails without it; a stale rules/*.md is invisible, and four published packages once
# shipped rule documentation that contradicted their own engine (polytypo/polytypo#56).
#
# What is compared, for every regular file under the vendored directory:
#
#   locales/*.json  (except registry.json, which carries no citations and is compared byte for
#                   byte like anything else) in full, byte for byte, when the vendored files have a
#                   `sources` array — which
#                   is how the repositories that keep the citations vendor them. When they do not,
#                   they are the shipped form: three runtimes embed these exact files in the
#                   published package and drop `sources` when vendoring, so the comparison is
#                   against canonical with that one array removed. Which side this repository is on
#                   is read off the files rather than configured, and the whole directory must
#                   agree — a tree where some locale files kept their citations and others lost
#                   them fails, because that is a tree losing citations file by file.
#   everything else byte-identical to spec/<same path> in canonical.
#
# Paths listed in <dir>/.not-canonical are skipped — the files this repository authors itself. A
# listed path that DOES exist in canonical is an error, not an exemption: the list cannot be used
# to fork a canonical file. A vendored file with no canonical counterpart fails, so a renamed or
# deleted canonical file cannot pass unnoticed. Completeness is deliberately not checked: each
# runtime vendors only the subset it needs, and the subsets differ.
set -eu

usage='usage: check-vendored-spec.sh <vendored-spec-dir>'
vendor=${1:?$usage}
vendor=${vendor%/}
canonical_repo=${CANONICAL_REPO:-https://github.com/polytypo/polytypo.git}

[ -d "$vendor" ] || { echo "$vendor is not a directory" >&2; exit 1; }
[ -f "$vendor/VERSION" ] || {
  echo "$vendor/VERSION is missing — it names the canonical tag this tree is checked against" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }

version=$(tr -d ' \t\n\r' < "$vendor/VERSION")
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "$vendor/VERSION is not a semver triple: '$version'" >&2
  exit 1
}
tag="spec-v$version"

irregular=$(find "$vendor" \! -type d \! -type f -print)
[ -z "$irregular" ] || {
  echo "$vendor contains non-regular files, which a vendored snapshot must not:" >&2
  echo "$irregular" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

git clone --quiet --depth 1 --branch "$tag" "$canonical_repo" "$tmp/canonical" 2>"$tmp/clone.err" || {
  echo "cannot check out canonical at $tag — a released spec version must be tagged:" >&2
  cat "$tmp/clone.err" >&2
  exit 1
}

: > "$tmp/skip"
echo '.not-canonical' >> "$tmp/skip"
if [ -f "$vendor/.not-canonical" ]; then
  sed -e 's/#.*$//' -e 's/[[:space:]]*//g' "$vendor/.not-canonical" | grep -v '^$' >> "$tmp/skip" || true
fi

forked=''
while IFS= read -r skip; do
  [ "$skip" = '.not-canonical' ] && continue
  [ -e "$tmp/canonical/spec/$skip" ] && forked="$forked $skip"
done < "$tmp/skip"
[ -z "$forked" ] || {
  echo "$vendor/.not-canonical lists path(s) canonical does have:$forked" >&2
  echo "That list is for files this repository authors, not a way to keep a forked copy of a" >&2
  echo "canonical file. Remove the entry and re-copy the file, or rename this repository's own." >&2
  exit 1
}

find "$vendor" -type f -print | sed "s|^$vendor/||" | LC_ALL=C sort > "$tmp/vendored"

with_sources=0
without_sources=0
for locale in "$vendor"/locales/*.json; do
  [ -f "$locale" ] || continue
  # registry.json lists the locales and their aliases; it attests nothing and has no citations.
  [ "$(basename "$locale")" = 'registry.json' ] && continue
  if jq -e 'has("sources")' "$locale" >/dev/null 2>&1; then
    with_sources=$((with_sources + 1))
  else
    without_sources=$((without_sources + 1))
  fi
done
if [ "$with_sources" -ne 0 ] && [ "$without_sources" -ne 0 ]; then
  echo "$vendor/locales/ is inconsistent: $with_sources file(s) carry a \"sources\" array and" >&2
  echo "$without_sources do not. A vendored tree either keeps the citations or ships without them;" >&2
  echo "a mixture means some files lost theirs, which is drift this check would otherwise allow." >&2
  exit 1
fi

: > "$tmp/report"
checked=0
while IFS= read -r rel; do
  grep -Fxq "$rel" "$tmp/skip" && continue
  checked=$((checked + 1))
  canon="$tmp/canonical/spec/$rel"
  if [ ! -f "$canon" ]; then
    printf 'no counterpart in canonical  %s\n' "$rel" >> "$tmp/report"
    continue
  fi
  case $rel in
    locales/registry.json)
      cmp -s "$vendor/$rel" "$canon" ||
        printf 'differs from canonical       %s\n' "$rel" >> "$tmp/report"
      ;;
    locales/*.json)
      if jq -e 'has("sources")' "$vendor/$rel" >/dev/null 2>&1; then
        cmp -s "$vendor/$rel" "$canon" ||
          printf 'differs from canonical       %s\n' "$rel" >> "$tmp/report"
      else
        jq -S . "$vendor/$rel" > "$tmp/a" || { echo "$rel is not valid JSON" >&2; exit 1; }
        jq -S 'del(.sources)' "$canon" > "$tmp/b" || { echo "canonical $rel is not valid JSON" >&2; exit 1; }
        cmp -s "$tmp/a" "$tmp/b" ||
          printf 'differs from canonical       %s (shipped form, without "sources")\n' "$rel" >> "$tmp/report"
      fi
      ;;
    *)
      cmp -s "$vendor/$rel" "$canon" ||
        printf 'differs from canonical       %s\n' "$rel" >> "$tmp/report"
      ;;
  esac
done < "$tmp/vendored"

differing=$(wc -l < "$tmp/report" | tr -d ' ')
if [ "$differing" -ne 0 ]; then
  echo "$vendor does not match canonical $tag — $differing of $checked file(s):" >&2
  cat "$tmp/report" >&2
  echo >&2
  echo "Re-copy them from https://github.com/polytypo/polytypo/tree/$tag/spec. If canonical has" >&2
  echo "instead moved on without a version bump, fix that first: the vendored VERSION names the" >&2
  echo "tag this tree is checked against, and a released spec is not amended in place." >&2
  exit 1
fi

echo "$vendor matches canonical $tag ($checked files checked)."

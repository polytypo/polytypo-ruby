#!/bin/sh
# Fails when this repository's vendored spec subset differs from canonical polytypo at the spec
# version the subset itself claims.
#
# Nothing else checks the prose half of that tree. The data half stays current because the test
# suite fails without it; a stale rules/*.md is invisible, and four published packages once
# shipped rule documentation contradicting their own engine (polytypo/polytypo#56).
#
# What is compared, for every regular file under the vendored directory:
#
#   locales/*.json  parsed and compared with the `sources` array dropped from both sides. Three
#                   runtimes embed these exact files in the published package and drop the
#                   citations when vendoring, which is documented and deliberate; every other
#                   field must still match canonical.
#   everything else byte-identical to spec/<same path> in canonical.
#
# Paths listed in <dir>/.not-canonical are skipped — the files this repository authors itself.
# A vendored file with no canonical counterpart fails, so a renamed or deleted canonical file
# cannot pass unnoticed. Completeness is deliberately not checked: each runtime vendors only the
# subset it needs, and the subsets differ.
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

find "$vendor" -type f -print | sed "s|^$vendor/||" | LC_ALL=C sort > "$tmp/vendored"

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
    locales/*.json)
      jq -S 'del(.sources)' "$vendor/$rel" > "$tmp/a" || { echo "$rel is not valid JSON" >&2; exit 1; }
      jq -S 'del(.sources)' "$canon" > "$tmp/b" || { echo "canonical $rel is not valid JSON" >&2; exit 1; }
      cmp -s "$tmp/a" "$tmp/b" ||
        printf 'differs from canonical       %s (ignoring "sources")\n' "$rel" >> "$tmp/report"
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

#!/usr/bin/env bash
# Verify that every file under core/ is byte-identical to bitcoin/bitcoin at
# the pinned tag. This is the artifact that makes the vendoring reviewable:
# a Core developer runs it and confirms they only need to read shim/ and src/.
set -uo pipefail

TAG="${CORE_TAG:-v29.0}"
BASE="https://raw.githubusercontent.com/bitcoin/bitcoin/${TAG}/src"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok=0; bad=0; miss=0

echo "Verifying core/ against bitcoin/bitcoin ${TAG}"
echo

while IFS= read -r f; do
  rel="${f#"$ROOT"/core/}"
  if ! curl -sfL --max-time 30 "${BASE}/${rel}" -o "$TMP/f" 2>/dev/null; then
    printf '  MISSING UPSTREAM  %s\n' "$rel"; miss=$((miss+1)); continue
  fi
  if cmp -s "$f" "$TMP/f"; then
    ok=$((ok+1))
  else
    printf '  MODIFIED          %s\n' "$rel"; bad=$((bad+1))
  fi
done < <(find "$ROOT/core" -type f \( -name '*.h' -o -name '*.cpp' \) | sort)

echo
echo "  identical to upstream : $ok"
echo "  modified              : $bad"
echo "  not found upstream    : $miss"
echo
if [ "$bad" -ne 0 ] || [ "$miss" -ne 0 ]; then
  echo "FAIL: core/ diverges from ${TAG}."
  echo "Every divergence must be a file in patches/ applied by the build, not an"
  echo "edit in place, or the Core-dev review story breaks."
  exit 1
fi
echo "PASS: core/ is byte-identical to ${TAG}. Non-Core code is limited to:"
find "$ROOT/shim" "$ROOT/src" -type f | sed "s|$ROOT/|  |" | sort

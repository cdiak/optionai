#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-optionai}"
echo "Compiling $OUT …"
swiftc -O \
  -o "$OUT" \
  OptionAI.swift \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -framework WebKit
# Sign with a stable identity so the Accessibility (TCC) grant survives
# rebuilds. Ad-hoc signatures change every build and reset the grant.
CODESIGN_ID="${CODESIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
if [[ -n "$CODESIGN_ID" ]]; then
  codesign --force --identifier com.cdiak.optionai -s "$CODESIGN_ID" "$OUT"
  echo "Signed with: $CODESIGN_ID"
else
  echo "warning: no signing identity found — ad-hoc signature (Accessibility grant resets on every rebuild)" >&2
fi

if [[ "$OUT" = /* ]]; then
  echo "Built: $OUT"
else
  echo "Built: $(pwd)/$OUT"
fi
file "$OUT"

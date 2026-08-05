#!/usr/bin/env bash
set -euo pipefail

# Lightweight dependency-direction checks. These intentionally inspect only
# import declarations (not arbitrary text) so comments and documentation do
# not create false positives. The script is a guardrail, not a replacement for
# Swift's type checker.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

failures=0
check_forbidden_imports() {
  local label="$1"
  local path="$2"
  shift 2
  local forbidden=("$@")
  [[ -d "$ROOT/$path" ]] || return 0
  for module in "${forbidden[@]}"; do
    if rg -n --glob '*.swift' "^[[:space:]]*import[[:space:]]+$module([[:space:]]|$)" "$ROOT/$path" >/tmp/audiolink-architecture-check.out; then
      printf 'Architecture boundary violation (%s): import %s\n' "$label" "$module" >&2
      cat /tmp/audiolink-architecture-check.out >&2
      failures=$((failures + 1))
    fi
  done
}

check_forbidden_imports "Core" "Packages/AudioLinkCore/Sources" \
  SwiftUI AudioLinkDSP AudioLinkStorage AudioLinkNetworking AudioLinkRealtime AudioLinkReporting
check_forbidden_imports "DSP" "Packages/AudioLinkDSP/Sources" \
  SwiftUI AudioLinkStorage AudioLinkNetworking AudioLinkRealtime AudioLinkReporting
check_forbidden_imports "Networking" "Packages/AudioLinkNetworking/Sources" \
  SwiftUI AudioLinkMac AudioLinkMobile AudioLinkStorage AudioLinkReporting AudioLinkRealtime
check_forbidden_imports "Storage" "Packages/AudioLinkStorage/Sources" \
  SwiftUI AudioLinkReporting AudioLinkMac AudioLinkMobile
check_forbidden_imports "CLI" "Packages/AudioLinkAutomation/Sources/audiolink" \
  SwiftUI AudioLinkMac AudioLinkMobile

# Application targets may consume packages, but packages must never import an
# application target. This catches accidental back edges in shared code.
check_forbidden_imports "shared packages" "Packages" AudioLinkMac AudioLinkMobile

# The external report model is deliberately independent of database records;
# conversion belongs in the document builder only.
if rg -n --glob 'ReportModels.swift' "^[[:space:]]*import[[:space:]]+AudioLinkStorage([[:space:]]|$)" "$ROOT/Packages/AudioLinkReporting/Sources" >/tmp/audiolink-architecture-check.out; then
  printf 'Architecture boundary violation (report schema imports storage records)\n' >&2
  cat /tmp/audiolink-architecture-check.out >&2
  failures=$((failures + 1))
fi

rm -f /tmp/audiolink-architecture-check.out
if (( failures > 0 )); then
  exit 1
fi
printf 'Architecture boundary checks passed.\n'

#!/usr/bin/env bash
set -euo pipefail

first_identity_matching() {
  local pattern="$1"

  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/sed -n "s/.*\"\\([^\"]*${pattern}[^\"]*\\)\".*/\\1/p" \
    | /usr/bin/head -n 1
}

choose_local_signing_identity() {
  local requested="${SIGNING_IDENTITY:-${CODESIGN_IDENTITY:-}}"

  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local developer_id
  developer_id="$(first_identity_matching "Developer ID Application")"
  if [[ -n "$developer_id" ]]; then
    printf '%s\n' "$developer_id"
    return 0
  fi

  local apple_development
  apple_development="$(first_identity_matching "Apple Development")"
  if [[ -n "$apple_development" ]]; then
    printf '%s\n' "$apple_development"
    return 0
  fi

  printf '%s\n' "-"
}

choose_release_signing_identity() {
  local requested="${CODESIGN_IDENTITY:-${SIGNING_IDENTITY:-}}"

  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local developer_id
  developer_id="$(first_identity_matching "Developer ID Application")"
  if [[ -n "$developer_id" ]]; then
    printf '%s\n' "$developer_id"
    return 0
  fi

  echo "No Developer ID Application signing identity found. Set CODESIGN_IDENTITY explicitly or install a Developer ID Application certificate." >&2
  return 1
}

signable_children_for_bundle() {
  local bundle_path="$1"

  /usr/bin/find "$bundle_path/Contents" \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' -o -name '*.dylib' \) \
    -print 2>/dev/null \
    | /usr/bin/awk -F/ '{print NF "\t" $0}' \
    | /usr/bin/sort -rn \
    | /usr/bin/cut -f2-
}

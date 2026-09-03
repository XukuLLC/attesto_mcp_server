#!/usr/bin/env sh
# Check a source tree or unpacked package for accidental machine-local data.
# The rules are intentionally generic so this check is safe to run in public
# repositories without maintaining a project-specific denylist.
set -eu

if [ "$#" -gt 2 ]; then
  echo "usage: $0 [directory] [source|package]" >&2
  exit 64
fi

root=${1:-.}
mode=${2:-source}
case "$mode" in
  source|package) ;;
  *)
    echo "scan mode must be source or package" >&2
    exit 64
    ;;
esac

root=$(CDPATH='' cd -- "$root" && pwd)
script_path="$root/scripts/check_source_hygiene.sh"
failures=0

report_matches() {
  label=$1
  pattern=$2

  matches=$(
    find "$root" \
      \( -name .git -prune \) -o \
      \( -type d \( -name '_build*' -o -name cover -o -name deps -o -name doc \) -prune \) -o \
      \( -type f ! -path "$script_path" -exec grep -I -n -E -- "$pattern" {} + \) 2>/dev/null || :
  )

  if [ -n "$matches" ]; then
    echo "source hygiene violation: $label" >&2
    printf '%s\n' "$matches" >&2
    failures=1
  fi
}

report_paths() {
  paths=$(
    find "$root" \
      \( -name .git -prune \) -o \
      \( -type d \( -name '_build*' -o -name cover -o -name deps -o -name doc \) -prune \) -o \
      \( -type f \( \
        -name .DS_Store -o \
        -name '*.pem' -o \
        -name '*.key' -o \
        -name '*.p12' -o \
        -name '*.pfx' -o \
        -name '*.jks' -o \
        -name '.env' -o \
        -name '.env.local' -o \
        -name '.env.development' -o \
        -name '.env.production' \
      \) -print \) 2>/dev/null || :
  )

  if [ -n "$paths" ]; then
    echo "source hygiene violation: credential or generated artifact file" >&2
    printf '%s\n' "$paths" >&2
    failures=1
  fi

  if [ "$mode" = package ]; then
    paths=$(
      find "$root" \
        \( -name .git -print -prune \) -o \
        \( -type d \( -name '_build*' -o -name cover -o -name deps -o -name doc \) -print \) -o \
        \( -type f -name mix.lock -print \) 2>/dev/null || :
    )

    if [ -n "$paths" ]; then
      echo "package hygiene violation: repository or generated artifact in package archive" >&2
      printf '%s\n' "$paths" >&2
      failures=1
    fi
  fi
}

# Absolute home and temporary paths disclose the author's workstation and are
# not portable package content. Loopback URLs and ordinary example paths are
# deliberately allowed because they are useful in public documentation/tests.
report_matches "absolute local path" '(^|[^[:alnum:]_])/(Users|home|private/var|var/folders)/[[:alnum:]_.-]+'
report_matches "Windows user path" '(^|[^[:alnum:]_])[A-Za-z]:[\\/](Users|Documents)([\\/])'

# High-confidence private key and cloud credential markers. Generic words such
# as "secret" or "token" are not rejected because public libraries commonly
# document those APIs and use harmless test values.
report_matches "private key material" '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----'
report_matches "cloud access key" '(^|[^[:alnum:]])(AKIA|ASIA)[0-9A-Z]{16}([^[:alnum:]]|$)'
report_matches "OAuth or API credential" '(^|[^[:alnum:]])(gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9]{20,})([^[:alnum:]]|$)'

report_paths

if [ "$failures" -ne 0 ]; then
  exit 1
fi

echo "source hygiene scan passed ($mode): $root"

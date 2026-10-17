#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

source_commit=$(
  sed -n '/^- release commit:/{
    s/^- release commit: `//
    s/`[[:space:]]*$//
    p
    q
  }' CONFORMANCE.md
)

case "$source_commit" in
  ''|*[!0-9a-f]*)
    echo "CONFORMANCE.md does not contain a lowercase release commit" >&2
    exit 1
    ;;
  *) ;;
esac

if [ "${#source_commit}" -ne 40 ] || ! git cat-file -e "$source_commit^{commit}" 2>/dev/null; then
  echo "CONFORMANCE.md release commit is not an available 40-character commit" >&2
  exit 1
fi

for required in \
  fixtures/installer_phoenix_postgres_host/mix.exs \
  fixtures/installer_phoenix_postgres_host/config/config.exs \
  fixtures/installer_phoenix_postgres_host/lib/installer_host/application.ex \
  fixtures/installer_phoenix_postgres_host/lib/installer_host/repo.ex \
  test/session_store_observability_test.exs
do
  if ! git cat-file -e "$source_commit:$required" 2>/dev/null; then
    echo "conformance evidence input is not tracked: $required" >&2
    exit 1
  fi
done

expected=$(
  sed -n '/^- source fingerprint:/{
    n
    s/^[[:space:]]*`//
    s/`[[:space:]]*$//
    p
    q
  }' CONFORMANCE.md
)

case "$expected" in
  ''|*[!0-9a-f]*)
    echo "CONFORMANCE.md does not contain a lowercase SHA-256 source fingerprint" >&2
    exit 1
    ;;
  *) ;;
esac

if [ "${#expected}" -ne 64 ]; then
  echo "CONFORMANCE.md source fingerprint is not 64 hexadecimal characters" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  actual=$(
    git ls-tree -r --name-only "$source_commit" -- mix.exs config lib examples scripts test fixtures |
      while IFS= read -r path; do
        blob_hash=$(git cat-file blob "$source_commit:$path" | shasum -a 256 | awk '{print $1}')
        printf '%s  %s\n' "$blob_hash" "$path"
      done |
      shasum -a 256 |
      awk '{print $1}'
  )
else
  actual=$(
    git ls-tree -r --name-only "$source_commit" -- mix.exs config lib examples scripts test fixtures |
      while IFS= read -r path; do
        blob_hash=$(git cat-file blob "$source_commit:$path" | sha256sum | awk '{print $1}')
        printf '%s  %s\n' "$blob_hash" "$path"
      done |
      sha256sum |
      awk '{print $1}'
  )
fi

if [ "$actual" != "$expected" ]; then
  echo "CONFORMANCE.md source fingerprint does not match its frozen release commit" >&2
  echo "expected: $expected" >&2
  echo "actual:   $actual" >&2
  exit 1
fi

printf 'conformance evidence fingerprint verified: %s\n' "$actual"

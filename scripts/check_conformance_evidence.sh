#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
cd "$repo_root"

for required in \
  fixtures/installer_phoenix_postgres_host/mix.exs \
  fixtures/installer_phoenix_postgres_host/config/config.exs \
  fixtures/installer_phoenix_postgres_host/lib/installer_host/application.ex \
  fixtures/installer_phoenix_postgres_host/lib/installer_host/repo.ex \
  test/session_store_observability_test.exs
do
  if ! git ls-files --error-unmatch "$required" >/dev/null 2>&1; then
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
    git ls-files -z mix.exs config lib examples scripts test fixtures |
      xargs -0 shasum -a 256 |
      shasum -a 256 |
      awk '{print $1}'
  )
else
  actual=$(
    git ls-files -z mix.exs config lib examples scripts test fixtures |
      xargs -0 sha256sum |
      sha256sum |
      awk '{print $1}'
  )
fi

if [ "$actual" != "$expected" ]; then
  echo "CONFORMANCE.md source fingerprint is stale" >&2
  echo "expected: $expected" >&2
  echo "actual:   $actual" >&2
  exit 1
fi

printf 'conformance evidence fingerprint verified: %s\n' "$actual"

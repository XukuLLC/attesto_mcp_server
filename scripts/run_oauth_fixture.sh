#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir/fixtures/oauth_host"

# Isolated host project: Phoenix/client are conformance-only dependencies.
# Family source paths default to sibling checkouts and can be pinned by CI.
MIX_ENV=test
export MIX_ENV
mix deps.get
exec mix test "$@"

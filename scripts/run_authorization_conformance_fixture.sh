#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  printf '%s\n' 'usage: run_authorization_conformance_fixture.sh RUNNER_DIST_INDEX_JS OUTPUT_DIR' >&2
  exit 64
fi

# Resolve caller-relative paths before entering the isolated fixture project.
runner_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
runner="$runner_dir/$(basename -- "$1")"
mkdir -p -- "$2"
output_dir=$(CDPATH= cd -- "$2" && pwd)
if [ -n "$(ls -A "$output_dir")" ]; then
  printf '%s\n' 'output directory must be empty so previous checks cannot satisfy this run' >&2
  exit 64
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir/fixtures/oauth_host"
MIX_ENV=test
export MIX_ENV
mix deps.get
exec mix run run_authorization_conformance.exs -- "$runner" "$output_dir"

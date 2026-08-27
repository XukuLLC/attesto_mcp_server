#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 ERA COMMAND [ARG ...]" >&2
  exit 64
fi

era=$1
shift
case "$era" in
  2025-11-25|2026-07-28) ;;
  *) echo "unsupported era: $era" >&2; exit 64 ;;
esac

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
fixture_build_path=${MCP_FIXTURE_BUILD_PATH:-${MIX_BUILD_PATH:-_build}/fixture}
MIX_ENV=test
MIX_BUILD_PATH=$fixture_build_path
export MIX_ENV MIX_BUILD_PATH
exec mix run examples/conformance_server.exs -- \
  --fixture-command "$era" "$@"

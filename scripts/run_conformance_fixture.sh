#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 CONFORMANCE_REPO REQUIREMENTS [SCENARIO]" >&2
  exit 64
fi

runner_dir=$1
requirements=$2
scenario=${3:-}
case "$requirements" in
  2025-11-25|2026-07-28) ;;
  *) echo "unsupported requirements: $requirements" >&2; exit 64 ;;
esac

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
fixture_build_path=${MCP_FIXTURE_BUILD_PATH:-${MIX_BUILD_PATH:-_build}/fixture}
MIX_ENV=test
MIX_BUILD_PATH=$fixture_build_path
export MIX_ENV MIX_BUILD_PATH

if [ -n "$scenario" ]; then
  exec mix run examples/conformance_server.exs -- \
    --fixture-command "$requirements" node "$runner_dir/dist/index.js" server \
    --url __MCP_SERVER_URL__ --scenario "$scenario" \
    --spec-version "$requirements" --force
else
  exec mix run examples/conformance_server.exs -- \
    --fixture-command "$requirements" node "$runner_dir/dist/index.js" server \
    --url __MCP_SERVER_URL__ --requirements "$requirements"
fi

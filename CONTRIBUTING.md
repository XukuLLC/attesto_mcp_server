# Contributing

Thank you for contributing to `attesto_mcp_server`. Open an issue before a large
change so the intended behavior and compatibility constraints can be agreed
first.

Before opening a pull request, run `mix test.all` and
`scripts/check_source_hygiene.sh .`. Security-sensitive changes should include
regression tests for refusal paths as well as the successful path. Package
changes should also verify the unpacked archive with
`scripts/check_source_hygiene.sh path/to/archive package`.

Do not commit credentials, generated dependency state, workstation paths, or
other private project data. Release notes must distinguish candidate work from
recorded conformance and dependency evidence; do not add results that were not
actually run.

## Contributor credit

Accepted external contributions are credited by GitHub handle and pull request
in the release changelog entry that first includes them. The merge also
preserves Git commit authorship or an appropriate `Co-authored-by` trailer.

Credit is added when the contribution lands, not while it is still under
review. Security reporters may request anonymous or alternate attribution.

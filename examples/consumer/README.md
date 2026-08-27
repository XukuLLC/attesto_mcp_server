# External consumer check

This small Mix project compiles against the package through a path dependency,
registers every public primitive category, initializes Plug with an explicit
authorization-server metadata pointer (protected requests still require a
real Attesto verifier), and invokes the stdio adapter. Run it from this
directory with:

```text
mix deps.get
mix compile --warnings-as-errors
mix run -e ' {:ok, server} = AttestoMCP.ExternalConsumer.build_server(); _plug = AttestoMCP.ExternalConsumer.plug(server); AttestoMCP.ExternalConsumer.stdio(server)'
```

[
  inputs: [
    "{mix,.formatter}.exs",
    "config/*.exs",
    "lib/**/*.{ex,exs}",
    "test/**/*.exs",
    "fixtures/**/*.{ex,exs}",
    "examples/*.{exs,livemd}",
    "examples/consumer/mix.exs",
    "examples/consumer/{lib,test}/**/*.{ex,exs}"
  ],
  locals_without_parens: [plug: 2, plug: 3]
]

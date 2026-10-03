defmodule AttestoMCP.Server.Schema.Draft7Applicator do
  @moduledoc false
  use JSV.Vocabulary, priority: 200
  alias JSV.Vocabulary.V7.Applicator

  @impl true
  defdelegate init_validators(opts), to: Applicator

  @impl true
  def handle_keyword({keyword, _}, _acc, _builder, _schema)
      when keyword in ["prefixItems", "dependentSchemas", "minContains", "maxContains"],
      do: :ignore

  def handle_keyword(pair, acc, builder, schema),
    do: Applicator.handle_keyword(pair, acc, builder, schema)

  @impl true
  defdelegate finalize_validators(acc), to: Applicator
  @impl true
  defdelegate validate(data, validators, context), to: Applicator
  @impl true
  defdelegate format_error(kind, args, data), to: Applicator
end

defmodule AttestoMCP.Server.Schema.Draft7Validation do
  @moduledoc false
  use JSV.Vocabulary, priority: 300
  alias JSV.Vocabulary.V7.Validation

  @impl true
  defdelegate init_validators(opts), to: Validation

  @impl true
  def handle_keyword({"dependentRequired", _}, _acc, _builder, _schema), do: :ignore

  def handle_keyword(pair, acc, builder, schema),
    do: Validation.handle_keyword(pair, acc, builder, schema)

  @impl true
  defdelegate finalize_validators(acc), to: Validation
  @impl true
  defdelegate validate(data, validators, context), to: Validation
  @impl true
  defdelegate format_error(kind, args, data), to: JSV.Vocabulary.V202012.Validation
end

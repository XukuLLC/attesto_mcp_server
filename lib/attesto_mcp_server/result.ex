defmodule AttestoMCP.Server.Result do
  @moduledoc """
  Explicit client-visible business failures returned by MCP handlers.

  Arbitrary handler errors and exceptions remain private. Use `error/2` only
  for bounded text and a machine-readable code that are safe to disclose to
  the calling client.
  """

  @max_message_bytes 4_096
  @max_code_bytes 128

  defmodule ClientError do
    @moduledoc """
    A bounded business error explicitly approved for disclosure to an MCP client.

    Construct values with `AttestoMCP.Server.Result.error/2` so the public
    message and optional machine-readable code are validated.
    """
    @enforce_keys [:message]
    defstruct [:message, :code]

    @type t :: %__MODULE__{message: String.t(), code: String.t() | nil}
  end

  @doc "Builds one explicitly client-visible business error."
  @spec error(String.t(), String.t() | nil) :: ClientError.t()
  def error(message, code \\ nil) do
    unless valid_message?(message) do
      raise ArgumentError, "client error message must be valid UTF-8 between 1 and 4096 bytes"
    end

    unless valid_code?(code) do
      raise ArgumentError, "client error code must be nil or valid UTF-8 between 1 and 128 bytes"
    end

    %ClientError{message: message, code: code}
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message),
    do: byte_size(message) in 1..@max_message_bytes and String.valid?(message)

  def valid_message?(_message), do: false

  @doc false
  @spec valid_code?(term()) :: boolean()
  def valid_code?(nil), do: true

  def valid_code?(code) when is_binary(code),
    do: byte_size(code) in 1..@max_code_bytes and String.valid?(code)

  def valid_code?(_code), do: false
end

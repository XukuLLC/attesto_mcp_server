defmodule AttestoMCP.Server.UnloadedMFAHandler do
  @key :unloaded_mfa_argument

  def handle(arguments, _context), do: {:ok, %{"atom_key?" => Map.has_key?(arguments, @key)}}
end

defmodule AttestoMCP.Server.UnloadedCaptureHandler do
  @key :unloaded_capture_argument

  def handle(arguments, _context),
    do: {:ok, %{"atom_key?" => Map.has_key?(arguments, @key)}}
end

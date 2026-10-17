defmodule AttestoMCP.Server.TestSupport.HTTPClient do
  @moduledoc false

  def connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  def send_request(socket, method, path, headers, body) do
    headers = headers ++ [{"content-length", Integer.to_string(byte_size(body))}]

    :gen_tcp.send(
      socket,
      IO.iodata_to_binary([
        method,
        " ",
        path,
        " HTTP/1.1\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "\r\n",
        body
      ])
    )
  end

  def request(socket, method, path, headers, body) do
    :ok = send_request(socket, method, path, headers, body)
    {head, rest} = recv_headers(socket)
    [status_line | header_lines] = String.split(head, "\r\n", trim: true)
    [_, status] = Regex.run(~r/^HTTP\/\d\.\d (\d+)/, status_line)
    headers = parse_headers(header_lines)
    {body, _rest} = recv_body(socket, headers, rest)
    {String.to_integer(status), headers, body}
  end

  def recv_headers(socket, buffer \\ <<>>, timeout_ms \\ 1_000) do
    case :binary.match(buffer, "\r\n\r\n") do
      {offset, 4} ->
        head = binary_part(buffer, 0, offset)
        rest = binary_part(buffer, offset + 4, byte_size(buffer) - offset - 4)
        {head, rest}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, timeout_ms)
        recv_headers(socket, buffer <> chunk, timeout_ms)
    end
  end

  def parse_headers(lines) do
    Enum.group_by(
      lines,
      fn line -> line |> String.split(":", parts: 2) |> hd() |> String.downcase() end,
      fn line -> line |> String.split(":", parts: 2) |> List.last() |> String.trim() end
    )
  end

  def recv_body(socket, headers, rest, timeout_ms \\ 1_000) do
    case headers["content-length"] do
      [length] -> recv_exact(socket, rest, String.to_integer(length), timeout_ms)
      _ -> {rest, <<>>}
    end
  end

  def recv_until(socket, marker, buffer \\ "", timeout_ms \\ 1_000) do
    if String.contains?(buffer, marker) do
      {buffer, buffer}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, timeout_ms)
      recv_until(socket, marker, buffer <> chunk, timeout_ms)
    end
  end

  defp recv_exact(_socket, buffer, needed, _timeout_ms) when byte_size(buffer) >= needed do
    {binary_part(buffer, 0, needed), binary_part(buffer, needed, byte_size(buffer) - needed)}
  end

  defp recv_exact(socket, buffer, needed, timeout_ms) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, timeout_ms)
    recv_exact(socket, buffer <> chunk, needed, timeout_ms)
  end
end

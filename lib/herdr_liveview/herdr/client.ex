defmodule HerdrLiveView.Herdr.Client do
  @moduledoc """
  One-shot requests against a herdr server socket (newline-delimited JSON).

  The server answers a single request per connection and then closes it.
  """

  @connect_timeout 2_000
  @default_timeout 10_000

  def socket_path, do: Application.fetch_env!(:herdr_liveview, :herdr_socket_path)

  def request(method, params \\ %{}, opts \\ []) do
    path = Keyword.get(opts, :socket_path) || socket_path()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, sock} <- connect(path) do
      try do
        payload = Jason.encode!(%{id: request_id(), method: method, params: params})

        with :ok <- :gen_tcp.send(sock, [payload, ?\n]),
             {:ok, line} <- recv_line(sock, "", deadline(timeout)) do
          decode_response(line)
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  def connect(path, extra_opts \\ []) do
    :gen_tcp.connect(
      {:local, String.to_charlist(path)},
      0,
      [:binary, active: false, packet: :raw] ++ extra_opts,
      @connect_timeout
    )
  end

  def request_id, do: Integer.to_string(System.unique_integer([:positive]))

  def decode_response(line) do
    case Jason.decode(line) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, {:herdr, error}}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp recv_line(sock, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(sock, 0, remaining) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case :binary.split(acc, "\n") do
          [line, _rest] -> {:ok, line}
          [_partial] -> recv_line(sock, acc, deadline)
        end

      {:error, :closed} when acc != "" ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

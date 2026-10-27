defmodule HerdrLiveView.Herdr.ClientTest do
  use ExUnit.Case, async: true

  alias HerdrLiveView.Herdr.Client

  setup do
    path = Path.join(System.tmp_dir!(), "herdr-client-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp serve_once(path, reply_fun) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :line])

    test_pid = self()

    Task.start_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen)
      {:ok, line} = :gen_tcp.recv(sock, 0, 1_000)
      request = Jason.decode!(line)
      send(test_pid, {:request, request})
      :ok = :gen_tcp.send(sock, reply_fun.(request))
      :gen_tcp.close(sock)
    end)
  end

  test "sends one JSON line and returns the result", %{path: path} do
    serve_once(path, fn %{"id" => id} ->
      Jason.encode!(%{id: id, result: %{type: "pong"}}) <> "\n"
    end)

    assert {:ok, %{"type" => "pong"}} = Client.request("ping", %{}, socket_path: path)
    assert_receive {:request, %{"method" => "ping", "params" => %{}, "id" => _}}
  end

  test "maps herdr errors", %{path: path} do
    serve_once(path, fn %{"id" => id} ->
      Jason.encode!(%{id: id, error: %{code: "agent_blocked", message: "blocked"}}) <> "\n"
    end)

    assert {:error, {:herdr, %{"code" => "agent_blocked"}}} =
             Client.request("agent.prompt", %{target: "w1:p1", text: "hi"}, socket_path: path)
  end

  test "reassembles responses split across packets", %{path: path} do
    serve_once(path, fn %{"id" => id} ->
      json = Jason.encode!(%{id: id, result: %{text: String.duplicate("x", 200_000)}})
      [json, "\n"]
    end)

    assert {:ok, %{"text" => text}} = Client.request("pane.read", %{}, socket_path: path)
    assert byte_size(text) == 200_000
  end

  test "returns an error when the socket does not exist", %{path: path} do
    assert {:error, _} = Client.request("ping", %{}, socket_path: path)
  end
end

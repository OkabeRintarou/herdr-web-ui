defmodule HerdrLiveView.Hosts do
  @moduledoc "Hosts and their live herdr connections (one `Herdr.Panes` per host)."
  import Ecto.Query

  alias HerdrLiveView.Herdr.{Client, Panes}
  alias HerdrLiveView.Hosts.{Host, Shell, Tunnel}
  alias HerdrLiveView.Repo

  def list_hosts, do: Repo.all(from(h in Host, order_by: [desc: h.managed, asc: h.name]))

  def get_host(id), do: Repo.get(Host, id)
  def get_host!(id), do: Repo.get!(Host, id)

  def create_host(attrs) do
    %Host{}
    |> Host.changeset(Map.put_new(stringify(attrs), "id", new_id()))
    |> Repo.insert()
  end

  @doc "The local host whose socket follows configuration (HERDR_SOCKET_PATH)."
  def ensure_managed_local!(socket_path) do
    case Repo.one(from(h in Host, where: h.managed, limit: 1)) do
      nil ->
        {:ok, host} =
          create_host(%{
            "name" => "本机",
            "kind" => "local",
            "socket_path" => socket_path,
            "managed" => true
          })

        host

      %Host{socket_path: ^socket_path} = host ->
        host

      host ->
        host |> Host.changeset(%{socket_path: socket_path}) |> Repo.update!()
    end
  end

  def connect_all, do: Enum.each(list_hosts(), &connect/1)

  def connect(%Host{} = host) do
    if Application.get_env(:herdr_liveview, :start_herdr, true) do
      if host.kind == "ssh", do: start_connection({Tunnel, host})
      start_connection({Panes, host})
    else
      :ignore
    end
  end

  defp start_connection(child) do
    case DynamicSupervisor.start_child(HerdrLiveView.Herdr.Connections, child) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def change_host(host \\ %Host{}, attrs \\ %{}), do: Host.changeset(host, attrs)

  @doc """
  Checks each link a host depends on, in order: `[{label, :ok | {:error, why}}]`.
  Stops at the first failure since later checks depend on it.
  """
  def check(%Host{} = host) do
    steps =
      case host.kind do
        "ssh" ->
          [
            {"ssh 连接 #{host.ssh_target}", fn -> shell_ok(host, "true") end},
            {"远端 herdr socket #{host.remote_socket}", fn -> remote_socket_ok(host) end},
            {"git 可用", fn -> shell_ok(host, "git --version") end},
            {"经隧道访问 herdr", fn -> herdr_ok(host) end}
          ]

        _ ->
          [
            {"herdr socket #{host.socket_path}",
             fn -> if File.exists?(host.socket_path), do: :ok, else: {:error, "文件不存在"} end},
            {"herdr 响应", fn -> herdr_ok(host) end}
          ]
      end

    Enum.reduce_while(steps, [], fn {label, run}, acc ->
      result = run.()
      next = if result == :ok, do: :cont, else: :halt
      {next, acc ++ [{label, result}]}
    end)
  end

  defp shell_ok(host, script) do
    case Shell.sh(host, script) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp remote_socket_ok(host) do
    with {:ok, path} <- Tunnel.remote_socket(host) do
      case Shell.sh(host, ~S(test -S "$1"), [path]) do
        {_, 0} -> :ok
        _ -> {:error, "#{path} 不存在，远端 herdr 是否在运行？"}
      end
    end
  end

  defp herdr_ok(host) do
    case Client.request("pane.list", %{}, socket_path: host.socket_path, timeout: 3_000) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        tunnel = if host.kind == "ssh", do: Tunnel.last_error(host.id)
        {:error, Enum.join(Enum.reject([inspect(reason), tunnel], &is_nil/1), "；")}
    end
  end

  defp new_id,
    do: "h-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end

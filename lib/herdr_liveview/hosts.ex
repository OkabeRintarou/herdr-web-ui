defmodule HerdrLiveView.Hosts do
  @moduledoc "Hosts and their live herdr connections (one `Herdr.Panes` per host)."
  import Ecto.Query

  alias HerdrLiveView.Herdr.Panes
  alias HerdrLiveView.Hosts.Host
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
      case DynamicSupervisor.start_child(HerdrLiveView.Herdr.Connections, {Panes, host}) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    else
      :ignore
    end
  end

  defp new_id,
    do: "h-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end

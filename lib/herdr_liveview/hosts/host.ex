defmodule HerdrLiveView.Hosts.Host do
  @moduledoc """
  A machine running a herdr session that agents are started on. A `local` host is reached
  through its socket; an `ssh` host through `ssh_target` (anything `ssh` accepts, e.g. an
  alias from ~/.ssh/config): its herdr socket is forwarded to `socket_path` here, and files
  and git run over ssh.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "hosts" do
    field(:name, :string)
    field(:kind, :string, default: "local")
    field(:socket_path, :string)
    field(:ssh_target, :string)
    field(:remote_socket, :string)
    field(:managed, :boolean, default: false)
    field(:max_agents, :integer, default: 12)

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [
      :id,
      :name,
      :kind,
      :socket_path,
      :ssh_target,
      :remote_socket,
      :managed,
      :max_agents
    ])
    |> validate_required([:id, :name, :kind])
    |> validate_inclusion(:kind, ["local", "ssh"])
    |> validate_number(:max_agents, greater_than: 0)
    |> validate_required_for_kind()
  end

  defp validate_required_for_kind(changeset) do
    case get_field(changeset, :kind) do
      "local" ->
        validate_required(changeset, [:socket_path])

      "ssh" ->
        changeset
        |> validate_required([:ssh_target, :remote_socket])
        # options smuggled in as a target would run as ssh flags
        |> validate_format(:ssh_target, ~r/^[A-Za-z0-9_][A-Za-z0-9_.@\[\]:-]*$/,
          message: "只能是 user@host 或 ssh 配置里的别名"
        )
        |> validate_format(:remote_socket, ~r{^(/|~/)[^\s:]*$},
          message: "需要绝对路径或以 ~/ 开头，且不含空白和冒号"
        )
        |> put_change(:socket_path, tunnel_path(get_field(changeset, :id)))

      _ ->
        changeset
    end
  end

  @doc "Where an ssh host's herdr socket is forwarded to (kept short: unix socket paths are limited)."
  def tunnel_path(id), do: Path.join(System.tmp_dir!(), "hlv-#{id}.sock")
end

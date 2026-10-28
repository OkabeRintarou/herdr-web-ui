defmodule HerdrLiveView.Hosts.Host do
  @moduledoc "A machine running a herdr session that agents are started on."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "hosts" do
    field(:name, :string)
    field(:kind, :string, default: "local")
    field(:socket_path, :string)
    field(:managed, :boolean, default: false)
    field(:max_agents, :integer, default: 12)

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:id, :name, :kind, :socket_path, :managed, :max_agents])
    |> validate_required([:id, :name, :kind])
    |> validate_inclusion(:kind, ["local"])
    |> validate_number(:max_agents, greater_than: 0)
    |> validate_required_for_kind()
  end

  defp validate_required_for_kind(changeset) do
    case get_field(changeset, :kind) do
      "local" -> validate_required(changeset, [:socket_path])
      _ -> changeset
    end
  end
end

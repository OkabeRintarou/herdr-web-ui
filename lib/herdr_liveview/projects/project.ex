defmodule HerdrLiveView.Projects.Project do
  @moduledoc "A folder on a host; every project has its own task board."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "projects" do
    field(:slug, :string)
    field(:name, :string)
    field(:path, :string)
    field(:default_branch, :string, default: "main")
    belongs_to(:host, HerdrLiveView.Hosts.Host, type: :string)

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:id, :slug, :name, :host_id, :path, :default_branch])
    |> update_change(:path, &expand/1)
    |> validate_required([:id, :slug, :name, :host_id, :path, :default_branch])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{0,39}$/, message: "只能用小写字母、数字和 -，最长 40 个字符")
    |> validate_change(:path, fn :path, path ->
      if String.starts_with?(path, "/"), do: [], else: [path: "必须是绝对路径"]
    end)
    |> unique_constraint(:slug, message: "已被其他项目使用")
    |> foreign_key_constraint(:host_id)
  end

  defp expand(""), do: ""
  defp expand(path), do: Path.expand(String.trim(path))
end

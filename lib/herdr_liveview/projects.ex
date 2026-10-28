defmodule HerdrLiveView.Projects do
  @moduledoc "Projects: a folder on a host with its own task board."
  import Ecto.Query

  alias HerdrLiveView.Projects.Project
  alias HerdrLiveView.Repo

  def list_projects, do: Repo.all(from(p in Project, order_by: p.name, preload: :host))

  def get_project(id), do: Project |> Repo.get(id) |> Repo.preload(:host)
  def get_project!(id), do: Project |> Repo.get!(id) |> Repo.preload(:host)

  def get_by_slug(slug), do: Project |> Repo.get_by(slug: slug) |> Repo.preload(:host)

  def change_project(project \\ %Project{}, attrs \\ %{}), do: Project.changeset(project, attrs)

  def create_project(attrs) do
    attrs = Map.put_new(stringify(attrs), "id", new_id())

    %Project{}
    |> Project.changeset(attrs)
    |> validate_local_path()
    |> Repo.insert()
    |> case do
      {:ok, project} -> {:ok, Repo.preload(project, :host)}
      error -> error
    end
  end

  @doc "Validation that needs the host: local paths must exist on this machine."
  def validate_local_path(changeset) do
    host_id = Ecto.Changeset.get_field(changeset, :host_id)
    path = Ecto.Changeset.get_field(changeset, :path)

    case host_id && HerdrLiveView.Hosts.get_host(host_id) do
      %{kind: "local"} when is_binary(path) ->
        if File.dir?(path),
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :path, "目录不存在")

      _ ->
        changeset
    end
  end

  @doc "Makes sure at least one project exists so pre-project tasks have a home."
  def ensure_default!(host) do
    case Repo.one(from(p in Project, order_by: p.inserted_at, limit: 1)) do
      nil ->
        {:ok, project} =
          create_project(%{
            "slug" => "default",
            "name" => "默认项目",
            "host_id" => host.id,
            "path" => System.user_home!()
          })

        project

      project ->
        Repo.preload(project, :host)
    end
  end

  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
  end

  defp new_id,
    do: "p-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end

defmodule HerdrLiveView.Repo.Migrations.CreateHostsAndProjects do
  use Ecto.Migration

  def change do
    create table(:hosts, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false, default: "local"
      add :socket_path, :string
      # follows the configured HERDR_SOCKET_PATH on every boot
      add :managed, :boolean, null: false, default: false
      add :max_agents, :integer, null: false, default: 12
      timestamps(type: :utc_datetime_usec)
    end

    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :host_id, references(:hosts, type: :string, on_delete: :restrict), null: false
      add :path, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:slug])

    alter table(:tasks) do
      add :project_id, references(:projects, type: :string, on_delete: :delete_all)
    end

    rename table(:tasks), :repo, to: :workdir
    create index(:tasks, [:project_id])
  end
end

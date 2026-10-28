defmodule HerdrLiveView.Repo.Migrations.AddSshHosts do
  use Ecto.Migration

  def change do
    alter table(:hosts) do
      add :ssh_target, :string
      add :remote_socket, :string
    end
  end
end

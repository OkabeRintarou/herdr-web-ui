defmodule HerdrLiveView.Fixtures do
  @moduledoc "Hosts and projects for tests."
  alias HerdrLiveView.{Hosts, Projects}

  def host_fixture(attrs \\ %{}) do
    {:ok, host} =
      attrs
      |> Enum.into(%{
        "name" => "test-host",
        "kind" => "local",
        "socket_path" => Path.join(System.tmp_dir!(), "herdr-liveview-test-missing.sock")
      })
      |> Hosts.create_host()

    host
  end

  def project_fixture(attrs \\ %{}) do
    host = attrs[:host] || host_fixture()
    n = System.unique_integer([:positive])

    {:ok, project} =
      Projects.create_project(%{
        "name" => attrs[:name] || "项目 #{n}",
        "slug" => attrs[:slug] || "proj-#{n}",
        "host_id" => host.id,
        "path" => attrs[:path] || System.tmp_dir!()
      })

    project
  end
end

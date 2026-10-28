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

  @doc "A scratch folder outside this repo (ExUnit's tmp_dir is inside it, so it counts as git)."
  def scratch_dir! do
    dir = Path.join(System.tmp_dir!(), "hlv-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
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

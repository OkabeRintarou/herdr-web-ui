defmodule HerdrLiveView.SshHostTest do
  # Remote hosts with a stand-in `ssh` (test/support/fake_ssh) that runs commands locally.
  use HerdrLiveView.DataCase, async: false

  import HerdrLiveView.Fixtures

  alias HerdrLiveView.Hosts
  alias HerdrLiveView.Hosts.{Host, Shell, Tunnel}
  alias HerdrLiveView.Worktrees

  setup do
    previous = Application.get_env(:herdr_liveview, :ssh_command)

    Application.put_env(
      :herdr_liveview,
      :ssh_command,
      Path.expand("../support/fake_ssh", __DIR__)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:herdr_liveview, :ssh_command, previous),
        else: Application.delete_env(:herdr_liveview, :ssh_command)
    end)

    dir = scratch_dir!()

    {:ok, host} =
      Hosts.create_host(%{
        "name" => "box",
        "kind" => "ssh",
        "ssh_target" => "me@box",
        "remote_socket" => Path.join(dir, "herdr.sock")
      })

    %{host: host, dir: dir}
  end

  test "ssh hosts need a plain target and a usable socket path", %{host: host} do
    changeset =
      Hosts.change_host(%Host{}, %{
        "id" => "h-x",
        "name" => "x",
        "kind" => "ssh",
        "ssh_target" => "-oProxyCommand=evil",
        "remote_socket" => "relative.sock"
      })

    assert %{ssh_target: [_], remote_socket: [_]} = errors_on(changeset)
    assert host.socket_path == Host.tunnel_path(host.id)
  end

  test "files and commands go through ssh, with arguments quoted", %{host: host, dir: dir} do
    path = Path.join(dir, "it's here.txt")

    Shell.append!(host, path, "a \"b\" $HOME\n")
    assert {:ok, "a \"b\" $HOME\n"} = Shell.read(host, path)
    assert {:error, :enoent} = Shell.read(host, Path.join(dir, "missing"))

    Shell.mkdir_p!(host, Path.join([dir, "x y", "z"]))
    assert Shell.dir?(host, Path.join([dir, "x y", "z"]))
    refute Shell.dir?(host, Path.join(dir, "nope"))
  end

  test "a remote project's worktree is made on the host", %{host: host, dir: dir} do
    init_repo!(dir)
    project = %{path: dir, default_branch: "main", host: host}

    assert {:ok, task} =
             Worktrees.ensure(project, %{id: "t-r", workdir: dir, worktree: nil, branch: nil})

    assert task.workdir == Path.join([dir, ".herdr-worktrees", "t-r"])
    assert File.read!(Path.join([dir, ".git", "info", "exclude"])) =~ ".herdr-worktrees/"
  end

  test "the connection check walks each link and stops at the first failure", %{host: host} do
    assert [{"ssh 连接 me@box", :ok}, {"远端 herdr socket " <> _, {:error, message}}] =
             Hosts.check(host)

    assert message =~ "远端 herdr 是否在运行"
  end

  test "~/ in the remote socket path is expanded on the host", %{host: host} do
    host = %{host | remote_socket: "~/.config/herdr/sessions/s/herdr.sock"}
    assert {:ok, path} = Tunnel.remote_socket(host)
    assert path == Path.join(System.user_home!(), ".config/herdr/sessions/s/herdr.sock")
  end

  test "the tunnel forwards the remote herdr socket to the local one", %{host: host} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, host.remote_socket}, active: false])

    on_exit(fn -> File.rm(host.socket_path) end)
    start_supervised!({Tunnel, host})

    sock = connect_eventually(host.socket_path, 50)
    {:ok, remote} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.send(sock, "ping\n")
    assert {:ok, "ping\n"} = :gen_tcp.recv(remote, 0, 2_000)

    assert [_, _, _, {"经隧道访问 herdr", {:error, _}}] = Hosts.check(host)
  end

  defp connect_eventually(path, tries) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false]) do
      {:ok, sock} ->
        sock

      {:error, _} when tries > 0 ->
        Process.sleep(50)
        connect_eventually(path, tries - 1)

      {:error, reason} ->
        flunk("tunnel never came up: #{inspect(reason)}")
    end
  end
end

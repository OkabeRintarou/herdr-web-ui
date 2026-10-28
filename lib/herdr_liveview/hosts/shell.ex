defmodule HerdrLiveView.Hosts.Shell do
  @moduledoc """
  Runs commands and touches files on a host: directly for local hosts (or `nil`, as in plain
  test maps), through `ssh` for ssh hosts. ssh reuses one master connection per host.
  """

  @doc "`{output, exit_status}` with stderr folded in."
  def cmd(host, exe, args) do
    case host do
      %{kind: "ssh", ssh_target: target} ->
        System.cmd(ssh(), ssh_opts() ++ ["--", target, remote_command([exe | args])],
          stderr_to_stdout: true
        )

      _ ->
        System.cmd(exe, args, stderr_to_stdout: true)
    end
  rescue
    e in ErlangError -> {"无法执行 #{exe}：#{inspect(e.original)}", 127}
  end

  def git(host, dir, args) do
    case cmd(host, "git", ["-C", dir | args]) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "git #{Enum.join(args, " ")}: #{String.trim(out)}"}
    end
  end

  def dir?(host, path),
    do:
      local_or(host, fn -> File.dir?(path) end, fn -> sh_ok?(host, "test -d \"$1\"", [path]) end)

  def read(host, path) do
    local_or(host, fn -> File.read(path) end, fn ->
      case cmd(host, "sh", ["-c", "test -e \"$1\" || exit 3; cat \"$1\"", "sh", path]) do
        {body, 0} -> {:ok, body}
        {_, 3} -> {:error, :enoent}
        {out, _} -> {:error, String.trim(out)}
      end
    end)
  end

  def mkdir_p!(host, path) do
    local_or(host, fn -> File.mkdir_p!(path) end, fn ->
      true = sh_ok?(host, "mkdir -p \"$1\"", [path])
      :ok
    end)
  end

  def append!(host, path, text) do
    local_or(host, fn -> File.write!(path, text, [:append]) end, fn ->
      true =
        sh_ok?(host, "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" >> \"$2\"", [text, path])

      :ok
    end)
  end

  @doc "Runs a shell snippet on the host; arguments arrive as $1, $2, …"
  def sh(host, script, args \\ []), do: cmd(host, "sh", ["-c", script, "sh" | args])

  def ssh_opts do
    [
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ControlMaster=auto",
      "-o",
      "ControlPath=#{Path.join(System.tmp_dir!(), "hlv-ssh-%C")}",
      "-o",
      "ControlPersist=120"
    ]
  end

  def ssh, do: Application.get_env(:herdr_liveview, :ssh_command, "ssh")

  defp sh_ok?(host, script, args), do: match?({_, 0}, sh(host, script, args))

  defp local_or(%{kind: "ssh"}, _local, remote), do: remote.()
  defp local_or(_host, local, _remote), do: local.()

  # ssh joins its arguments into one string for the remote shell, so quote each one
  defp remote_command(argv), do: Enum.map_join(argv, " ", &shell_quote/1)

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", ~S('"'"')) <> "'"
end

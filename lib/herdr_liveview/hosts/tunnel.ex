defmodule HerdrLiveView.Hosts.Tunnel do
  @moduledoc """
  Forwards an ssh host's herdr socket to `host.socket_path` here (`ssh -N -L`), so the
  herdr client and event stream work exactly as for a local host. Reconnects with backoff.
  """
  use GenServer
  require Logger

  alias HerdrLiveView.Hosts.Shell

  @max_backoff_ms 30_000

  def start_link(host), do: GenServer.start_link(__MODULE__, host, name: via(host.id))

  def child_spec(host),
    do: %{id: {__MODULE__, host.id}, start: {__MODULE__, :start_link, [host]}}

  defp via(id), do: {:via, Registry, {HerdrLiveView.Herdr.Registry, {:tunnel, id}}}

  @doc "The last ssh output, useful when the tunnel keeps failing."
  def last_error(host_id) do
    case Registry.lookup(HerdrLiveView.Herdr.Registry, {:tunnel, host_id}) do
      [{pid, _}] -> GenServer.call(pid, :last_error)
      [] -> nil
    end
  end

  @doc "The remote socket path with a leading ~/ expanded on the host."
  def remote_socket(host) do
    case host.remote_socket do
      "~/" <> rest ->
        case Shell.sh(host, ~S(printf %s "$HOME")) do
          {home, 0} -> {:ok, Path.join(String.trim(home), rest)}
          {out, _} -> {:error, String.trim(out)}
        end

      path ->
        {:ok, path}
    end
  end

  @impl true
  def init(host) do
    Process.flag(:trap_exit, true)
    send(self(), :open)
    {:ok, %{host: host, port: nil, backoff: 1_000, output: "", last_error: nil}}
  end

  @impl true
  def handle_call(:last_error, _from, state), do: {:reply, state.last_error, state}

  @impl true
  def handle_info(:open, %{host: host} = state) do
    case remote_socket(host) do
      {:ok, remote} ->
        File.rm(host.socket_path)

        args =
          ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ExitOnForwardFailure=yes"] ++
            ["-o", "ServerAliveInterval=15", "-o", "StreamLocalBindUnlink=yes", "-N"] ++
            ["-L", "#{host.socket_path}:#{remote}", "--", host.ssh_target]

        port =
          Port.open({:spawn_executable, System.find_executable(Shell.ssh())}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        {:noreply, %{state | port: port, output: ""}}

      {:error, reason} ->
        retry(state, reason)
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, %{state | output: String.slice(state.output <> data, -2_000, 2_000)}}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    retry(%{state | port: nil}, "ssh 退出（#{status}）：#{String.trim(state.output)}")
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: System.cmd("kill", [to_string(pid)])
  end

  def terminate(_reason, _state), do: :ok

  defp retry(state, reason) do
    Logger.warning("ssh tunnel to #{state.host.name} down: #{reason}")
    Process.send_after(self(), :open, state.backoff)

    {:noreply, %{state | last_error: reason, backoff: min(state.backoff * 2, @max_backoff_ms)}}
  end
end

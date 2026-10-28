defmodule HerdrLiveView.Herdr.Panes do
  @moduledoc """
  Keeps a live copy of the herdr pane list via `events.subscribe` and
  broadcasts every change on the "herdr:panes" PubSub topic.
  """
  use GenServer
  require Logger

  alias HerdrLiveView.Herdr.Client

  @topic "herdr:panes"
  @retry_ms 2_000
  @poll_ms 2_000
  @refresh_debounce_ms 100
  @subscriptions ~w(pane.created pane.updated pane.closed pane.moved pane.exited
                    pane.agent_detected tab.closed workspace.closed)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  @doc "Returns `{status, panes}` where status is `:connected` or `{:disconnected, reason}`."
  def snapshot do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :snapshot),
      else: {{:disconnected, :not_started}, %{}}
  end

  @impl true
  def init(_opts) do
    send(self(), :connect)
    Process.send_after(self(), :poll, @poll_ms)
    {:ok, %{status: {:disconnected, :starting}, panes: %{}, sock: nil, buf: "", refresh: nil}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, {state.status, state.panes}, state}

  @impl true
  def handle_info(:connect, state) do
    with {:ok, panes} <- fetch_panes(),
         {:ok, sock} <- subscribe() do
      {:noreply, publish(%{state | status: :connected, panes: panes, sock: sock, buf: ""})}
    else
      {:error, reason} ->
        Logger.warning("herdr connect failed: #{inspect(reason)}")
        Process.send_after(self(), :connect, @retry_ms)
        {:noreply, publish(%{state | status: {:disconnected, reason}, panes: %{}, sock: nil})}
    end
  end

  def handle_info({:tcp, sock, data}, %{sock: sock} = state) do
    {lines, rest} = split_lines(state.buf <> data)
    state = Enum.reduce(lines, %{state | buf: rest}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, sock}, %{sock: sock} = state), do: disconnected(state, :closed)

  def handle_info({:tcp_error, sock, reason}, %{sock: sock} = state),
    do: disconnected(state, reason)

  def handle_info(:refresh, state) do
    state = %{state | refresh: nil}

    case fetch_panes() do
      {:ok, panes} -> {:noreply, publish(%{state | panes: panes})}
      {:error, reason} -> {:noreply, publish(%{state | status: {:disconnected, reason}})}
    end
  end

  # Agent status changes don't emit pane_updated (and their own event needs a pane_id per
  # subscription), so a cheap re-list catches them.
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)

    with :connected <- state.status,
         {:ok, panes} when panes != state.panes <- fetch_panes() do
      {:noreply, publish(%{state | panes: panes})}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp disconnected(state, reason) do
    Logger.warning("herdr subscription lost: #{inspect(reason)}")
    Process.send_after(self(), :connect, @retry_ms)

    {:noreply,
     publish(%{state | status: {:disconnected, reason}, panes: %{}, sock: nil, buf: ""})}
  end

  defp fetch_panes do
    with {:ok, %{"panes" => panes}} <- Client.request("pane.list", %{}) do
      {:ok, Map.new(panes, &{&1["pane_id"], &1})}
    end
  end

  defp subscribe do
    with {:ok, sock} <- Client.connect(Client.socket_path()) do
      req = %{
        id: Client.request_id(),
        method: "events.subscribe",
        params: %{subscriptions: Enum.map(@subscriptions, &%{type: &1})}
      }

      with :ok <- :gen_tcp.send(sock, [Jason.encode!(req), ?\n]),
           :ok <- :inet.setopts(sock, active: true) do
        {:ok, sock}
      else
        error ->
          :gen_tcp.close(sock)
          error
      end
    end
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "pane_updated", "data" => %{"pane" => %{"pane_id" => id} = pane}}} ->
        publish(%{state | panes: Map.put(state.panes, id, pane)})

      {:ok, %{"event" => "pane_closed", "data" => %{"pane_id" => id}}} ->
        publish(%{state | panes: Map.delete(state.panes, id)})

      {:ok, %{"event" => _}} ->
        schedule_refresh(state)

      {:ok, %{"error" => error}} ->
        Logger.error("herdr subscription rejected: #{inspect(error)}")
        state

      _ ->
        state
    end
  end

  defp schedule_refresh(%{refresh: nil} = state),
    do: %{state | refresh: Process.send_after(self(), :refresh, @refresh_debounce_ms)}

  defp schedule_refresh(state), do: state

  defp publish(state) do
    Phoenix.PubSub.broadcast(
      HerdrLiveView.PubSub,
      @topic,
      {:herdr_panes, state.status, state.panes}
    )

    state
  end
end

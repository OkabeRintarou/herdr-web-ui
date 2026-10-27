defmodule HerdrLiveViewWeb.LiveTerminal do
  @moduledoc """
  Polls `pane.read` for one pane and pushes changed frames to the `Terminal` JS hook.
  The LiveView must forward `:terminal_poll` messages to `handle_poll/1`.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3]

  alias HerdrLiveView.Herdr

  @poll_ms 1_000

  def init(socket), do: assign(socket, term_pane: nil, frame_hash: nil, poll_ref: nil)

  @doc "Starts (or re-arms) polling `pane_id`; `nil` stops polling."
  def watch(socket, pane_id, delay \\ 0) do
    socket =
      if pane_id == socket.assigns.term_pane,
        do: socket,
        else:
          socket |> assign(term_pane: pane_id, frame_hash: nil) |> push_event("term:clear", %{})

    schedule(socket, delay)
  end

  def handle_poll(socket) do
    socket |> assign(poll_ref: nil) |> push_frame() |> schedule(@poll_ms)
  end

  defp schedule(socket, delay) do
    if ref = socket.assigns.poll_ref, do: Process.cancel_timer(ref)

    ref =
      if connected?(socket) and socket.assigns.term_pane,
        do: Process.send_after(self(), :terminal_poll, delay)

    assign(socket, poll_ref: ref)
  end

  defp push_frame(%{assigns: %{term_pane: pane_id}} = socket) when is_binary(pane_id) do
    case Herdr.read_pane(pane_id) do
      {:ok, text} ->
        hash = :erlang.phash2(text)

        if hash == socket.assigns.frame_hash,
          do: socket,
          else: socket |> assign(frame_hash: hash) |> push_event("term:frame", %{text: text})

      {:error, _reason} ->
        socket
    end
  end

  defp push_frame(socket), do: socket
end

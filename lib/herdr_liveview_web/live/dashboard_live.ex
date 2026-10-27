defmodule HerdrLiveViewWeb.DashboardLive do
  use HerdrLiveViewWeb, :live_view

  alias HerdrLiveView.Herdr
  alias HerdrLiveView.Herdr.Panes

  @poll_ms 1_000
  @after_input_ms 150

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(HerdrLiveView.PubSub, Panes.topic())

    {status, panes} = Panes.snapshot()

    {:ok,
     socket
     |> assign(status: status, panes: panes, selected: nil, frame_hash: nil, poll_ref: nil)
     |> assign(form: empty_form(), keys: Herdr.allowed_keys())
     |> stream_configure(:agents, dom_id: &"agent-#{dom_safe(&1["pane_id"])}")
     |> stream_agents()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected = params["pane_id"]

    socket =
      socket
      |> assign(selected: selected, frame_hash: nil, form: empty_form())
      |> assign(page_title: page_title(socket.assigns.panes[selected]))
      |> stream_agents()
      |> push_event("term:clear", %{})

    {:noreply, restart_polling(socket, 0)}
  end

  @impl true
  def handle_info({:herdr_panes, status, panes}, socket) do
    {:noreply,
     socket
     |> assign(status: status, panes: panes)
     |> assign(page_title: page_title(panes[socket.assigns.selected]))
     |> stream_agents()}
  end

  def handle_info(:poll, socket) do
    socket = socket |> assign(poll_ref: nil) |> push_frame()
    {:noreply, restart_polling(socket, @poll_ms)}
  end

  @impl true
  def handle_event("validate", %{"prompt" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :prompt))}
  end

  def handle_event("prompt", %{"prompt" => %{"text" => text}}, socket) do
    with pane_id when is_binary(pane_id) <- socket.assigns.selected,
         text when text != "" <- String.trim(text) do
      case Herdr.prompt(pane_id, text) do
        {:ok, _} ->
          {:noreply, socket |> assign(form: empty_form()) |> restart_polling(@after_input_ms)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Prompt failed: #{format_error(reason)}")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("key", %{"key" => key}, socket) do
    case socket.assigns.selected && Herdr.send_key(socket.assigns.selected, key) do
      {:ok, _} ->
        {:noreply, restart_polling(socket, @after_input_ms)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Key #{key} failed: #{format_error(reason)}")}

      nil ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:status>
        <.connection status={@status} />
      </:status>

      <div class="flex h-full">
        <aside class="flex w-80 shrink-0 flex-col border-r border-white/5 bg-zinc-900/40">
          <div class="flex items-center justify-between px-4 pt-4 pb-2">
            <h2 class="text-xs font-medium tracking-wider text-zinc-500 uppercase">Agents</h2>
            <span id="agent-count" class="rounded-full bg-white/5 px-2 py-0.5 text-xs text-zinc-400">
              {@agent_count}
            </span>
          </div>

          <ul id="agents" phx-update="stream" class="flex-1 space-y-1 overflow-y-auto px-2 pb-4">
            <li
              id="agents-empty"
              class="hidden px-3 py-8 text-center text-sm text-zinc-500 only:block"
            >
              No agents detected in this herdr session.
            </li>
            <li :for={{dom_id, pane} <- @streams.agents} id={dom_id}>
              <.link
                patch={~p"/panes/#{pane["pane_id"]}"}
                class={[
                  "group block rounded-lg px-3 py-2.5 ring-1 transition duration-150",
                  if(pane["pane_id"] == @selected,
                    do: "bg-white/[0.06] ring-white/10",
                    else: "ring-transparent hover:bg-white/[0.03]"
                  )
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="truncate text-sm font-medium text-zinc-100">
                    {pane["name"] || pane["label"] || pane["pane_id"]}
                  </span>
                  <.status_badge status={pane["agent_status"]} />
                </div>
                <div class="mt-1 flex items-center gap-1.5 text-xs text-zinc-500">
                  <span class="font-mono">{pane["pane_id"]}</span>
                  <span>·</span>
                  <span>{pane["agent"]}</span>
                </div>
                <p
                  :if={pane["terminal_title_stripped"]}
                  class="mt-1 truncate text-xs text-zinc-400"
                >
                  {pane["terminal_title_stripped"]}
                </p>
              </.link>
            </li>
          </ul>
        </aside>

        <section class="flex min-w-0 flex-1 flex-col">
          <%= if @selected do %>
            <.pane_header pane={@panes[@selected]} pane_id={@selected} />

            <div class="min-h-0 flex-1 overflow-auto bg-zinc-950 p-4">
              <div id="terminal" phx-hook="Terminal" phx-update="ignore" class="w-max"></div>
            </div>

            <div class="border-t border-white/5 bg-zinc-900/40 p-3">
              <div class="mb-2 flex flex-wrap gap-1.5">
                <button
                  :for={key <- @keys}
                  id={"key-#{dom_safe(key)}"}
                  type="button"
                  phx-click="key"
                  phx-value-key={key}
                  class="rounded-md bg-white/5 px-2 py-1 font-mono text-xs text-zinc-300 ring-1 ring-white/10 transition hover:bg-white/10 hover:text-white active:scale-95"
                >
                  {key}
                </button>
              </div>
              <.form
                for={@form}
                id="prompt-form"
                phx-change="validate"
                phx-submit="prompt"
                class="flex items-end gap-2"
              >
                <div class="flex-1 [&_.fieldset]:mb-0">
                  <.input
                    field={@form[:text]}
                    type="textarea"
                    rows="2"
                    phx-hook=".SubmitOnModEnter"
                    placeholder="Send a prompt…  (Ctrl/⌘ + Enter)"
                    class="block min-h-[2.75rem] w-full resize-y rounded-lg border-0 bg-zinc-950 px-3 py-2 text-sm text-zinc-100 ring-1 ring-white/10 placeholder:text-zinc-600 focus:ring-2 focus:ring-emerald-500/60 focus:outline-none"
                  />
                </div>
                <button
                  id="prompt-submit"
                  type="submit"
                  phx-disable-with="Sending…"
                  class="inline-flex h-11 items-center gap-1.5 rounded-lg bg-emerald-500 px-4 text-sm font-medium text-zinc-950 transition hover:bg-emerald-400 active:scale-[0.98] disabled:opacity-60"
                >
                  <.icon name="hero-paper-airplane-micro" class="size-4" /> Send
                </button>
              </.form>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnModEnter">
                export default {
                  mounted() {
                    this.el.addEventListener("keydown", e => {
                      if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
                        e.preventDefault()
                        this.el.form.requestSubmit()
                      }
                    })
                  }
                }
              </script>
            </div>
          <% else %>
            <div class="grid h-full place-items-center">
              <div class="text-center">
                <.icon name="hero-cursor-arrow-rays" class="size-8 text-zinc-700" />
                <p class="mt-3 text-sm text-zinc-500">Select an agent to view its terminal.</p>
              </div>
            </div>
          <% end %>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :pane, :map, default: nil
  attr :pane_id, :string, required: true

  defp pane_header(assigns) do
    ~H"""
    <div class="flex h-14 shrink-0 items-center justify-between gap-4 border-b border-white/5 px-4">
      <%= if @pane do %>
        <div class="min-w-0">
          <div class="flex items-center gap-2">
            <h1 class="truncate text-sm font-semibold">
              {@pane["name"] || @pane["label"] || @pane_id}
            </h1>
            <.status_badge status={@pane["agent_status"]} />
          </div>
          <p class="truncate font-mono text-xs text-zinc-500">
            {@pane["foreground_cwd"] || @pane["cwd"]}
          </p>
        </div>
      <% else %>
        <p class="text-sm text-zinc-500">
          Pane <span class="font-mono">{@pane_id}</span> is no longer available.
        </p>
      <% end %>
    </div>
    """
  end

  attr :status, :string, default: nil

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium ring-1 ring-inset",
      status_classes(@status)
    ]}>
      <span class={[
        "size-1.5 rounded-full bg-current",
        @status == "working" && "motion-safe:animate-pulse"
      ]} />
      {@status || "unknown"}
    </span>
    """
  end

  attr :status, :any, required: true

  defp connection(assigns) do
    ~H"""
    <span
      id="herdr-connection"
      class={[
        "inline-flex items-center gap-1.5 text-xs",
        if(@status == :connected, do: "text-zinc-400", else: "text-amber-400")
      ]}
    >
      <span class={[
        "size-1.5 rounded-full",
        if(@status == :connected,
          do: "bg-emerald-400",
          else: "bg-amber-400 motion-safe:animate-pulse"
        )
      ]} />
      {if @status == :connected, do: "herdr connected", else: "herdr disconnected — retrying"}
    </span>
    """
  end

  defp status_classes("working"), do: "bg-sky-400/10 text-sky-300 ring-sky-400/20"
  defp status_classes("blocked"), do: "bg-amber-400/10 text-amber-300 ring-amber-400/30"
  defp status_classes("done"), do: "bg-emerald-400/10 text-emerald-300 ring-emerald-400/20"
  defp status_classes("idle"), do: "bg-zinc-400/10 text-zinc-300 ring-zinc-400/20"
  defp status_classes(_), do: "bg-zinc-500/10 text-zinc-500 ring-zinc-500/20"

  defp stream_agents(socket) do
    agents =
      socket.assigns.panes
      |> Map.values()
      |> Enum.filter(& &1["agent"])
      |> Enum.sort_by(&{&1["workspace_id"], &1["tab_id"], &1["pane_id"]})

    socket
    |> assign(agent_count: length(agents))
    |> stream(:agents, agents, reset: true)
  end

  defp restart_polling(socket, delay) do
    if ref = socket.assigns.poll_ref, do: Process.cancel_timer(ref)

    ref =
      if connected?(socket) and socket.assigns.selected,
        do: Process.send_after(self(), :poll, delay)

    assign(socket, poll_ref: ref)
  end

  defp push_frame(%{assigns: %{selected: pane_id}} = socket) when is_binary(pane_id) do
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

  defp empty_form, do: to_form(%{"text" => ""}, as: :prompt)

  defp page_title(nil), do: "herdr"
  defp page_title(pane), do: pane["name"] || pane["label"] || pane["pane_id"]

  defp dom_safe(value), do: String.replace(value, ~r/[^A-Za-z0-9_-]/, "-")

  defp format_error({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
  defp format_error(reason), do: inspect(reason)
end

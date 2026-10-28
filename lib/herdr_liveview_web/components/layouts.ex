defmodule HerdrLiveViewWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HerdrLiveViewWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true
  slot :status, doc: "right side of the top bar"
  slot :crumb, doc: "current location shown after the tabs, e.g. the project name"
  attr :active, :atom, default: nil, doc: "highlighted top-level tab"

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col bg-zinc-950 text-zinc-100 antialiased">
      <header class="flex h-12 shrink-0 items-center justify-between gap-4 border-b border-white/5 px-4">
        <div class="flex items-center gap-3 sm:gap-6">
          <.link navigate={~p"/"} class="group flex items-center gap-2.5">
            <span class="grid size-7 place-items-center rounded-lg bg-emerald-400/10 text-emerald-400 ring-1 ring-emerald-400/20 transition group-hover:bg-emerald-400/20">
              <.icon name="hero-command-line-micro" class="size-4" />
            </span>
            <span class="hidden text-sm font-semibold tracking-tight sm:inline">herdr</span>
            <span class="hidden text-sm text-zinc-500 md:inline">liveview</span>
          </.link>
          <nav class="flex items-center gap-1 text-sm">
            <.nav_tab navigate={~p"/"} active={@active == :projects} icon="hero-squares-2x2-micro">
              项目
            </.nav_tab>
            <.nav_tab navigate={~p"/hosts"} active={@active == :agents} icon="hero-cpu-chip-micro">
              Agents
            </.nav_tab>
          </nav>
          <div
            :if={@crumb != []}
            class="hidden min-w-0 items-center gap-2 text-sm text-zinc-400 md:flex"
          >
            <.icon name="hero-chevron-right-micro" class="size-4 text-zinc-600" />
            {render_slot(@crumb)}
          </div>
        </div>
        <div class="flex items-center gap-3">{render_slot(@status)}</div>
      </header>
      <main class="min-h-0 flex-1">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_tab(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center gap-1.5 rounded-md px-2.5 py-1.5 whitespace-nowrap transition",
        if(@active,
          do: "bg-white/[0.07] text-zinc-100",
          else: "text-zinc-400 hover:bg-white/[0.04] hover:text-zinc-200"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end

defmodule HerdrLiveViewWeb.HerdrComponents do
  @moduledoc "UI pieces shared by the agents page and the task board."
  use Phoenix.Component

  attr :status, :string, default: nil

  def status_badge(assigns) do
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

  def connection(assigns) do
    ~H"""
    <span
      id="herdr-connection"
      title={if @status == :connected, do: "herdr connected", else: "herdr disconnected"}
      class={[
        "inline-flex items-center gap-1.5 text-xs whitespace-nowrap",
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
      <span class="hidden md:inline">
        {if @status == :connected, do: "herdr connected", else: "herdr disconnected — retrying"}
      </span>
    </span>
    """
  end

  defp status_classes("working"), do: "bg-sky-400/10 text-sky-300 ring-sky-400/20"
  defp status_classes("blocked"), do: "bg-amber-400/10 text-amber-300 ring-amber-400/30"
  defp status_classes("done"), do: "bg-emerald-400/10 text-emerald-300 ring-emerald-400/20"
  defp status_classes("idle"), do: "bg-zinc-400/10 text-zinc-300 ring-zinc-400/20"
  defp status_classes(_), do: "bg-zinc-500/10 text-zinc-500 ring-zinc-500/20"
end

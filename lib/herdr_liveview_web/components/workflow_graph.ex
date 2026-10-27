defmodule HerdrLiveViewWeb.WorkflowGraph do
  @moduledoc """
  Server-rendered SVG of a workflow: steps laid out left to right, the edge to the next
  step drawn straight, forward skips arced above and loops back arced below.
  """
  use Phoenix.Component

  alias HerdrLiveView.Tasks.Workflow

  @w 100
  @h 48
  @gap 56
  @pad 14

  attr :id, :string, required: true
  attr :workflow, :map, required: true
  attr :current, :string, default: nil
  attr :visits, :map, default: %{}
  attr :edge_counts, :map, default: %{}
  attr :finished, :boolean, default: false

  def graph(assigns) do
    wf = assigns.workflow
    nodes = wf.steps ++ [%{id: "done", label: "完成", role: nil}]
    edges = edges(wf, assigns.edge_counts)

    below =
      edges |> Enum.filter(&(&1.kind == :back)) |> Enum.map(& &1.span) |> Enum.max(fn -> 0 end)

    above =
      edges |> Enum.filter(&(&1.kind == :skip)) |> Enum.map(& &1.span) |> Enum.max(fn -> 0 end)

    top = if above > 0, do: 34 + above * 8, else: 12

    width = @pad * 2 + length(nodes) * @w + (length(nodes) - 1) * @gap
    height = top + @h + 30 + below * 20

    assigns =
      assign(assigns,
        nodes: Enum.with_index(nodes),
        edges: edges,
        width: width,
        height: height,
        w: @w,
        h: @h,
        top: top
      )

    ~H"""
    <div class="overflow-x-auto">
      <svg
        id={@id}
        viewBox={"0 0 #{@width} #{@height}"}
        width={@width}
        height={@height}
        class="block"
        role="img"
        aria-label={"workflow #{@workflow.name}"}
      >
        <defs>
          <marker
            :for={{name, color} <- [{"fwd", "#52525b"}, {"hot", "#a1a1aa"}, {"back", "#b45309"}]}
            id={"#{@id}-arrow-#{name}"}
            viewBox="0 0 8 8"
            refX="7"
            refY="4"
            markerWidth="7"
            markerHeight="7"
            orient="auto-start-reverse"
          >
            <path d="M0,0 L8,4 L0,8 z" fill={color} />
          </marker>
        </defs>

        <g :for={edge <- @edges} id={"#{@id}-edge-#{edge.from}-#{edge.on}"}>
          <path
            d={edge_path(edge, @w, @h, @top)}
            fill="none"
            stroke-width={if edge.count > 0, do: "1.6", else: "1.2"}
            stroke-dasharray={if edge.kind == :back, do: "4 3"}
            marker-end={"url(##{@id}-arrow-#{marker(edge)})"}
            class={edge_stroke(edge)}
          />
          <text
            x={label_x(edge, @w)}
            y={label_y(edge, @h, @top)}
            text-anchor="middle"
            class={["text-[10px]", edge_text(edge)]}
          >
            {Workflow.verdict_label(edge.on)}{if edge.max, do: " #{edge.count}/#{edge.max}"}
          </text>
        </g>

        <g
          :for={{node, i} <- @nodes}
          id={"#{@id}-node-#{node.id}"}
          data-state={node_state(node, @current, @visits, @finished)}
        >
          <%= if node.id == "done" do %>
            <rect
              x={x(i) + 18}
              y={@top + 6}
              width={@w - 36}
              height={@h - 12}
              rx="19"
              class={
                if @finished,
                  do: "fill-emerald-400/15 stroke-emerald-400/60",
                  else: "fill-zinc-900 stroke-zinc-700"
              }
            />
            <text
              x={x(i) + @w / 2}
              y={@top + @h / 2 + 4}
              text-anchor="middle"
              class={["text-[12px]", if(@finished, do: "fill-emerald-300", else: "fill-zinc-500")]}
            >
              完成
            </text>
          <% else %>
            <rect
              x={x(i)}
              y={@top}
              width={@w}
              height={@h}
              rx="10"
              stroke-width={if node.id == @current, do: "1.8", else: "1"}
              class={node_box(node_state(node, @current, @visits, @finished))}
            />
            <circle
              :if={node.id == @current}
              cx={x(i) + @w - 10}
              cy={@top + 10}
              r="3"
              class="fill-sky-400 motion-safe:animate-pulse"
            />
            <text x={x(i) + 12} y={@top + 21} class="fill-zinc-100 text-[12px] font-medium">
              {node.label}
            </text>
            <text x={x(i) + 12} y={@top + 38} class="fill-zinc-500 text-[10px]">
              {node.role}{if (n = Map.get(@visits, node.id, 0)) > 1, do: " · ×#{n}"}
            </text>
          <% end %>
        </g>
      </svg>
    </div>
    """
  end

  defp edges(wf, counts) do
    for {from, transitions} <- wf.transitions, t <- transitions do
      i = Workflow.index(wf, from)
      j = Workflow.index(wf, t.to)

      kind =
        cond do
          j == i + 1 -> :next
          j > i + 1 -> :skip
          true -> :back
        end

      %{
        from: from,
        on: t.on,
        to: t.to,
        max: t.max,
        i: i,
        j: j,
        kind: kind,
        span: abs(j - i),
        count: Map.get(counts, "#{from}:#{t.on}", 0)
      }
    end
    |> Enum.sort_by(&{&1.kind != :next, &1.span})
  end

  defp x(i), do: @pad + i * (@w + @gap)

  defp edge_path(%{kind: :next, i: i, j: j}, w, h, top) do
    y = top + h / 2
    "M#{x(i) + w},#{y} L#{x(j) - 2},#{y}"
  end

  defp edge_path(%{kind: :skip, i: i, j: j, span: span}, w, _h, top) do
    {x1, x2} = {x(i) + w * 0.65, x(j) + w * 0.35}
    lift = 22 + span * 8
    "M#{x1},#{top} C#{x1},#{top - lift} #{x2},#{top - lift} #{x2},#{top - 2}"
  end

  defp edge_path(%{kind: :back, span: span} = edge, w, h, top) do
    {x1, x2} = back_ends(edge, w)
    drop = 14 + span * 20
    base = top + h
    "M#{x1},#{base} C#{x1},#{base + drop} #{x2},#{base + drop} #{x2},#{base + 2}"
  end

  # Loops into the same step land at different points so arrows and labels don't stack.
  defp back_ends(%{i: i, j: j, span: span}, w) do
    {x(i) + w * 0.3, x(j) + w * (0.78 - 0.14 * min(span - 1, 4))}
  end

  defp label_x(%{kind: :next, i: i}, w), do: x(i) + w + @gap / 2
  defp label_x(%{kind: :skip, i: i, j: j}, w), do: (x(i) + w * 0.65 + x(j) + w * 0.35) / 2

  defp label_x(%{kind: :back} = edge, w) do
    {x1, x2} = back_ends(edge, w)
    (x1 + x2) / 2
  end

  defp label_y(%{kind: :next}, h, top), do: top + h / 2 - 6
  defp label_y(%{kind: :skip, span: span}, _h, top), do: top - (22 + span * 8) * 0.75 - 4
  defp label_y(%{kind: :back, span: span}, h, top), do: top + h + (14 + span * 20) * 0.75 + 10

  defp marker(%{kind: :back}), do: "back"
  defp marker(%{count: c}) when c > 0, do: "hot"
  defp marker(_edge), do: "fwd"

  defp edge_stroke(%{kind: :back, count: c}) when c > 0, do: "stroke-amber-500"
  defp edge_stroke(%{kind: :back}), do: "stroke-amber-700/70"
  defp edge_stroke(%{count: c}) when c > 0, do: "stroke-zinc-400"
  defp edge_stroke(_edge), do: "stroke-zinc-600"

  defp edge_text(%{kind: :back, count: c, max: max}) when is_integer(max) and c >= max,
    do: "fill-rose-300"

  defp edge_text(%{kind: :back, count: c}) when c > 0, do: "fill-amber-300"
  defp edge_text(%{kind: :back}), do: "fill-amber-600/80"
  defp edge_text(%{count: c}) when c > 0, do: "fill-zinc-300"
  defp edge_text(_edge), do: "fill-zinc-500"

  defp node_state(%{id: id}, current, _visits, _finished) when id == current, do: "current"
  defp node_state(%{id: "done"}, _current, _visits, true), do: "visited"

  defp node_state(%{id: id}, _current, visits, _finished),
    do: if(Map.has_key?(visits, id), do: "visited", else: "pending")

  defp node_box("current"), do: "fill-sky-400/10 stroke-sky-400"
  defp node_box("visited"), do: "fill-emerald-400/[0.06] stroke-emerald-500/50"
  defp node_box(_), do: "fill-zinc-900 stroke-zinc-700"
end

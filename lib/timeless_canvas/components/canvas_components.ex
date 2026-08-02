defmodule TimelessCanvas.Components.CanvasComponents do
  @moduledoc """
  SVG element and connection renderers for the canvas.
  """
  use Phoenix.Component

  require Logger

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.IconCatalog
  alias TimelessCanvas.MetricFormatter

  attr(:element, Element, required: true)
  attr(:selected, :boolean, default: false)
  # [entry_map] | :error (backend query failure — rendered distinctly)
  attr(:stream_entries, :any, default: [])
  attr(:expanded_graph_id, :string, default: nil)
  attr(:metric_units, :map, default: %{})
  # value | nil (no data) | :error (backend query failure)
  attr(:text_value, :any, default: nil)

  def canvas_element(assigns) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        is_expanded =
          assigns.element.type == :graph and assigns.expanded_graph_id == assigns.element.id

        {render_w, render_h} =
          if is_expanded do
            {assigns.element.width * 2, assigns.element.height * 2}
          else
            {assigns.element.width, assigns.element.height}
          end

        assigns =
          assign(assigns,
            status_color: status_color(assigns.element.status),
            is_expanded: is_expanded,
            render_w: render_w,
            render_h: render_h
          )

        ~H"""
        <g
          class={"canvas-element#{if @selected, do: " canvas-element--selected", else: ""}"}
          data-element-id={@element.id}
        >
          <.element_body
            element={@element}
            stream_entries={@stream_entries}
            is_expanded={@is_expanded}
            render_w={@render_w}
            render_h={@render_h}
            metric_units={@metric_units}
            text_value={@text_value}
          />
          <.element_icon element={@element} />
          <.element_badge_icon element={@element} />
          <text
            :if={@element.type not in [:graph, :log_stream, :trace_stream, :text, :text_series]}
            x={@element.x + @render_w / 2}
            y={@element.y + @render_h - 16}
            text-anchor="middle"
            dominant-baseline="central"
            class="canvas-element__label"
          >
            {@element.label}
          </text>
          <circle
            :if={@element.type != :text}
            cx={@element.x + @render_w - 8}
            cy={@element.y + 8}
            r="5"
            fill={@status_color}
            class={"canvas-element__status#{if @element.status == :error, do: " canvas-element__status--error", else: ""}"}
          />
          <rect
            :if={@selected}
            x={@element.x + @render_w - 10}
            y={@element.y + @render_h - 10}
            width="10"
            height="10"
            class="canvas-element__handle"
            data-handle="se"
          />
        </g>
        """
      end)

    bump_render_stat(:canvas_element_calls, 1)
    bump_render_stat(:canvas_element_time_us, elapsed_us)
    result
  end

  defp status_color(:ok), do: "#22c55e"
  defp status_color(:warning), do: "#f59e0b"
  defp status_color(:error), do: "#ef4444"
  defp status_color(_), do: "#64748b"

  # --- Element body shapes ---

  defp element_body(%{element: %{type: :database}} = assigns) do
    ~H"""
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + 15}
      rx={@element.width / 2}
      ry="15"
      fill={@element.color}
      class="canvas-element__body"
    />
    <rect
      x={@element.x}
      y={@element.y + 15}
      width={@element.width}
      height={@element.height - 30}
      fill={@element.color}
      class="canvas-element__body-rect"
    />
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + @element.height - 15}
      rx={@element.width / 2}
      ry="15"
      fill={@element.color}
      class="canvas-element__body-bottom"
    />
    <ellipse
      cx={@element.x + @element.width / 2}
      cy={@element.y + @element.height - 15}
      rx={@element.width / 2}
      ry="15"
      fill="none"
      stroke={@element.color}
      stroke-width="1"
      style="filter: brightness(0.7)"
      pointer-events="none"
    />
    <%!-- Transparent hit rect covering full cylinder for drag/click --%>
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      fill="transparent"
      class="canvas-element__hit"
    />
    """
  end

  defp element_body(%{element: %{type: :log_stream}} = assigns) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        level_filter = Map.get(assigns.element.meta, "level", "all")

        log_title =
          case assigns.element.label do
            nil -> "Logs"
            "" -> "Logs"
            label -> "#{label} | #{level_filter}"
          end

        stream_error? = assigns.stream_entries == :error
        entries = if stream_error?, do: [], else: assigns.stream_entries
        max_rows = max(floor((assigns.element.height - 24) / 14), 1)
        rows = Enum.take(entries, max_rows)

        assigns = assign(assigns, log_title: log_title, rows: rows, stream_error?: stream_error?)

        ~H"""
        <rect
          x={@element.x}
          y={@element.y}
          width={@element.width}
          height={@element.height}
          rx="4"
          ry="4"
          fill="#0f172a"
          class="canvas-element__body"
        />
        <clipPath id={"log-clip-#{@element.id}"}>
          <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} rx="4" />
        </clipPath>
        <text
          x={@element.x + 4}
          y={@element.y + 10}
          fill="#94a3b8"
          font-size="8"
          clip-path={"url(#log-clip-#{@element.id})"}
        >
          {@log_title}
        </text>
        <g :for={{entry, i} <- Enum.with_index(@rows)}>
          <rect
            x={@element.x}
            y={@element.y + 15 + i * 14}
            width={@element.width}
            height="14"
            fill="transparent"
            class="canvas-stream-row"
            data-entry-id={Map.get(entry, :id)}
          />
          <text
            x={@element.x + 4}
            y={@element.y + 24 + i * 14}
            fill={log_level_color(entry.level)}
            font-size="9"
            font-family="monospace"
            clip-path={"url(#log-clip-#{@element.id})"}
            pointer-events="none"
          >
            {format_log_entry(entry)}
          </text>
        </g>
        <text
          :if={@rows == [] && !@stream_error?}
          x={@element.x + @element.width / 2}
          y={@element.y + @element.height / 2 + 4}
          text-anchor="middle"
          fill="#475569"
          font-size="9"
        >
          Waiting for logs...
        </text>
        <text
          :if={@stream_error?}
          x={@element.x + @element.width / 2}
          y={@element.y + @element.height / 2 + 4}
          text-anchor="middle"
          fill="#f59e0b"
          opacity="0.8"
          font-size="9"
        >
          log backend unavailable
        </text>
        """
      end)

    bump_render_stat(:log_stream_body_calls, 1)
    bump_render_stat(:log_stream_body_time_us, elapsed_us)
    result
  end

  defp element_body(%{element: %{type: :trace_stream}} = assigns) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        service_filter = Map.get(assigns.element.meta, "service", "all")

        trace_title =
          case assigns.element.label do
            nil -> "Traces"
            "" -> "Traces"
            label -> "#{label} | #{service_filter}"
          end

        stream_error? = assigns.stream_entries == :error
        entries = if stream_error?, do: [], else: assigns.stream_entries
        max_rows = max(floor((assigns.element.height - 24) / 14), 1)
        rows = Enum.take(entries, max_rows)

        assigns =
          assign(assigns, trace_title: trace_title, rows: rows, stream_error?: stream_error?)

        ~H"""
        <rect
          x={@element.x}
          y={@element.y}
          width={@element.width}
          height={@element.height}
          rx="4"
          ry="4"
          fill="#0f172a"
          class="canvas-element__body"
        />
        <clipPath id={"trace-clip-#{@element.id}"}>
          <rect
            x={@element.x}
            y={@element.y}
            width={@element.width}
            height={@element.height}
            rx="4"
          />
        </clipPath>
        <text
          x={@element.x + 4}
          y={@element.y + 10}
          fill="#94a3b8"
          font-size="8"
          clip-path={"url(#trace-clip-#{@element.id})"}
        >
          {@trace_title}
        </text>
        <g :for={{span, i} <- Enum.with_index(@rows)}>
          <rect
            x={@element.x}
            y={@element.y + 15 + i * 14}
            width={@element.width}
            height="14"
            fill="transparent"
            class="canvas-stream-row"
            data-entry-id={Map.get(span, :id)}
          />
          <text
            x={@element.x + 4}
            y={@element.y + 24 + i * 14}
            font-size="9"
            font-family="monospace"
            clip-path={"url(#trace-clip-#{@element.id})"}
            pointer-events="none"
          >
            <tspan fill="#94a3b8">{format_stream_timestamp(Map.get(span, :timestamp))}</tspan>
            <tspan dx="6" fill="#e2e8f0">{span.name}</tspan>
            <tspan dx="6" fill={duration_color(span.duration_ns)}>
              {format_duration(span.duration_ns)}
            </tspan>
            <tspan dx="6" fill={span_status_color(span.status)}>{span_status_label(span.status)}</tspan>
          </text>
        </g>
        <text
          :if={@rows == [] && !@stream_error?}
          x={@element.x + @element.width / 2}
          y={@element.y + @element.height / 2 + 4}
          text-anchor="middle"
          fill="#475569"
          font-size="9"
        >
          Waiting for traces...
        </text>
        <text
          :if={@stream_error?}
          x={@element.x + @element.width / 2}
          y={@element.y + @element.height / 2 + 4}
          text-anchor="middle"
          fill="#f59e0b"
          opacity="0.8"
          font-size="9"
        >
          trace backend unavailable
        </text>
        """
      end)

    bump_render_stat(:trace_stream_body_calls, 1)
    bump_render_stat(:trace_stream_body_time_us, elapsed_us)
    result
  end

  defp element_body(%{element: %{type: :graph}, is_expanded: true} = assigns) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        metric_name = Map.get(assigns.element.meta, "metric_name", "metric")

        graph_title =
          case assigns.element.label do
            nil -> metric_name
            "" -> metric_name
            label -> "#{label} | #{metric_name}"
          end

        assigns = assign(assigns, graph_title: graph_title)

        ~H"""
        <g data-expanded="true">
          <rect
            x={@element.x}
            y={@element.y}
            width={@render_w}
            height={@render_h}
            rx="6"
            ry="6"
            fill="#0c1222"
            class="canvas-element__body"
          />
          <clipPath id={"graph-clip-#{@element.id}"}>
            <rect x={@element.x} y={@element.y} width={@render_w} height={@render_h} rx="6" />
          </clipPath>
          <%!-- Legend chrome; the current-value text inside it is pushed
               with the rest of the dynamic internals below. --%>
          <g transform={"translate(#{@element.x + @render_w - 8}, #{@element.y + 10})"}>
            <rect x="-60" y="-6" width="60" height="12" rx="3" fill="#1e293b" opacity="0.8" />
            <rect x="-56" y="-2" width="8" height="4" rx="1" fill={@element.color} />
          </g>
          <%!-- Dynamic internals (gridlines, axis labels, area, line,
               current value): rendered client-side by the Canvas hook from
               "graph:expanded" push_event payloads (expanded_graph_payload/3);
               LiveView never patches this subtree, so data ticks produce
               zero template diff. --%>
          <g id={"graph-dyn-#{@element.id}-expanded"} phx-update="ignore"></g>
          <text
            x={@element.x + 8}
            y={@element.y + 14}
            fill="#94a3b8"
            font-size="10"
            clip-path={"url(#graph-clip-#{@element.id})"}
          >
            {@graph_title}
          </text>
        </g>
        """
      end)

    bump_render_stat(:expanded_graph_body_calls, 1)
    bump_render_stat(:expanded_graph_body_time_us, elapsed_us)
    result
  end

  defp element_body(%{element: %{type: :graph}} = assigns) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        metric_name = Map.get(assigns.element.meta, "metric_name", "metric")
        unit = Map.get(assigns.metric_units, assigns.element.id)

        base_title =
          case assigns.element.label do
            nil -> metric_name
            "" -> metric_name
            label -> "#{label} | #{metric_name}"
          end

        graph_title = if unit, do: "#{base_title} (#{unit})", else: base_title
        graph_icon = IconCatalog.graph_icon_name(assigns.element)

        # The pushed current-value text is right-aligned at x + width - 18;
        # truncate the title to leave it ~8 chars of room instead of
        # overlapping (both render at font-size 8, ~4.8px per char).
        title_offset = if graph_icon, do: 32, else: 4
        title_budget = compact_title_budget(assigns.element.width, title_offset)
        graph_title = truncate_text(graph_title, title_budget)

        {plot_x, plot_y, plot_w, plot_h} = compact_plot_box(assigns.element)

        assigns =
          assign(assigns,
            graph_title: graph_title,
            graph_icon: graph_icon,
            graph_title_x: assigns.element.x + title_offset,
            plot_x: plot_x,
            plot_y: plot_y,
            plot_w: plot_w,
            plot_h: plot_h
          )

        ~H"""
        <rect
          x={@element.x}
          y={@element.y}
          width={@element.width}
          height={@element.height}
          rx="4"
          ry="4"
          fill="#0f172a"
          class="canvas-element__body"
        />
        <clipPath id={"graph-plot-clip-#{@element.id}"}>
          <rect x={@plot_x} y={@plot_y} width={@plot_w} height={@plot_h} rx="2" />
        </clipPath>
        <%!-- Dynamic internals (gridlines, axis labels, line, current
             value): rendered client-side by the Canvas hook from
             "graph:data" push_event payloads (compact_graph_payload/3);
             LiveView never patches this subtree, so data ticks produce
             zero template diff. --%>
        <g id={"graph-dyn-#{@element.id}"} phx-update="ignore"></g>
        <clipPath id={"graph-clip-#{@element.id}"}>
          <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} />
        </clipPath>
        <rect
          :if={@graph_icon}
          x={@element.x + 4}
          y={@element.y + 3}
          width="24"
          height="24"
          rx="3"
          ry="3"
          fill="#ffffff"
          stroke="#cbd5e1"
          stroke-width="0.6"
          opacity="0.95"
        />
        <.iconify_svg :if={@graph_icon} icon={@graph_icon} x={@element.x + 6} y={@element.y + 5} size={20} />
        <text
          x={@graph_title_x}
          y={@element.y + 10}
          class="canvas-graph__title"
          fill="#94a3b8"
          font-size="8"
          clip-path={"url(#graph-clip-#{@element.id})"}
        >
          {@graph_title}
        </text>
        """
      end)

    bump_render_stat(:graph_body_calls, 1)
    bump_render_stat(:graph_body_time_us, elapsed_us)
    result
  end

  defp element_body(%{element: %{type: :text_series}} = assigns) do
    metric_name = Map.get(assigns.element.meta, "metric_name", "metric")

    title =
      case assigns.element.label do
        nil -> metric_name
        "" -> metric_name
        label -> "#{label} | #{metric_name}"
      end

    # nil = no data (em dash); :error = backend query failure (distinct
    # muted warning so a down backend never masquerades as "no data").
    {display_value, value_fill, value_size} =
      case assigns.text_value do
        :error -> {"data unavailable", "#f59e0b", 9}
        nil -> {"\u2014", assigns.element.color, 12}
        value -> {value, assigns.element.color, 12}
      end

    assigns =
      assign(assigns,
        title: title,
        display_value: display_value,
        value_fill: value_fill,
        value_size: value_size
      )

    ~H"""
    <rect
      x={@element.x} y={@element.y}
      width={@element.width} height={@element.height}
      rx="4" ry="4"
      fill="#0f172a"
      class="canvas-element__body"
    />
    <clipPath id={"text-series-clip-#{@element.id}"}>
      <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} />
    </clipPath>
    <text
      x={@element.x + 4} y={@element.y + 10}
      class="canvas-graph__title" fill="#94a3b8" font-size="8"
      clip-path={"url(#text-series-clip-#{@element.id})"}
    >
      {@title}
    </text>
    <text
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2 + 4}
      text-anchor="middle" dominant-baseline="central"
      fill={@value_fill} font-size={@value_size}
      clip-path={"url(#text-series-clip-#{@element.id})"}
    >
      {@display_value}
    </text>
    """
  end

  defp element_body(%{element: %{type: :text}} = assigns) do
    font_size = Map.get(assigns.element.meta, "font_size", "16")

    font_size =
      case Integer.parse(to_string(font_size)) do
        {n, _} when n > 0 -> n
        _ -> 16
      end

    assigns = assign(assigns, font_size: font_size)

    ~H"""
    <clipPath id={"text-clip-#{@element.id}"}>
      <rect
        x={@element.x}
        y={@element.y}
        width={@element.width}
        height={@element.height}
      />
    </clipPath>
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      fill="transparent"
      class="canvas-element__body"
    />
    <text
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2}
      text-anchor="middle"
      dominant-baseline="central"
      fill={@element.color}
      font-size={@font_size}
      clip-path={"url(#text-clip-#{@element.id})"}
      class="canvas-element__text-content"
    >
      {@element.label}
    </text>
    """
  end

  defp element_body(assigns) do
    assigns = assign(assigns, image_url: assigns.element.meta["image_url"])

    ~H"""
    <rect
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      rx="6"
      ry="6"
      fill={if @image_url && @image_url != "", do: "none", else: @element.color}
      class="canvas-element__body"
    />
    <image
      :if={@image_url && @image_url != ""}
      x={@element.x}
      y={@element.y}
      width={@element.width}
      height={@element.height}
      href={@image_url}
      preserveAspectRatio="xMidYMid slice"
      clip-path={"url(#rect-clip-#{@element.id})"}
    />
    <clipPath :if={@image_url && @image_url != ""} id={"rect-clip-#{@element.id}"}>
      <rect
        x={@element.x}
        y={@element.y}
        width={@element.width}
        height={@element.height}
        rx="6"
        ry="6"
      />
    </clipPath>
    """
  end

  # --- Element icons ---

  defp element_icon(%{element: %{type: :rect}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :graph}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :text}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :text_series}} = assigns), do: ~H""

  defp element_icon(%{element: %{type: :database}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        ~H""

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 18
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :log_stream}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.2) translate(-8, -8)"}
    >
      <line x1="2" y1="3" x2="14" y2="3" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="7" x2="12" y2="7" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="11" x2="10" y2="11" stroke="#334155" stroke-width="1.5" opacity="0.6" />
      <line x1="2" y1="15" x2="13" y2="15" stroke="#334155" stroke-width="1.5" opacity="0.6" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :trace_stream}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 8
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.2) translate(-8, -8)"}
    >
      <rect x="0" y="1" width="14" height="3" rx="1" fill="#334155" opacity="0.6" />
      <rect x="3" y="6" width="10" height="3" rx="1" fill="#334155" opacity="0.5" />
      <rect x="6" y="11" width="8" height="3" rx="1" fill="#334155" opacity="0.4" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :server}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-12, -12)"}
    >
      <rect x="0" y="0" width="24" height="7" rx="1" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
      <rect x="0" y="9" width="24" height="7" rx="1" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
      <rect x="0" y="18" width="24" height="7" rx="1" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
      <circle cx="20" cy="3.5" r="1.5" fill="#22c55e" />
      <circle cx="20" cy="12.5" r="1.5" fill="#22c55e" />
      <circle cx="20" cy="21.5" r="1.5" fill="#22c55e" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :service}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        assigns =
          assign(assigns,
            cx: assigns.element.x + assigns.element.width / 2,
            cy: assigns.element.y + assigns.element.height / 2 - 8
          )

        ~H"""
        <g
          class="canvas-element__icon"
          transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
        >
          <path
            d="M10 3.5L11.5 1h-3L10 3.5zM10 16.5L8.5 19h3L10 16.5zM3.5 10L1 8.5v3L3.5 10zM16.5 10L19 11.5v-3L16.5 10zM4.5 5.5L2.5 3.5l-1 1L4.5 7.5 4.5 5.5zM15.5 14.5L17.5 16.5l1-1L15.5 12.5V14.5zM5.5 15.5L3.5 17.5l1 1L7.5 15.5H5.5zM14.5 4.5L16.5 2.5l-1-1L12.5 4.5H14.5z"
            fill="white"
            opacity="0.9"
          />
          <circle cx="10" cy="10" r="4" fill="none" stroke="white" stroke-width="1.5" opacity="0.9" />
        </g>
        """

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 12
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :load_balancer}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        assigns =
          assign(assigns,
            cx: assigns.element.x + assigns.element.width / 2,
            cy: assigns.element.y + assigns.element.height / 2 - 8
          )

        ~H"""
        <g
          class="canvas-element__icon"
          transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -8)"}
        >
          <path
            d="M0 8 L8 8 L8 2 L16 2 M8 8 L8 8 L16 8 M8 8 L8 14 L16 14"
            fill="none"
            stroke="white"
            stroke-width="1.5"
            stroke-linecap="round"
            opacity="0.9"
          />
          <polygon points="16,0 20,2 16,4" fill="white" opacity="0.9" />
          <polygon points="16,6 20,8 16,10" fill="white" opacity="0.9" />
          <polygon points="16,12 20,14 16,16" fill="white" opacity="0.9" />
        </g>
        """

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 12
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :queue}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        assigns =
          assign(assigns,
            cx: assigns.element.x + assigns.element.width / 2,
            cy: assigns.element.y + assigns.element.height / 2 - 8
          )

        ~H"""
        <g class="canvas-element__icon" transform={"translate(#{@cx - 14}, #{@cy - 6})"}>
          <rect x="0" y="0" width="28" height="12" rx="2" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
          <line x1="7" y1="0" x2="7" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
          <line x1="14" y1="0" x2="14" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
          <line x1="21" y1="0" x2="21" y2="12" stroke="white" stroke-width="1" opacity="0.6" />
          <polygon points="-2,6 -6,3 -6,9" fill="white" opacity="0.7" />
          <polygon points="30,6 34,3 34,9" fill="white" opacity="0.7" />
        </g>
        """

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 12
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :cache}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        assigns =
          assign(assigns,
            cx: assigns.element.x + assigns.element.width / 2,
            cy: assigns.element.y + assigns.element.height / 2 - 8
          )

        ~H"""
        <g
          class="canvas-element__icon"
          transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-7, -10)"}
        >
          <polygon points="8,0 2,10 7,10 5,20 13,8 8,8" fill="white" opacity="0.9" />
        </g>
        """

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 12
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :network}} = assigns) do
    case IconCatalog.element_icon_name(assigns.element) do
      nil ->
        assigns =
          assign(assigns,
            cx: assigns.element.x + assigns.element.width / 2,
            cy: assigns.element.y + assigns.element.height / 2 - 6
          )

        ~H"""
        <g
          class="canvas-element__icon"
          transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
        >
          <circle cx="10" cy="10" r="9" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
          <ellipse cx="10" cy="10" rx="4" ry="9" fill="none" stroke="white" stroke-width="1" opacity="0.7" />
          <line x1="1" y1="7" x2="19" y2="7" stroke="white" stroke-width="0.8" opacity="0.6" />
          <line x1="1" y1="13" x2="19" y2="13" stroke="white" stroke-width="0.8" opacity="0.6" />
        </g>
        """

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + assigns.element.width / 2 - 14,
            icon_y: assigns.element.y + 12
          )

        ~H"""
        <.branded_icon icon={@icon} icon_x={@icon_x} icon_y={@icon_y} />
        """
    end
  end

  defp element_icon(%{element: %{type: :router}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g class="canvas-element__icon" transform={"translate(#{@cx - 20}, #{@cy - 20})"}>
      <circle cx="20" cy="20" r="8" fill="none" stroke="white" stroke-width="2.5" opacity="0.9" />
      <line x1="20" y1="0" x2="20" y2="12" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="14,6 20,0 26,6" fill="white" opacity="0.9" />
      <line x1="20" y1="28" x2="20" y2="40" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="14,34 20,40 26,34" fill="white" opacity="0.9" />
      <line x1="0" y1="20" x2="12" y2="20" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="6,14 0,20 6,26" fill="white" opacity="0.9" />
      <line x1="28" y1="20" x2="40" y2="20" stroke="white" stroke-width="2.5" opacity="0.9" />
      <polygon points="34,14 40,20 34,26" fill="white" opacity="0.9" />
    </g>
    """
  end

  defp element_icon(%{element: %{type: :canvas}} = assigns) do
    assigns =
      assign(assigns,
        cx: assigns.element.x + assigns.element.width / 2,
        cy: assigns.element.y + assigns.element.height / 2 - 10
      )

    ~H"""
    <g
      class="canvas-element__icon"
      transform={"translate(#{@cx}, #{@cy}) scale(1.4) translate(-10, -10)"}
    >
      <rect x="4" y="0" width="16" height="12" rx="1.5" fill="none" stroke="white" stroke-width="1.2" opacity="0.5" />
      <rect x="2" y="3" width="16" height="12" rx="1.5" fill="none" stroke="white" stroke-width="1.2" opacity="0.7" />
      <rect x="0" y="6" width="16" height="12" rx="1.5" fill="none" stroke="white" stroke-width="1.2" opacity="0.9" />
      <line x1="3" y1="10" x2="10" y2="10" stroke="white" stroke-width="0.8" opacity="0.5" />
      <line x1="3" y1="13" x2="8" y2="13" stroke="white" stroke-width="0.8" opacity="0.5" />
    </g>
    """
  end

  defp element_icon(assigns), do: ~H""

  defp element_badge_icon(%{element: %{type: type}} = assigns) when type in [:server, :router] do
    case IconCatalog.badge_icon_name(assigns.element) do
      nil ->
        ~H""

      icon ->
        assigns =
          assign(assigns,
            icon: icon,
            icon_x: assigns.element.x + 6,
            icon_y: assigns.element.y + 6
          )

        ~H"""
        <rect
          x={@icon_x - 2}
          y={@icon_y - 2}
          width="24"
          height="24"
          rx="5"
          ry="5"
          fill="#ffffff"
          opacity="0.98"
        />
        <.iconify_svg icon={@icon} x={@icon_x + 1} y={@icon_y + 1} size={20} />
        """
    end
  end

  defp element_badge_icon(assigns), do: ~H""

  attr(:icon, :string, required: true)
  attr(:icon_x, :float, required: true)
  attr(:icon_y, :float, required: true)

  defp branded_icon(assigns) do
    ~H"""
    <rect
      x={@icon_x - 4}
      y={@icon_y - 4}
      width="36"
      height="36"
      rx="10"
      ry="10"
      fill="#ffffff"
      opacity="0.96"
    />
    <.iconify_svg icon={@icon} x={@icon_x} y={@icon_y} size={28} />
    """
  end

  attr(:icon, :string, required: true)
  attr(:x, :float, required: true)
  attr(:y, :float, required: true)
  attr(:size, :any, required: true)

  defp iconify_svg(assigns) do
    assigns = assign(assigns, src: icon_image_src(assigns.icon))

    ~H"""
    <image
      :if={@src}
      href={@src}
      x={@x}
      y={@y}
      width={@size}
      height={@size}
      preserveAspectRatio="xMidYMid meet"
    />
    """
  end

  # Iconify.prepare raises when an icon isn't pre-generated and the
  # @iconify/json npm assets aren't installed; that must never take the
  # LiveView down. Failures are cached as nil (logged once per icon) and
  # the element renders without an icon.
  # Direct static paths ("/...") and data URIs bypass Iconify entirely.
  defp icon_image_src("/" <> _ = path), do: path
  defp icon_image_src("data:" <> _ = src), do: src

  defp icon_image_src(icon) do
    key = {__MODULE__, :icon_image_src, icon}

    case :persistent_term.get(key, :missing) do
      :missing ->
        src =
          try do
            case Iconify.prepare(%{icon: icon, __changed__: nil}, mode: :img) do
              {:img, _fun, %{src: src}} -> src
              _other -> nil
            end
          rescue
            e ->
              Logger.warning(
                "TimelessCanvas: cannot render icon #{inspect(icon)} " <>
                  "(#{Exception.message(e)}); rendering without an icon. " <>
                  "Pre-generate icon assets or install @iconify/json to fix."
              )

              nil
          end

        :persistent_term.put(key, src)
        src

      src ->
        src
    end
  end

  defp bump_render_stat(key, delta) do
    Process.put(key, (Process.get(key) || 0) + delta)
  end

  # --- Connection component ---

  attr(:connection, :map, required: true)
  attr(:source, :map, required: true)
  attr(:target, :map, required: true)
  attr(:selected, :boolean, default: false)

  def canvas_connection(assigns) do
    assigns =
      assign(assigns,
        x1: assigns.source.x + assigns.source.width / 2,
        y1: assigns.source.y + assigns.source.height / 2,
        x2: assigns.target.x + assigns.target.width / 2,
        y2: assigns.target.y + assigns.target.height / 2,
        dash: dash_for_style(assigns.connection.style)
      )

    ~H"""
    <g
      class={"canvas-connection#{if @selected, do: " canvas-connection--selected", else: ""}"}
      data-connection-id={@connection.id}
    >
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke="transparent"
        stroke-width="12"
        class="canvas-connection__hit"
      />
      <line
        x1={@x1}
        y1={@y1}
        x2={@x2}
        y2={@y2}
        stroke={@connection.color}
        stroke-width="2"
        stroke-dasharray={@dash}
        class="canvas-connection__line"
      />
      <text
        :if={@connection.label != ""}
        x={(@x1 + @x2) / 2}
        y={(@y1 + @y2) / 2 - 8}
        text-anchor="middle"
        class="canvas-connection__label"
      >
        {@connection.label}
      </text>
    </g>
    """
  end

  # --- Log/Trace stream helpers ---

  defp log_level_color(:error), do: "#ef4444"
  defp log_level_color(:warning), do: "#f59e0b"
  defp log_level_color(:info), do: "#22c55e"
  defp log_level_color(:debug), do: "#94a3b8"
  defp log_level_color(_), do: "#94a3b8"

  defp format_log_entry(entry) do
    ts = format_stream_timestamp(entry.timestamp)
    level = entry.level |> to_string() |> String.upcase() |> String.slice(0, 4)
    "#{ts} [#{level}] #{entry.message}"
  end

  defp format_stream_timestamp(ts) when is_integer(ts) do
    case normalize_stream_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M:%S")
      :error -> "??:??:??"
    end
  end

  defp format_stream_timestamp(_), do: "??:??:??"

  defp normalize_stream_timestamp(ts) when ts > 10_000_000_000_000_000 do
    DateTime.from_unix(ts, :nanosecond)
  end

  defp normalize_stream_timestamp(ts) when ts > 10_000_000_000_000 do
    DateTime.from_unix(ts, :microsecond)
  end

  defp normalize_stream_timestamp(ts) when ts > 10_000_000_000 do
    DateTime.from_unix(ts, :millisecond)
  end

  defp normalize_stream_timestamp(ts) when ts > 0 do
    DateTime.from_unix(ts, :second)
  end

  defp normalize_stream_timestamp(_), do: :error

  defp duration_color(nil), do: "#94a3b8"

  defp duration_color(duration_ns) when is_integer(duration_ns) do
    ms = duration_ns / 1_000_000

    cond do
      ms < 100 -> "#22c55e"
      ms < 500 -> "#f59e0b"
      true -> "#ef4444"
    end
  end

  defp duration_color(_), do: "#94a3b8"

  defp format_duration(nil), do: "?ms"

  defp format_duration(duration_ns) when is_integer(duration_ns) do
    ms = duration_ns / 1_000_000

    cond do
      ms < 1 -> "#{Float.round(ms, 2)}ms"
      ms < 1000 -> "#{Float.round(ms, 1)}ms"
      true -> "#{Float.round(ms / 1000, 1)}s"
    end
  end

  defp format_duration(_), do: "?ms"

  defp span_status_color(:ok), do: "#22c55e"
  defp span_status_color(:error), do: "#ef4444"
  defp span_status_color(_), do: "#94a3b8"

  defp span_status_label(:ok), do: "OK"
  defp span_status_label(:error), do: "ERR"
  defp span_status_label(_), do: "---"

  # --- Graph push payloads ---
  #
  # Graph internals are no longer rendered through HEEx: the compact and
  # expanded graph bodies only ship a static frame plus an empty
  # phx-update="ignore" container, and CanvasLive pushes these payloads
  # ("graph:data" / "graph:expanded") for the Canvas JS hook to render.
  # All scaling math stays here, next to the geometry helpers it shares
  # with the old server-rendered path.

  @doc """
  `push_event("graph:data", ...)` payload for a compact graph element.

  `graph_data` is the element's entry in the `graph_data` assign: a
  point list (newest first, as produced by `DataQueries`) or `:error`
  when the backend query failed. The payload carries an additive
  `status` field ("ok" | "empty" | "error") plus a `status_pos` so the
  client hook can draw a distinct "no data" / "data unavailable" state.
  """
  def compact_graph_payload(element, graph_data, unit) do
    {status, points_newest_first} = graph_data_status(graph_data)
    points = Enum.reverse(points_newest_first)
    meta = element.meta || %{}

    {plot_x, plot_y, plot_w, plot_h, min_val, _max_val, val_range, y_ticks, x_ticks,
     polyline_points} = compact_graph_geometry(element, points, meta)

    grid =
      Enum.map(y_ticks, fn tick ->
        y = plot_y + (1 - (tick - min_val) / val_range) * plot_h
        %{x1: plot_x, y1: y, x2: plot_x + plot_w, y2: y}
      end)

    y_labels =
      Enum.map(y_ticks, fn tick ->
        %{
          x: plot_x - 3,
          y: compact_y_tick_label_y(tick, plot_y, plot_h, min_val, val_range),
          text: MetricFormatter.format(tick / 1.0, unit)
        }
      end)

    x_labels =
      Enum.map(x_ticks, fn {ts, frac} ->
        %{
          x: compact_x_tick_label_x(frac, plot_x, plot_w),
          y: element.y + element.height - 2,
          text: format_time(ts)
        }
      end)

    value =
      case points_newest_first do
        [{_ts, val} | _] -> MetricFormatter.format(val / 1.0, unit)
        _ -> nil
      end

    %{
      id: element.id,
      kind: "compact",
      color: element.color,
      status: status,
      status_pos: %{x: plot_x + plot_w / 2, y: plot_y + plot_h / 2 + 2},
      points: polyline_points,
      raw: raw_points(points),
      grid: grid,
      y_labels: y_labels,
      x_labels: x_labels,
      value: value,
      value_pos: %{x: element.x + element.width - 18, y: element.y + 10}
    }
  end

  @doc """
  `push_event("graph:expanded", ...)` payload for the expanded graph.

  `graph_data` is the `expanded_graph_data` assign (newest point first,
  or `:error` — see `compact_graph_payload/3`). Mirrors the geometry the
  expanded body used to render server-side, at 2x element size.
  """
  def expanded_graph_payload(element, graph_data, unit) do
    {status, points_newest_first} = graph_data_status(graph_data)
    render_w = element.width * 2
    render_h = element.height * 2
    pad_left = 50
    pad_right = 10
    pad_top = 30
    pad_bottom = 20
    plot_x = element.x + pad_left
    plot_y = element.y + pad_top
    plot_w = render_w - pad_left - pad_right
    plot_h = render_h - pad_top - pad_bottom

    points = Enum.reverse(points_newest_first)
    meta = element.meta || %{}

    {min_val, max_val, y_ticks, polyline_str, area_str, current_val} =
      if points != [] do
        {min_p, max_p} = Enum.min_max_by(points, &elem(&1, 1))
        data_min = elem(min_p, 1)
        data_max = elem(max_p, 1)
        raw_min = graph_bound_min(meta, data_min)
        raw_max = parse_graph_bound(meta["y_max"], data_max)
        val_range = max(raw_max - raw_min, 0.001)
        padded_min = raw_min - val_range * 0.05
        padded_max = raw_max + val_range * 0.05
        padded_range = padded_max - padded_min

        ticks = y_axis_ticks(raw_min, raw_max)
        count = length(points)

        poly =
          points
          |> Enum.with_index()
          |> Enum.map(fn {{_ts, val}, i} ->
            clamped = max(min(val, raw_max), raw_min)
            x = plot_x + i / max(count - 1, 1) * plot_w
            y = plot_y + (1 - (clamped - padded_min) / padded_range) * plot_h
            {Float.round(x, 1), Float.round(y, 1)}
          end)

        polyline_str = Enum.map_join(poly, " ", fn {x, y} -> "#{x},#{y}" end)

        {first_x, _} = List.first(poly)
        {last_x, _} = List.last(poly)
        bottom_y = plot_y + plot_h
        area_str = polyline_str <> " #{last_x},#{bottom_y} #{first_x},#{bottom_y}"

        {_ts, cur} = List.last(points)

        {padded_min, padded_max, ticks, polyline_str, area_str,
         MetricFormatter.format(cur / 1.0, unit)}
      else
        {0, 1, [0.0, 0.25, 0.5, 0.75, 1.0], "", "", nil}
      end

    x_ticks =
      if points != [] do
        {first_ts, _} = List.first(points)
        {last_ts, _} = List.last(points)
        x_axis_ticks(first_ts, last_ts)
      else
        []
      end

    val_range = max(max_val - min_val, 0.001)

    grid =
      Enum.map(y_ticks, fn tick ->
        y = plot_y + (1 - (tick - min_val) / val_range) * plot_h
        %{x1: plot_x, y1: y, x2: plot_x + plot_w, y2: y}
      end)

    y_labels =
      Enum.map(y_ticks, fn tick ->
        %{
          x: plot_x - 4,
          y: plot_y + (1 - (tick - min_val) / val_range) * plot_h + 3,
          text: MetricFormatter.format(tick / 1.0, unit)
        }
      end)

    x_labels =
      Enum.map(x_ticks, fn {ts, frac} ->
        %{x: plot_x + frac * plot_w, y: plot_y + plot_h + 14, text: format_time(ts)}
      end)

    %{
      id: element.id,
      kind: "expanded",
      color: element.color,
      status: status,
      status_pos: %{x: plot_x + plot_w / 2, y: plot_y + plot_h / 2},
      points: polyline_str,
      area: area_str,
      raw: raw_points(points),
      grid: grid,
      y_labels: y_labels,
      x_labels: x_labels,
      value: current_val,
      # Absolute coordinates of the legend value text (the legend chrome
      # itself is server-rendered).
      value_pos: %{x: element.x + render_w - 52, y: element.y + 13}
    }
  end

  # Split the graph_data assign shape into {status, point_list}: a down
  # backend (:error) and an empty series ([]) must render distinctly.
  defp graph_data_status(:error), do: {"error", []}
  defp graph_data_status([]), do: {"empty", []}
  defp graph_data_status(points) when is_list(points), do: {"ok", points}

  # ~4.8px per char at font-size 8 monospace; reserve 56px on the right
  # for the pushed current-value text (~8 chars + its 18px inset).
  defp compact_title_budget(width, title_offset) do
    max(trunc((width - title_offset - 56) / 4.8), 4)
  end

  defp truncate_text(text, max_chars) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max(max_chars - 1, 1)) <> "…"
    else
      text
    end
  end

  # JSON-safe [[unix_ms, value], ...] for the JS tooltip cache.
  defp raw_points(points_asc) do
    Enum.map(points_asc, fn {ts, val} -> [ts_to_ms(ts), val] end)
  end

  defp ts_to_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp ts_to_ms(ms) when is_integer(ms), do: ms
  defp ts_to_ms(_), do: 0

  # --- Graph detail helpers ---

  defp format_time(ts) do
    ms =
      case ts do
        %DateTime{} -> DateTime.to_unix(ts, :millisecond)
        ms when is_integer(ms) -> ms
        _ -> 0
      end

    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp y_axis_ticks(min_val, max_val) do
    range = max_val - min_val

    if range == 0 do
      [min_val]
    else
      raw_step = range / 4
      magnitude = :math.pow(10, floor(:math.log10(raw_step)))

      nice_step =
        cond do
          raw_step / magnitude < 1.5 -> magnitude
          raw_step / magnitude < 3.5 -> 2 * magnitude
          raw_step / magnitude < 7.5 -> 5 * magnitude
          true -> 10 * magnitude
        end

      start = Float.floor(min_val / nice_step) * nice_step
      stop = Float.ceil(max_val / nice_step) * nice_step

      ticks =
        Stream.iterate(start, &(&1 + nice_step))
        |> Enum.take_while(&(&1 <= stop + nice_step * 0.01))

      Enum.take(ticks, 7)
    end
  end

  defp x_axis_ticks(first_ts, last_ts) do
    first_ms =
      case first_ts do
        %DateTime{} -> DateTime.to_unix(first_ts, :millisecond)
        ms when is_integer(ms) -> ms
        _ -> 0
      end

    last_ms =
      case last_ts do
        %DateTime{} -> DateTime.to_unix(last_ts, :millisecond)
        ms when is_integer(ms) -> ms
        _ -> 0
      end

    span_ms = max(last_ms - first_ms, 1)
    num_ticks = 6

    for i <- 0..(num_ticks - 1) do
      frac = i / (num_ticks - 1)
      ts_ms = round(first_ms + frac * span_ms)
      {DateTime.from_unix!(ts_ms, :millisecond), frac}
    end
  end

  # Plot box shared by the static clipPath (HEEx) and the pushed
  # geometry (compact_graph_payload/3).
  defp compact_plot_box(element) do
    {element.x + 28, element.y + 20, max(element.width - 32, 1), max(element.height - 34, 1)}
  end

  defp compact_graph_geometry(element, [], _meta) do
    {plot_x, plot_y, plot_w, plot_h} = compact_plot_box(element)

    {plot_x, plot_y, plot_w, plot_h, 0.0, 1.0, 1.0, [], [], ""}
  end

  defp compact_graph_geometry(element, points, meta) do
    {plot_x, plot_y, plot_w, plot_h} = compact_plot_box(element)

    {min_p, max_p} = Enum.min_max_by(points, &elem(&1, 1))
    data_min = elem(min_p, 1)
    data_max = elem(max_p, 1)
    min_val = graph_bound_min(meta, data_min)
    max_val = parse_graph_bound(meta["y_max"], data_max)
    val_range = max(max_val - min_val, 0.001)

    polyline_points =
      points
      |> Enum.with_index()
      |> Enum.map(fn {{_ts, val}, i} ->
        x = plot_x + i / max(length(points) - 1, 1) * plot_w
        clamped = max(min(val, max_val), min_val)
        y = plot_y + (1 - (clamped - min_val) / val_range) * plot_h
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)
      |> Enum.join(" ")

    y_ticks =
      min_val
      |> y_axis_ticks(max_val)
      |> compact_tick_subset(3)

    x_ticks =
      points
      |> List.first()
      |> elem(0)
      |> x_axis_ticks(elem(List.last(points), 0))
      |> compact_tick_subset(3)

    {plot_x, plot_y, plot_w, plot_h, min_val, max_val, val_range, y_ticks, x_ticks,
     polyline_points}
  end

  defp compact_y_tick_label_y(tick, plot_y, plot_h, min_val, val_range) do
    raw_y = plot_y + (1 - (tick - min_val) / val_range) * plot_h + 3
    raw_y |> max(plot_y + 6) |> min(plot_y + plot_h - 1)
  end

  defp compact_x_tick_label_x(frac, plot_x, plot_w) do
    raw_x = plot_x + frac * plot_w
    raw_x |> max(plot_x + 12) |> min(plot_x + plot_w - 12)
  end

  defp compact_tick_subset(ticks, max_count) when length(ticks) <= max_count, do: ticks

  defp compact_tick_subset(ticks, max_count) do
    last_index = length(ticks) - 1

    0..(max_count - 1)
    |> Enum.map(fn idx -> round(idx * last_index / max(max_count - 1, 1)) end)
    |> Enum.uniq()
    |> Enum.map(&Enum.at(ticks, &1))
  end

  defp dash_for_style(:dashed), do: "8 4"
  defp dash_for_style(:dotted), do: "3 3"
  defp dash_for_style(_), do: ""

  # --- Timeline Bar ---

  attr(:timeline_mode, :atom, required: true)
  attr(:timeline_time, :any, default: nil)
  attr(:timeline_span, :integer, default: 3600)
  attr(:timeline_range, :any, default: 86_400)
  attr(:timeline_data_range, :any, default: nil)

  def timeline_bar(assigns) do
    now_ms = System.system_time(:millisecond)

    span_ms = assigns.timeline_span * 1000
    half_span = div(span_ms, 2)

    {window_end_ms, is_live} =
      case assigns.timeline_time do
        nil -> {now_ms, true}
        %DateTime{} = t -> {DateTime.to_unix(t, :millisecond), false}
      end

    {slider_min, slider_max} =
      timeline_slider_bounds(
        assigns.timeline_data_range,
        assigns.timeline_range,
        window_end_ms,
        span_ms,
        half_span,
        is_live,
        now_ms
      )

    window_center_ms = window_end_ms - half_span
    window_ratio = span_ms / max(slider_max - slider_min, 1)

    slider_value =
      window_center_ms
      |> max(slider_min + half_span)
      |> min(slider_max - half_span)

    assigns =
      assign(assigns,
        slider_min: slider_min,
        slider_max: slider_max,
        slider_value: slider_value,
        window_ratio: min(window_ratio, 1.0),
        is_live: is_live,
        track_start: format_track_ts(slider_min),
        track_end: format_track_ts(slider_max),
        # Persistent readout of the viewed (window-center) time while
        # scrubbed into history — same instant the drag bubble shows.
        historical_readout: if(!is_live, do: format_readout_ts(window_center_ms))
      )

    ~H"""
    <div class="timeline-bar">
      <span class="timeline-bar__time timeline-bar__time--start" title="Earliest time in track">
        {@track_start}
      </span>

      <div
        id="timeline-slider"
        phx-hook="TimelineSlider"
        phx-update="ignore"
        data-min={@slider_min}
        data-max={@slider_max}
        data-value={@slider_value}
        data-window-ratio={@window_ratio}
        data-live={to_string(@is_live)}
        class="timeline-bar__track"
        tabindex="0"
      >
        <div class="timeline-bar__density"></div>
        <div class="timeline-bar__ticks"></div>
        <div class="timeline-bar__window"></div>
        <div class="timeline-bar__thumb"></div>
        <div class="timeline-bar__thumb-hit"></div>
        <div class="timeline-bar__bubble" hidden></div>
        <div class={"timeline-bar__live-dot#{if @is_live, do: " timeline-bar__live-dot--active", else: ""}"}></div>
      </div>

      <span class="timeline-bar__time timeline-bar__time--end" title="Latest time in track">
        {@track_end}
      </span>

      <span
        :if={@timeline_mode == :historical}
        class="timeline-bar__readout"
        title="Currently viewed time"
      >
        {@historical_readout}
      </span>
      <button
        :if={@timeline_mode == :historical}
        phx-click="timeline:go_live"
        class="timeline-bar__go-live"
        title="Return to live data"
      >
        Go Live
      </button>
    </div>
    """
  end

  defp format_readout_ts(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%b %-d %H:%M:%S")
  end

  defp format_track_ts(ms) do
    dt = DateTime.from_unix!(ms, :millisecond)
    today = Date.utc_today()

    if Date.compare(DateTime.to_date(dt), today) == :eq do
      Calendar.strftime(dt, "%H:%M")
    else
      Calendar.strftime(dt, "%b %-d %H:%M")
    end
  end

  defp timeline_slider_bounds(
         {data_start, data_end},
         :all,
         window_end_ms,
         _span_ms,
         _half_span,
         true,
         _now_ms
       )
       when is_struct(data_start, DateTime) and is_struct(data_end, DateTime) do
    data_start_ms = DateTime.to_unix(data_start, :millisecond)
    slider_max = max(window_end_ms, data_start_ms + 1)

    if slider_max > data_start_ms do
      {data_start_ms, slider_max}
    else
      {data_start_ms, data_start_ms + 1}
    end
  end

  defp timeline_slider_bounds(
         {data_start, data_end},
         :all,
         _window_end_ms,
         _span_ms,
         _half_span,
         false,
         _now_ms
       )
       when is_struct(data_start, DateTime) and is_struct(data_end, DateTime) do
    data_start_ms = DateTime.to_unix(data_start, :millisecond)
    data_end_ms = DateTime.to_unix(data_end, :millisecond)
    slider_max = max(data_end_ms, data_start_ms + 1)

    if slider_max > data_start_ms do
      {data_start_ms, slider_max}
    else
      {data_start_ms, data_start_ms + 1}
    end
  end

  defp timeline_slider_bounds(
         _timeline_data_range,
         :all,
         _window_end_ms,
         span_ms,
         _half_span,
         _is_live,
         now_ms
       ) do
    slider_range_ms = max(span_ms * 10, 86_400_000)
    {now_ms - slider_range_ms, now_ms}
  end

  defp timeline_slider_bounds(
         _timeline_data_range,
         range_seconds,
         _window_end_ms,
         span_ms,
         _half_span,
         _is_live,
         now_ms
       )
       when is_integer(range_seconds) do
    slider_range_ms = max(range_seconds * 1000, span_ms)
    {now_ms - slider_range_ms, now_ms}
  end

  def timeline_span_options do
    [
      {900, "15m"},
      {3600, "1h"},
      {21600, "6h"},
      {43200, "12h"},
      {86400, "24h"}
    ]
  end

  def timeline_range_options do
    [
      {86_400, "24h"},
      {604_800, "7d"},
      {2_592_000, "30d"},
      {:all, "All"}
    ]
  end

  defp parse_graph_bound(nil, fallback), do: fallback
  defp parse_graph_bound("", fallback), do: fallback

  defp parse_graph_bound(str, fallback) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> fallback
    end
  end

  defp graph_bound_min(meta, data_min) when is_map(meta) do
    cond do
      explicit_nonzero_graph_bound?(meta["y_min"]) ->
        parse_graph_bound(meta["y_min"], data_min)

      counter_graph_series?(meta) ->
        data_min

      true ->
        parse_graph_bound(meta["y_min"], 0.0)
    end
  end

  defp explicit_nonzero_graph_bound?(nil), do: false
  defp explicit_nonzero_graph_bound?(""), do: false

  defp explicit_nonzero_graph_bound?(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} when parsed == 0.0 -> false
      {_nonzero, _} -> true
      :error -> false
    end
  end

  defp counter_graph_series?(meta) when is_map(meta) do
    case Map.get(meta, "type") do
      "counter32" -> true
      "counter64" -> true
      _ -> false
    end
  end
end

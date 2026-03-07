defmodule TimelessCanvas.Components.CanvasComponents do
  @moduledoc """
  SVG element and connection renderers for the canvas.
  """
  use Phoenix.Component

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.MetricFormatter

  attr :element, Element, required: true
  attr :selected, :boolean, default: false
  attr :graph_points, :string, default: ""
  attr :graph_value, :string, default: nil
  attr :stream_entries, :list, default: []
  attr :expanded_graph_id, :string, default: nil
  attr :expanded_graph_data, :list, default: []
  attr :metric_units, :map, default: %{}
  attr :text_value, :string, default: nil

  def canvas_element(assigns) do
    is_expanded = assigns.element.type == :graph and assigns.expanded_graph_id == assigns.element.id

    # When expanded, use larger dimensions
    {render_w, render_h} =
      if is_expanded do
        {assigns.element.width * 4, assigns.element.height * 5}
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
        graph_points={@graph_points}
        graph_value={@graph_value}
        stream_entries={@stream_entries}
        is_expanded={@is_expanded}
        expanded_graph_data={@expanded_graph_data}
        render_w={@render_w}
        render_h={@render_h}
        metric_units={@metric_units}
        text_value={@text_value}
      />
      <.element_icon element={@element} />
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
    level_filter = Map.get(assigns.element.meta, "level", "all")

    log_title =
      case assigns.element.label do
        nil -> "Logs"
        "" -> "Logs"
        label -> "#{label} | #{level_filter}"
      end

    max_rows = max(floor((assigns.element.height - 24) / 14), 1)
    rows = Enum.take(assigns.stream_entries, max_rows)

    assigns = assign(assigns, log_title: log_title, rows: rows)

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
        data-stream-entry={Jason.encode!(%{element_id: @element.id, index: i, type: "log"})}
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
      :if={@rows == []}
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2 + 4}
      text-anchor="middle"
      fill="#475569"
      font-size="9"
    >
      Waiting for logs...
    </text>
    """
  end

  defp element_body(%{element: %{type: :trace_stream}} = assigns) do
    service_filter = Map.get(assigns.element.meta, "service", "all")

    trace_title =
      case assigns.element.label do
        nil -> "Traces"
        "" -> "Traces"
        label -> "#{label} | #{service_filter}"
      end

    max_rows = max(floor((assigns.element.height - 24) / 14), 1)
    rows = Enum.take(assigns.stream_entries, max_rows)

    assigns = assign(assigns, trace_title: trace_title, rows: rows)

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
        data-stream-entry={Jason.encode!(%{element_id: @element.id, index: i, type: "trace"})}
      />
      <text
        x={@element.x + 4}
        y={@element.y + 24 + i * 14}
        font-size="9"
        font-family="monospace"
        clip-path={"url(#trace-clip-#{@element.id})"}
        pointer-events="none"
      >
        <tspan fill="#e2e8f0">{span.name}</tspan>
        <tspan dx="6" fill={duration_color(span.duration_ns)}>
          {format_duration(span.duration_ns)}
        </tspan>
        <tspan dx="6" fill={span_status_color(span.status)}>{span_status_label(span.status)}</tspan>
      </text>
    </g>
    <text
      :if={@rows == []}
      x={@element.x + @element.width / 2}
      y={@element.y + @element.height / 2 + 4}
      text-anchor="middle"
      fill="#475569"
      font-size="9"
    >
      Waiting for traces...
    </text>
    """
  end

  defp element_body(%{element: %{type: :graph}, is_expanded: true} = assigns) do
    metric_name = Map.get(assigns.element.meta, "metric_name", "metric")
    unit = Map.get(assigns.metric_units, assigns.element.id)

    graph_title =
      case assigns.element.label do
        nil -> metric_name
        "" -> metric_name
        label -> "#{label} | #{metric_name}"
      end

    # Layout constants
    pad_left = 50
    pad_right = 10
    pad_top = 30
    pad_bottom = 20
    w = assigns.render_w
    h = assigns.render_h
    plot_x = assigns.element.x + pad_left
    plot_y = assigns.element.y + pad_top
    plot_w = w - pad_left - pad_right
    plot_h = h - pad_top - pad_bottom

    # Compute points, ticks, and polyline for expanded view
    points = Enum.reverse(assigns.expanded_graph_data)

    {min_val, max_val, y_ticks, polyline_points, area_points, tooltip_data, current_val} =
      if points != [] do
        {min_p, max_p} = Enum.min_max_by(points, &elem(&1, 1))
        raw_min = elem(min_p, 1)
        raw_max = elem(max_p, 1)
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
            x = plot_x + i / max(count - 1, 1) * plot_w
            y = plot_y + (1 - (val - padded_min) / padded_range) * plot_h
            {Float.round(x, 1), Float.round(y, 1)}
          end)

        polyline_str = Enum.map_join(poly, " ", fn {x, y} -> "#{x},#{y}" end)

        {first_x, _} = List.first(poly)
        {last_x, _} = List.last(poly)
        bottom_y = plot_y + plot_h

        area_str =
          polyline_str <>
            " #{last_x},#{bottom_y} #{first_x},#{bottom_y}"

        tooltip =
          Enum.map(points, fn {ts, val} ->
            t_ms =
              case ts do
                %DateTime{} -> DateTime.to_unix(ts, :millisecond)
                ms when is_integer(ms) -> ms
                _ -> 0
              end

            %{"t" => t_ms, "v" => val}
          end)

        {_ts, cur} = List.last(points)
        {padded_min, padded_max, ticks, polyline_str, area_str, tooltip, MetricFormatter.format(cur / 1.0, unit)}
      else
        {0, 1, [0.0, 0.25, 0.5, 0.75, 1.0], "", "", [], nil}
      end

    # X-axis time ticks
    x_ticks =
      if points != [] do
        {first_ts, _} = List.first(points)
        {last_ts, _} = List.last(points)
        x_axis_ticks(first_ts, last_ts)
      else
        []
      end

    val_range = max(max_val - min_val, 0.001)

    assigns =
      assign(assigns,
        graph_title: graph_title,
        metric_name: metric_name,
        unit: unit,
        plot_x: plot_x,
        plot_y: plot_y,
        plot_w: plot_w,
        plot_h: plot_h,
        min_val: min_val,
        max_val: max_val,
        val_range: val_range,
        y_ticks: y_ticks,
        x_ticks: x_ticks,
        polyline_points: polyline_points,
        area_points: area_points,
        tooltip_data: Jason.encode!(tooltip_data),
        current_val: current_val
      )

    ~H"""
    <g data-expanded="true" data-points={@tooltip_data}>
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

      <%!-- Gridlines --%>
      <line
        :for={tick <- @y_ticks}
        x1={@plot_x}
        y1={@plot_y + (1 - (tick - @min_val) / @val_range) * @plot_h}
        x2={@plot_x + @plot_w}
        y2={@plot_y + (1 - (tick - @min_val) / @val_range) * @plot_h}
        stroke="#1e293b"
        stroke-width="0.5"
        stroke-dasharray="4 3"
      />

      <%!-- Y-axis labels --%>
      <text
        :for={tick <- @y_ticks}
        x={@plot_x - 4}
        y={@plot_y + (1 - (tick - @min_val) / @val_range) * @plot_h + 3}
        text-anchor="end"
        fill="#64748b"
        font-size="8"
        font-family="monospace"
      >
        {MetricFormatter.format(tick / 1.0, @unit)}
      </text>

      <%!-- X-axis labels --%>
      <text
        :for={{ts, frac} <- @x_ticks}
        x={@plot_x + frac * @plot_w}
        y={@plot_y + @plot_h + 14}
        text-anchor="middle"
        fill="#64748b"
        font-size="8"
        font-family="monospace"
      >
        {format_time(ts)}
      </text>

      <%!-- Area fill --%>
      <polygon
        :if={@area_points != ""}
        points={@area_points}
        fill={@element.color}
        opacity="0.12"
        clip-path={"url(#graph-clip-#{@element.id})"}
      />

      <%!-- Graph line --%>
      <polyline
        :if={@polyline_points != ""}
        points={@polyline_points}
        fill="none"
        stroke={@element.color}
        stroke-width="1.5"
        stroke-linejoin="round"
        stroke-linecap="round"
        class="canvas-graph__line"
        clip-path={"url(#graph-clip-#{@element.id})"}
      />

      <%!-- Title --%>
      <text
        x={@element.x + 8}
        y={@element.y + 14}
        fill="#94a3b8"
        font-size="10"
        clip-path={"url(#graph-clip-#{@element.id})"}
      >
        {@graph_title}
      </text>

      <%!-- Legend --%>
      <g transform={"translate(#{@element.x + @render_w - 8}, #{@element.y + 10})"}>
        <rect x="-60" y="-6" width="60" height="12" rx="3" fill="#1e293b" opacity="0.8" />
        <rect x="-56" y="-2" width="8" height="4" rx="1" fill={@element.color} />
        <text x="-44" y="3" fill="#e2e8f0" font-size="7" font-family="monospace">
          {@current_val || "---"}
        </text>
      </g>
    </g>
    """
  end

  defp element_body(%{element: %{type: :graph}} = assigns) do
    metric_name = Map.get(assigns.element.meta, "metric_name", "metric")
    unit = Map.get(assigns.metric_units, assigns.element.id)

    base_title =
      case assigns.element.label do
        nil -> metric_name
        "" -> metric_name
        label -> "#{label} | #{metric_name}"
      end

    graph_title = if unit, do: "#{base_title} (#{unit})", else: base_title

    assigns = assign(assigns, graph_title: graph_title)

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
    <polyline
      :if={@graph_points != ""}
      points={@graph_points}
      fill="none"
      stroke={@element.color}
      stroke-width="1.5"
      stroke-linejoin="round"
      stroke-linecap="round"
      class="canvas-graph__line"
    />
    <clipPath id={"graph-clip-#{@element.id}"}>
      <rect x={@element.x} y={@element.y} width={@element.width} height={@element.height} />
    </clipPath>
    <text
      x={@element.x + 4}
      y={@element.y + 10}
      class="canvas-graph__title"
      fill="#94a3b8"
      font-size="8"
      clip-path={"url(#graph-clip-#{@element.id})"}
    >
      {@graph_title}
    </text>
    <text
      :if={@graph_value}
      x={@element.x + @element.width - 18}
      y={@element.y + 10}
      text-anchor="end"
      class="canvas-graph__title"
      fill={@element.color}
      font-size="8"
    >
      {@graph_value}
    </text>
    """
  end

  defp element_body(%{element: %{type: :text_series}} = assigns) do
    metric_name = Map.get(assigns.element.meta, "metric_name", "metric")

    title =
      case assigns.element.label do
        nil -> metric_name
        "" -> metric_name
        label -> "#{label} | #{metric_name}"
      end

    display_value = assigns.text_value || "\u2014"
    assigns = assign(assigns, title: title, display_value: display_value)

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
      fill={@element.color} font-size="12"
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
  defp element_icon(%{element: %{type: :database}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :graph}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :text}} = assigns), do: ~H""
  defp element_icon(%{element: %{type: :text_series}} = assigns), do: ~H""

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
  end

  defp element_icon(%{element: %{type: :load_balancer}} = assigns) do
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
  end

  defp element_icon(%{element: %{type: :queue}} = assigns) do
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
  end

  defp element_icon(%{element: %{type: :cache}} = assigns) do
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
  end

  defp element_icon(%{element: %{type: :network}} = assigns) do
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

  # --- Connection component ---

  attr :connection, :map, required: true
  attr :source, :map, required: true
  attr :target, :map, required: true
  attr :selected, :boolean, default: false

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
    ts =
      case entry.timestamp do
        ts when is_integer(ts) ->
          ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")

        _ ->
          "??:??:??"
      end

    level = entry.level |> to_string() |> String.upcase() |> String.slice(0, 4)
    "#{ts} [#{level}] #{entry.message}"
  end

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

  defp dash_for_style(:dashed), do: "8 4"
  defp dash_for_style(:dotted), do: "3 3"
  defp dash_for_style(_), do: ""

  # --- Timeline Bar ---

  attr :timeline_mode, :atom, required: true
  attr :timeline_time, :any, default: nil
  attr :timeline_span, :integer, default: 300
  attr :timeline_data_range, :any, default: nil

  @span_options [
    {300, "5m"},
    {900, "15m"},
    {3600, "1h"},
    {21600, "6h"},
    {43200, "12h"},
    {86400, "24h"}
  ]

  def timeline_bar(assigns) do
    now_ms = System.system_time(:millisecond)

    {data_start_ms, data_end_ms} =
      case assigns.timeline_data_range do
        {s, e} -> {DateTime.to_unix(s, :millisecond), DateTime.to_unix(e, :millisecond)}
        _ -> {now_ms - 86_400_000, now_ms}
      end

    span_ms = assigns.timeline_span * 1000
    half_span = div(span_ms, 2)
    slider_min = data_start_ms + half_span
    slider_max = max(data_end_ms - half_span, slider_min + 60_000)

    {window_end_ms, is_live} =
      case assigns.timeline_time do
        nil -> {now_ms, true}
        %DateTime{} = t -> {DateTime.to_unix(t, :millisecond), false}
      end

    window_center_ms = window_end_ms - half_span
    window_start_ms = window_end_ms - span_ms
    window_ratio = span_ms / max(slider_max - slider_min, 1)

    assigns =
      assign(assigns,
        span_options: @span_options,
        slider_min: slider_min,
        slider_max: slider_max,
        slider_value: min(window_center_ms, slider_max),
        window_ratio: min(window_ratio, 1.0),
        is_live: is_live,
        window_start: format_ts(window_start_ms),
        window_end: format_ts(window_end_ms)
      )

    ~H"""
    <div class="timeline-bar">
      <form phx-change="timeline:change" phx-submit="timeline:change">
        <select
          name="span"
          class="timeline-bar__speed"
        >
          <option
            :for={{secs, label} <- @span_options}
            value={secs}
            selected={@timeline_span == secs}
          >
            {label}
          </option>
        </select>
      </form>

      <span class="timeline-bar__time">{@window_start}</span>

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
        <div class="timeline-bar__window"></div>
        <div class="timeline-bar__thumb"></div>
        <div class={"timeline-bar__live-dot#{if @is_live, do: " timeline-bar__live-dot--active", else: ""}"}></div>
      </div>

      <span class="timeline-bar__time">{@window_end}</span>
    </div>
    """
  end

  defp format_ts(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end
end

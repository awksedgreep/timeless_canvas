defmodule TimelessCanvas.Web.CanvasLive do
  use TimelessCanvas.Web, :live_view

  alias TimelessCanvas.Canvas

  alias TimelessCanvas.Canvas.{
    ViewBox,
    History,
    Element,
    Connection,
    Serializer,
    VariableResolver
  }

  alias TimelessCanvas.DataSource.Manager, as: StatusManager
  alias TimelessCanvas.IconCatalog
  alias TimelessCanvas.StreamManager
  alias TimelessCanvas.MetricFormatter
  require Logger

  defp persistence, do: TimelessCanvas.persistence()
  defp auth, do: TimelessCanvas.auth()
  defp pubsub, do: TimelessCanvas.pubsub()

  @type_labels %{
    rect: "Rect",
    server: "Server",
    service: "Service",
    database: "Database",
    load_balancer: "LB",
    queue: "Queue",
    cache: "Cache",
    network: "Network",
    graph: "Graph",
    log_stream: "Logs",
    trace_stream: "Traces",
    canvas: "Canvas",
    text: "Text",
    text_series: "TextSeries"
  }

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    current_user = TimelessCanvas.current_user(socket)

    with {canvas_id, ""} <- Integer.parse(id_str),
         {:ok, record} <- persistence().get_canvas(canvas_id),
         :ok <- auth().authorize(current_user, record, :view) do
      can_edit = auth().authorize(current_user, record, :edit) == :ok
      is_owner = record.user_id == current_user.id || auth().admin?(current_user)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(pubsub(), StatusManager.status_topic())
        Phoenix.PubSub.subscribe(pubsub(), StatusManager.metric_topic())
        Phoenix.PubSub.subscribe(pubsub(), StreamManager.topic())
      end

      canvas =
        case Serializer.decode(record.data) do
          {:ok, c} -> c
          {:error, _} -> Canvas.new()
        end

      history = History.new(canvas)

      bindings = VariableResolver.bindings(canvas.variables)
      resolved_elements = VariableResolver.resolve_elements(canvas.elements, bindings)

      stream_data =
        if connected?(socket) and map_size(canvas.elements) > 0 do
          StatusManager.register_elements(Map.values(resolved_elements))
          register_stream_elements(resolved_elements)
        else
          %{}
        end

      breadcrumbs = persistence().breadcrumb_chain(canvas_id)

      pin_hosts = StatusManager.list_hosts()
      pin_ifnames = StatusManager.list_label_values("ifname") || []

      place_pins = %{
        "host" => %{"mode" => "none", "value" => List.first(pin_hosts) || ""},
        "ifname" => %{"mode" => "none", "value" => ""}
      }

      socket =
        assign(socket,
          history: history,
          canvas: canvas,
          selected_ids: MapSet.new(),
          mode: :select,
          place_host: nil,
          place_host_type: :server,
          place_kind: :host,
          connect_from: nil,
          canvas_name: record.name,
          canvas_id: canvas_id,
          user_id: current_user.id,
          can_edit: can_edit,
          is_owner: is_owner,
          show_share: false,
          renaming: false,
          page_title: record.name,
          breadcrumbs: breadcrumbs,
          timeline_mode: :live,
          timeline_time: nil,
          timeline_span: 3600,
          timeline_range: 86_400,
          timeline_data_range: nil,
          graph_data: %{},
          text_data: %{},
          stream_data: stream_data,
          clipboard: [],
          paste_offset: 20,
          expanded_graph_id: nil,
          expanded_graph_data: [],
          pre_expand_viewbox: nil,
          available_series: [],
          discovered_hosts: [],
          pin_hosts: pin_hosts,
          pin_ifnames: pin_ifnames,
          place_pins: place_pins,
          host_filter: "",
          stream_popover: nil,
          metric_units: %{},
          resolved_elements: resolved_elements,
          variable_options: build_variable_options(canvas.variables),
          show_add_variable: false,
          debug_counts: %{
            status_msgs: 0,
            metric_msgs: 0,
            text_metric_msgs: 0,
            stream_entry_msgs: 0,
            stream_span_msgs: 0
          }
        )
        |> refresh_data_range()
        |> maybe_seed_historical_timeline()
        |> refresh_discovered_hosts()
        |> refresh_pin_ifnames()
        |> fetch_metric_units()

      initial_time = socket.assigns.timeline_time || DateTime.utc_now()

      {:ok,
       socket
       |> fill_graph_data_at(initial_time)
       |> fill_text_data_at(initial_time)
       |> fill_stream_data_at(initial_time)
       |> push_density_update()
       |> schedule_graph_refresh()
       |> schedule_debug_report()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Canvas not found or access denied")
         |> redirect(to: socket.assigns.tc_base_path)}
    end
  end

  @max_graph_points 60
  @max_graph_points_expanded 300
  @max_stream_entries 50
  @base_viewbox_width 1200.0
  @min_zoom_percent 10
  @max_zoom_percent 190
  @debug_report_interval 30_000
  @default_graph_refresh_interval 2_000
  @profile_skip_stream_updates false

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(type_labels: @type_labels)
      |> assign(profile_hide_properties_panel: false)
      |> assign(profile_hide_canvas_scene: false)

    ~H"""
    <div class={"canvas-container#{if sole_selected_object(@selected_ids, @canvas) != nil, do: " canvas-container--panel-open", else: ""}"}>
      <div class="canvas-toolbar">
        <span class="canvas-toolbar__logo" title="Timeless">
          <svg
            width="28"
            height="16"
            viewBox="0 0 28 16"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M8 2C4.5 2 2 4.7 2 8s2.5 6 6 6c2.2 0 4-1.2 5.5-3L14 10.5l.5.5c1.5 1.8 3.3 3 5.5 3 3.5 0 6-2.7 6-6s-2.5-6-6-6c-2.2 0-4 1.2-5.5 3L14 5.5 13.5 5C12 3.2 10.2 2 8 2z"
              stroke="#6366f1"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </span>
        <span class="canvas-toolbar__sep"></span>
        <span :if={length(@breadcrumbs) > 1} class="canvas-breadcrumbs">
          <span :for={{crumb, i} <- Enum.with_index(Enum.drop(@breadcrumbs, -1))}>
            <span :if={i > 0} class="canvas-breadcrumbs__sep">/</span>
            <.link
              navigate={"#{@tc_base_path}/#{elem(crumb, 0)}"}
              class="canvas-breadcrumbs__link"
            >
              {elem(crumb, 1)}
            </.link>
          </span>
          <span class="canvas-breadcrumbs__sep">/</span>
        </span>
        <form
          :if={@renaming}
          phx-submit="save_name"
          phx-click-away="cancel_rename"
          class="canvas-toolbar__name-form"
        >
          <input
            type="text"
            name="name"
            value={@canvas_name}
            class="canvas-toolbar__name-input"
            autofocus
            phx-key="Escape"
            phx-keydown="cancel_rename"
          />
        </form>
        <span
          :if={!@renaming}
          class={"canvas-toolbar__name#{if @is_owner, do: " canvas-toolbar__name--editable", else: ""}"}
          phx-click={if @is_owner, do: "start_rename"}
        >
          {@canvas_name}
        </span>
        <span class="canvas-toolbar__sep"></span>
        <span :if={!@can_edit} class="canvas-toolbar__badge canvas-toolbar__badge--readonly">
          View Only
        </span>
        <button
          phx-click="toggle_mode"
          phx-value-mode="select"
          class={"canvas-toolbar__btn#{if @mode == :select, do: " canvas-toolbar__btn--active", else: ""}"}
          title="Select (Esc to deselect)"
        >
          Select
        </button>
        <button
          phx-click="toggle_mode"
          phx-value-mode="place"
          class={"canvas-toolbar__btn#{if @mode == :place, do: " canvas-toolbar__btn--active", else: ""}"}
          disabled={!@can_edit}
          title="Place elements"
        >
          Place
        </button>
        <button
          phx-click="toggle_mode"
          phx-value-mode="connect"
          class={"canvas-toolbar__btn#{if @mode == :connect, do: " canvas-toolbar__btn--active", else: ""}"}
          disabled={!@can_edit}
          title="Connect elements"
        >
          Connect
        </button>
        <span class="canvas-toolbar__sep"></span>

        <div :if={@mode == :place} class="canvas-type-palette">
          <select
            phx-change="set_host_type"
            name="host_type"
            class="canvas-toolbar__select"
          >
            <option
              :for={t <- ~w(server service database load_balancer queue cache router network)a}
              value={t}
              selected={t == @place_host_type}
            >
              {@type_labels[t]}
            </option>
          </select>
          <.host_combobox
            :if={@discovered_hosts != []}
            hosts={@discovered_hosts}
            selected={@place_host}
            filter={@host_filter}
          />
          <span :if={@discovered_hosts == []} class="canvas-toolbar__hint">
            No hosts discovered
          </span>
          <span class="canvas-toolbar__sep"></span>
          <button
            :for={kind <- ~w(rect canvas text text_series)a}
            phx-click="set_place_kind"
            phx-value-kind={kind}
            class={"canvas-toolbar__btn canvas-type-btn#{if @place_kind == kind, do: " canvas-toolbar__btn--active", else: ""}"}
            style={"border-bottom: 2px solid #{Element.defaults_for(kind).color}"}
          >
            {@type_labels[kind]}
          </button>
        </div>

        <span :if={@mode == :place} class="canvas-toolbar__sep"></span>

        <button
          phx-click="toggle_grid"
          class={"canvas-toolbar__btn#{if @canvas.grid_visible, do: " canvas-toolbar__btn--active", else: ""}"}
          title="Toggle grid"
        >
          Grid
        </button>
        <button
          phx-click="toggle_snap"
          class={"canvas-toolbar__btn#{if @canvas.snap_to_grid, do: " canvas-toolbar__btn--active", else: ""}"}
          title="Snap to grid"
        >
          Snap
        </button>
        <span class="canvas-toolbar__sep"></span>
        <button
          phx-click="canvas:undo"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || !History.can_undo?(@history)}
          title="Undo (Ctrl+Z)"
        >
          Undo
        </button>
        <button
          phx-click="canvas:redo"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || !History.can_redo?(@history)}
          title="Redo (Ctrl+Shift+Z)"
        >
          Redo
        </button>
        <span class="canvas-toolbar__sep"></span>
        <button
          phx-click="fit_to_content"
          class="canvas-toolbar__btn"
          disabled={map_size(@canvas.elements) == 0}
          title="Fit all elements in view"
        >
          Fit
        </button>
        <button
          id="canvas-copy-svg"
          type="button"
          phx-hook="CanvasDebugCopy"
          data-target="#canvas-svg"
          class="canvas-toolbar__btn"
          disabled={map_size(@canvas.elements) == 0}
          title="Copy the rendered canvas SVG to the clipboard"
        >
          Copy SVG
        </button>
        <button
          phx-click="send_to_back"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
          title="Send to back"
        >
          Back
        </button>
        <button
          phx-click="bring_to_front"
          class="canvas-toolbar__btn"
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
          title="Bring to front"
        >
          Front
        </button>
        <button
          phx-click="delete_selected"
          class="canvas-toolbar__btn canvas-toolbar__btn--danger"
          disabled={!@can_edit || MapSet.size(@selected_ids) == 0}
          title="Delete (Backspace)"
        >
          Delete
        </button>
        <span :if={@is_owner} class="canvas-toolbar__sep"></span>
        <button
          :if={@is_owner}
          phx-click="toggle_share"
          class={"canvas-toolbar__btn#{if @show_share, do: " canvas-toolbar__btn--active", else: ""}"}
        >
          Share
        </button>
      </div>

      <div class="canvas-var-bar">
        <div :for={{name, definition} <- @canvas.variables} class="canvas-var-item">
          <span class="canvas-var-label">${name}</span>
          <select phx-change="var:change" name={name} class="canvas-var-select">
            <option
              :for={opt <- Map.get(@variable_options, name, [])}
              value={opt}
              selected={opt == definition["current"]}
            >
              {opt}
            </option>
          </select>
          <button
            :if={@can_edit}
            phx-click="var:remove"
            phx-value-name={name}
            class="canvas-var-remove"
            title="Remove variable"
          >
            &times;
          </button>
        </div>
        <button
          :if={@can_edit && !@show_add_variable}
          phx-click="var:show_add"
          class="canvas-var-add-btn"
          title="Add label variable"
        >
          + Label
        </button>
        <form
          :if={@show_add_variable}
          phx-submit="var:add"
          class="canvas-var-add-form"
          autocomplete="off"
        >
          <input type="text" name="name" placeholder="label name (e.g. ifName)" class="canvas-var-input" autocomplete="off" required />
          <button type="submit" class="canvas-var-add-btn">Add</button>
          <button type="button" phx-click="var:cancel_add" class="canvas-var-remove">&times;</button>
        </form>
      </div>

      <div :if={@show_share && @is_owner} class="canvas-share-overlay">
        <.live_component
          module={TimelessCanvas.Web.CanvasShareComponent}
          id="canvas-share"
          canvas_id={@canvas_id}
        />
      </div>

      <svg
        id="canvas-svg"
        phx-hook="Canvas"
        viewBox={ViewBox.to_string(@canvas.view_box)}
        class="canvas-svg"
        data-mode={@mode}
        data-connect-from={@connect_from}
        data-grid-size={@canvas.grid_size}
      >
        <defs>
          <pattern
            id="grid-pattern"
            width={@canvas.grid_size}
            height={@canvas.grid_size}
            patternUnits="userSpaceOnUse"
          >
            <path
              d={"M #{@canvas.grid_size} 0 L 0 0 0 #{@canvas.grid_size}"}
              fill="none"
              stroke="var(--grid-color)"
              stroke-width="0.5"
            />
          </pattern>
        </defs>

        <rect
          :if={@canvas.grid_visible}
          x={@canvas.view_box.min_x - @canvas.view_box.width}
          y={@canvas.view_box.min_y - @canvas.view_box.height}
          width={@canvas.view_box.width * 3}
          height={@canvas.view_box.height * 3}
          fill="url(#grid-pattern)"
          class="canvas-grid"
        />

        <.shortcut_legend :if={!@profile_hide_canvas_scene} view_box={@canvas.view_box} />

        <.canvas_connection
          :if={!@profile_hide_canvas_scene}
          :for={{_id, conn} <- @canvas.connections}
          connection={conn}
          source={@canvas.elements[conn.source_id]}
          target={@canvas.elements[conn.target_id]}
          selected={conn.id in @selected_ids}
        />

        <.canvas_element
          :if={!@profile_hide_canvas_scene}
          :for={element <- sorted_elements(@resolved_elements, @expanded_graph_id)}
          :key={element.id}
          element={element}
          selected={element.id in @selected_ids}
          graph_points={graph_points_for(element, @graph_data)}
          graph_data_points={graph_data_points_for(element, @graph_data)}
          graph_value={graph_value_for(element, @graph_data, @metric_units)}
          stream_entries={stream_entries_for(element, @stream_data)}
          expanded_graph_id={@expanded_graph_id}
          expanded_graph_data={@expanded_graph_data}
          metric_units={@metric_units}
          text_value={text_value_for(element, @text_data)}
        />

        <.stream_popover :if={!@profile_hide_canvas_scene && @stream_popover} popover={@stream_popover} />
      </svg>

      <.properties_panel
        :if={!@profile_hide_properties_panel}
        selected={sole_selected_object(@selected_ids, @canvas)}
        canvas={@canvas}
        available_series={@available_series}
        discovered_hosts={@discovered_hosts}
      />

      <.timeline_bar
        timeline_mode={@timeline_mode}
        timeline_time={@timeline_time}
        timeline_span={@timeline_span}
        timeline_range={@timeline_range}
        timeline_data_range={@timeline_data_range}
      />

      <div class="canvas-zoom-indicator">
        <span>{zoom_percentage(@canvas.view_box)}%</span>
        <button
          :if={map_size(@canvas.elements) > 0}
          phx-click="center_view"
          class="canvas-zoom-indicator__reset"
        >
          Center
        </button>
        <button
          :if={zoom_percentage(@canvas.view_box) != 100}
          phx-click="zoom_reset"
          class="canvas-zoom-indicator__reset"
        >
          100%
        </button>
        <span class="canvas-zoom-indicator__sep"></span>
        <form phx-change="timeline:change" phx-submit="timeline:change" class="canvas-zoom-indicator__timeline-form">
          <label class="canvas-zoom-indicator__meta">
            <span>Span</span>
            <select name="span" class="timeline-bar__speed">
              <option
                :for={{secs, label} <- TimelessCanvas.Components.CanvasComponents.timeline_span_options()}
                value={secs}
                selected={@timeline_span == secs}
              >
                {label}
              </option>
            </select>
          </label>
          <label class="canvas-zoom-indicator__meta">
            <span>Range</span>
            <select name="range" class="timeline-bar__speed">
              <option
                :for={{value, label} <- TimelessCanvas.Components.CanvasComponents.timeline_range_options()}
                value={value}
                selected={@timeline_range == value}
              >
                {label}
              </option>
            </select>
          </label>
        </form>
      </div>
    </div>
    """
  end

  @shortcuts [
    {"Ctrl+Z", "Undo"},
    {"Ctrl+Shift+Z", "Redo"},
    {"Ctrl+C / X / V", "Copy / Cut / Paste"},
    {"Ctrl+A", "Select all"},
    {"Ctrl+S", "Save"},
    {"Backspace", "Delete"},
    {"Arrows", "Nudge"},
    {"Shift+Arrow", "Nudge 1px"},
    {"+ / -", "Zoom"},
    {"Space+Drag", "Pan"},
    {"Alt+Drag", "Pan"},
    {"Double-click", "Expand graph"}
  ]

  defp shortcut_legend(assigns) do
    vb = assigns.view_box
    base_x = vb.min_x + vb.width - 10
    base_y = vb.min_y + 14
    scale = vb.width / 1200

    assigns = assign(assigns, base_x: base_x, base_y: base_y, scale: scale, shortcuts: @shortcuts)

    ~H"""
    <g pointer-events="none" opacity="0.18">
      <text
        :for={{shortcut, i} <- Enum.with_index(@shortcuts)}
        x={@base_x}
        y={@base_y + i * 16 * @scale}
        text-anchor="end"
        fill="#94a3b8"
        font-size={11 * @scale}
        font-family="monospace"
      >
        <tspan fill="#cbd5e1">{elem(shortcut, 0)}</tspan>
        <tspan dx={5 * @scale} fill="#4ade80">{elem(shortcut, 1)}</tspan>
      </text>
    </g>
    """
  end

  # --- Properties Panel ---

  defp properties_panel(%{selected: nil} = assigns) do
    ~H""
  end

  defp properties_panel(%{selected: %Element{}} = assigns) do
    base_fields = Element.meta_fields(assigns.selected.type)

    # Add canvas variable names as meta fields so users can set $varName references
    var_fields =
      assigns.canvas.variables
      |> Map.keys()
      |> Enum.reject(fn name -> name in base_fields end)

    assigns =
      assign(assigns,
        meta_fields: base_fields ++ var_fields,
        display_meta_fields:
          display_meta_fields(base_fields ++ var_fields, assigns.selected.type),
        icon_select_options:
          icon_options("icon", assigns.selected.meta["icon"], IconCatalog.icon_options()),
        os_icon_options:
          icon_options("os_icon", assigns.selected.meta["os_icon"], IconCatalog.os_options())
      )

    assigns =
      if "host" in base_fields do
        assign(
          assigns,
          graph_host_options:
            select_options("host", assigns.selected.meta["host"], assigns.discovered_hosts)
        )
      else
        assigns
      end

    assigns =
      if assigns.selected.type == :graph do
        selected_metric = assigns.selected.meta["metric_name"] || ""
        selected_labels = graph_query_labels_from_meta(assigns.selected.meta)

        matching_series =
          matching_graph_series(assigns.available_series, selected_metric, selected_labels)

        assign(assigns,
          graph_metric_options: graph_metric_options(assigns.available_series, selected_metric),
          graph_series_options:
            graph_series_options(assigns.available_series, selected_metric, selected_labels),
          graph_matching_series: matching_series
        )
      else
        assigns
      end

    ~H"""
    <div class="properties-panel">
      <h3 class="properties-panel__title">Element Properties</h3>
      <form phx-change="property:update_element" phx-submit="property:update_element">
        <input type="hidden" name="element_id" value={@selected.id} />
        <div class="properties-panel__field">
          <label>Label</label>
          <input type="text" name="label" value={@selected.label} />
        </div>
        <div class="properties-panel__field">
          <label>Type</label>
          <select name="type">
            <option :for={t <- Element.element_types()} value={t} selected={t == @selected.type}>
              {t}
            </option>
          </select>
        </div>
        <div class="properties-panel__field">
          <label>Color</label>
          <input type="color" name="color" value={@selected.color} />
        </div>
        <div class="properties-panel__row">
          <div class="properties-panel__field">
            <label>X</label>
            <input type="number" name="x" value={round(@selected.x)} step="1" />
          </div>
          <div class="properties-panel__field">
            <label>Y</label>
            <input type="number" name="y" value={round(@selected.y)} step="1" />
          </div>
        </div>
        <div class="properties-panel__row">
          <div class="properties-panel__field">
            <label>Width</label>
            <input type="number" name="width" value={round(@selected.width)} step="1" min="20" />
          </div>
          <div class="properties-panel__field">
            <label>Height</label>
            <input type="number" name="height" value={round(@selected.height)} step="1" min="20" />
          </div>
        </div>
      </form>
      <div :if={@meta_fields != []} class="properties-panel__section">
        <h4 class="properties-panel__subtitle">Metadata</h4>
        <form phx-change="property:update_meta" phx-submit="property:update_meta">
          <input type="hidden" name="element_id" value={@selected.id} />
          <div :for={field <- @display_meta_fields} class="properties-panel__field">
            <label>{if field == "graph_series", do: "Series", else: field}</label>
            <select :if={field == "icon"} name={field}>
              <option
                :for={{value, label} <- @icon_select_options}
                value={value}
                selected={value == (@selected.meta[field] || "")}
              >
                {label}
              </option>
            </select>
            <select :if={field == "os_icon"} name={field}>
              <option
                :for={{value, label} <- @os_icon_options}
                value={value}
                selected={value == (@selected.meta[field] || "")}
              >
                {label}
              </option>
            </select>
            <select :if={field == "host"} name={field}>
              <option
                :for={{value, label} <- @graph_host_options}
                value={value}
                selected={value == (@selected.meta[field] || "")}
              >
                {label}
              </option>
            </select>
            <select :if={@selected.type == :graph && field == "metric_name"} name={field}>
              <option
                :for={{value, label} <- @graph_metric_options}
                value={value}
                selected={value == (@selected.meta[field] || "")}
              >
                {label}
              </option>
            </select>
            <select :if={@selected.type == :graph && field == "graph_series"} name="graph_series">
              <option
                :for={{value, label, selected?} <- @graph_series_options}
                value={value}
                selected={selected?}
              >
                {label}
              </option>
            </select>
            <input
              :if={
                field not in
                  ["icon", "os_icon", "host", "metric_name", "graph_series"]
              }
              type="text"
              name={field}
              value={@selected.meta[field] || ""}
            />
          </div>
        </form>
        <div :if={@selected.type == :graph} class="properties-panel__field">
          <label>Matching Series</label>
          <div class="properties-panel__series-list">
            <div
              :for={{metric_name, labels} <- @graph_matching_series}
              class="properties-panel__series-btn"
            >
              <strong>{metric_name}</strong>
              <span>{format_series_labels(labels)}</span>
            </div>
          </div>
        </div>
      </div>
      <div :if={(@selected.meta["host"] || "") != ""} class="properties-panel__section">
        <h4 class="properties-panel__subtitle">Add Elements</h4>
        <div class="properties-panel__series-list">
          <button
            class="properties-panel__series-btn properties-panel__series-btn--stream"
            phx-click="place_child_element"
            phx-value-type="log_stream"
            phx-value-element_id={@selected.id}
          >
            Logs
          </button>
          <button
            class="properties-panel__series-btn properties-panel__series-btn--stream"
            phx-click="place_child_element"
            phx-value-type="trace_stream"
            phx-value-element_id={@selected.id}
          >
            Traces
          </button>
          <button
            :for={{metric_name, _labels} <- @available_series}
            class="properties-panel__series-btn"
            phx-click="place_series_graph"
            phx-value-metric_name={metric_name}
            phx-value-element_id={@selected.id}
          >
            {metric_name}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp properties_panel(%{selected: %Connection{}} = assigns) do
    ~H"""
    <div class="properties-panel">
      <h3 class="properties-panel__title">Connection Properties</h3>
      <form phx-change="property:update_connection" phx-submit="property:update_connection">
        <input type="hidden" name="conn_id" value={@selected.id} />
        <div class="properties-panel__field">
          <label>Label</label>
          <input type="text" name="label" value={@selected.label} />
        </div>
        <div class="properties-panel__field">
          <label>Color</label>
          <input type="color" name="color" value={@selected.color} />
        </div>
        <div class="properties-panel__field">
          <label>Style</label>
          <select name="style">
            <option value="solid" selected={@selected.style == :solid}>Solid</option>
            <option value="dashed" selected={@selected.style == :dashed}>Dashed</option>
            <option value="dotted" selected={@selected.style == :dotted}>Dotted</option>
          </select>
        </div>
        <div class="properties-panel__field">
          <label>Source</label>
          <input type="text" value={@selected.source_id} disabled />
        </div>
        <div class="properties-panel__field">
          <label>Target</label>
          <input type="text" value={@selected.target_id} disabled />
        </div>
      </form>
    </div>
    """
  end

  defp stream_popover(%{popover: %{type: "log"}} = assigns) do
    entry = assigns.popover.entry
    x = assigns.popover.x
    y = assigns.popover.y

    ts = format_popover_timestamp(entry[:timestamp])
    level = entry[:level] |> to_string() |> String.upcase()
    msg = entry[:message] || ""

    msg_lines = wrap_text(msg, 50)

    meta_rows =
      case entry[:metadata] do
        m when is_map(m) and map_size(m) > 0 ->
          Enum.map(m, fn {k, v} ->
            val = if is_binary(v), do: v, else: inspect(v)
            {to_string(k), val}
          end)

        _ ->
          []
      end

    header_h = 24
    msg_h = length(msg_lines) * 11 + 8
    meta_h = if meta_rows != [], do: 14 + length(meta_rows) * 11, else: 0
    box_h = header_h + msg_h + meta_h + 8
    box_w = 360

    assigns =
      assign(assigns,
        x: x,
        y: y,
        box_w: box_w,
        box_h: box_h,
        header_h: header_h,
        msg_lines: msg_lines,
        msg_h: msg_h,
        meta_rows: meta_rows,
        ts: ts,
        level: level,
        level_atom: entry[:level]
      )

    ~H"""
    <g class="stream-popover" phx-click="stream:close_popover">
      <rect x={@x} y={@y} width={@box_w} height={@box_h} rx="4" fill="#0f172a" stroke="#334155" stroke-width="0.5" />
      <rect x={@x} y={@y} width={@box_w} height={@header_h} rx="4" fill="#1e293b" />
      <rect x={@x} y={@y + @header_h - 4} width={@box_w} height="4" fill="#1e293b" />
      <rect x={@x + 8} y={@y + 6} width="32" height="12" rx="2" fill={log_level_color(@level_atom)} opacity="0.2" />
      <text x={@x + 24} y={@y + 15} text-anchor="middle" fill={log_level_color(@level_atom)} font-size="7" font-weight="bold" font-family="monospace">{@level}</text>
      <text x={@x + 48} y={@y + 15} fill="#94a3b8" font-size="7" font-family="monospace">{@ts}</text>
      <text x={@x + @box_w - 14} y={@y + 15} fill="#64748b" font-size="9" cursor="pointer">x</text>
      <text
        :for={{line, i} <- Enum.with_index(@msg_lines)}
        x={@x + 10}
        y={@y + @header_h + 12 + i * 11}
        fill="#e2e8f0"
        font-size="8"
        font-family="monospace"
      >{line}</text>
      <line :if={@meta_rows != []} x1={@x + 8} y1={@y + @header_h + @msg_h - 2} x2={@x + @box_w - 8} y2={@y + @header_h + @msg_h - 2} stroke="#334155" stroke-width="0.5" />
      <text :if={@meta_rows != []} x={@x + 10} y={@y + @header_h + @msg_h + 9} fill="#64748b" font-size="6" font-family="monospace">METADATA</text>
      <g :for={{row, i} <- Enum.with_index(@meta_rows)}>
        <text x={@x + 10} y={@y + @header_h + @msg_h + 20 + i * 11} fill="#94a3b8" font-size="7" font-family="monospace">{elem(row, 0)}</text>
        <text x={@x + 90} y={@y + @header_h + @msg_h + 20 + i * 11} fill="#e2e8f0" font-size="7" font-family="monospace">{elem(row, 1)}</text>
      </g>
    </g>
    """
  end

  defp stream_popover(%{popover: %{type: "trace"}} = assigns) do
    span = assigns.popover.entry
    x = assigns.popover.x
    y = assigns.popover.y

    ts = format_popover_timestamp(span[:timestamp])
    duration = format_popover_duration(span[:duration_ns])
    status = span[:status]
    status_ok = status == :ok || status == "ok"

    attrs =
      [
        if(span[:trace_id], do: {"Trace ID", span[:trace_id]}),
        if(span[:span_id], do: {"Span ID", span[:span_id]}),
        if(span[:service], do: {"Service", span[:service]}),
        if(span[:kind], do: {"Kind", to_string(span[:kind])}),
        if(ts, do: {"Start", ts})
      ]
      |> Enum.reject(&is_nil/1)

    header_h = 36
    dur_bar_h = 18
    attrs_h = if attrs != [], do: 14 + length(attrs) * 12, else: 0
    status_msg_h = if span[:status_message] && span[:status_message] != "", do: 14, else: 0
    box_h = header_h + dur_bar_h + attrs_h + status_msg_h + 12
    box_w = 340

    dur_bar_w = box_w - 20

    assigns =
      assign(assigns,
        x: x,
        y: y,
        box_w: box_w,
        box_h: box_h,
        header_h: header_h,
        dur_bar_h: dur_bar_h,
        dur_bar_w: dur_bar_w,
        attrs: attrs,
        attrs_h: attrs_h,
        span_name: span[:name] || "unknown",
        duration: duration,
        status: status,
        status_ok: status_ok,
        status_message: span[:status_message],
        status_msg_h: status_msg_h,
        service: span[:service]
      )

    ~H"""
    <g class="stream-popover" phx-click="stream:close_popover">
      <rect x={@x} y={@y} width={@box_w} height={@box_h} rx="4" fill="#0f172a" stroke="#334155" stroke-width="0.5" />
      <rect x={@x} y={@y} width={@box_w} height={@header_h} rx="4" fill="#1e293b" />
      <rect x={@x} y={@y + @header_h - 4} width={@box_w} height="4" fill="#1e293b" />
      <rect :if={@service} x={@x + 8} y={@y + 5} width={String.length(@service) * 5 + 10} height="12" rx="2" fill="#6366f1" opacity="0.25" />
      <text :if={@service} x={@x + 13} y={@y + 14} fill="#818cf8" font-size="7" font-weight="bold" font-family="monospace">{@service}</text>
      <text x={@x + 8} y={@y + 28} fill="#e2e8f0" font-size="9" font-weight="bold" font-family="monospace">{@span_name}</text>
      <circle cx={@x + @box_w - 16} cy={@y + 14} r="4" fill={if @status_ok, do: "#22c55e", else: "#ef4444"} />
      <text x={@x + @box_w - 28} y={@y + 17} fill="#64748b" font-size="9" cursor="pointer">x</text>
      <rect x={@x + 10} y={@y + @header_h + 4} width={@dur_bar_w} height="10" rx="2" fill="#1e293b" />
      <rect x={@x + 10} y={@y + @header_h + 4} width={@dur_bar_w} height="10" rx="2" fill={if @status_ok, do: "#22c55e", else: "#ef4444"} opacity="0.3" />
      <text x={@x + 14} y={@y + @header_h + 12} fill="#e2e8f0" font-size="7" font-weight="bold" font-family="monospace">{@duration}</text>
      <text :if={@status_message && @status_message != ""} x={@x + 10} y={@y + @header_h + @dur_bar_h + 10} fill="#ef4444" font-size="7" font-family="monospace">{@status_message}</text>
      <line :if={@attrs != []} x1={@x + 8} y1={@y + @header_h + @dur_bar_h + @status_msg_h + 2} x2={@x + @box_w - 8} y2={@y + @header_h + @dur_bar_h + @status_msg_h + 2} stroke="#334155" stroke-width="0.5" />
      <text :if={@attrs != []} x={@x + 10} y={@y + @header_h + @dur_bar_h + @status_msg_h + 12} fill="#64748b" font-size="6" font-family="monospace">ATTRIBUTES</text>
      <g :for={{row, i} <- Enum.with_index(@attrs)}>
        <text x={@x + 10} y={@y + @header_h + @dur_bar_h + @status_msg_h + 24 + i * 12} fill="#94a3b8" font-size="7" font-family="monospace">{elem(row, 0)}</text>
        <text x={@x + 80} y={@y + @header_h + @dur_bar_h + @status_msg_h + 24 + i * 12} fill="#e2e8f0" font-size="7" font-family="monospace">{elem(row, 1)}</text>
      </g>
    </g>
    """
  end

  defp format_popover_timestamp(nil), do: nil

  defp format_popover_timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} ->
        Calendar.strftime(dt, "%H:%M:%S.") <> String.pad_leading("#{rem(ts, 1000)}", 3, "0")

      _ ->
        "#{ts}"
    end
  end

  defp format_popover_timestamp(ts), do: "#{ts}"

  defp format_popover_duration(nil), do: "?"

  defp format_popover_duration(ns) when is_integer(ns) do
    cond do
      ns < 1_000 -> "#{ns}ns"
      ns < 1_000_000 -> "#{Float.round(ns / 1_000, 1)}us"
      ns < 1_000_000_000 -> "#{Float.round(ns / 1_000_000, 1)}ms"
      true -> "#{Float.round(ns / 1_000_000_000, 2)}s"
    end
  end

  defp format_popover_duration(_), do: "?"

  defp wrap_text(text, max_chars) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.length(line) <= max_chars do
        [line]
      else
        line
        |> String.graphemes()
        |> Enum.chunk_every(max_chars)
        |> Enum.map(&Enum.join/1)
      end
    end)
    |> Enum.take(15)
  end

  defp log_level_color(:error), do: "#ef4444"
  defp log_level_color(:warning), do: "#f59e0b"
  defp log_level_color(:info), do: "#22c55e"
  defp log_level_color(_), do: "#94a3b8"

  defp host_combobox(assigns) do
    filtered =
      if assigns.filter == "" do
        assigns.hosts
      else
        pattern = String.downcase(assigns.filter)
        Enum.filter(assigns.hosts, &String.contains?(String.downcase(&1), pattern))
      end

    assigns = assign(assigns, filtered: filtered)

    ~H"""
    <div class="host-combobox" phx-click-away="host_combo:close">
      <input
        type="text"
        class="host-combobox__input"
        placeholder={@selected || "Search hosts..."}
        value={@filter}
        phx-keyup="host_combo:filter"
        phx-focus="host_combo:open"
      />
      <div :if={@filter != "" || @selected == nil} class="host-combobox__dropdown">
        <button
          :for={host <- @filtered}
          class={"host-combobox__option#{if host == @selected, do: " host-combobox__option--active", else: ""}"}
          phx-click="set_place_host"
          phx-value-host={host}
        >
          {host}
        </button>
        <span :if={@filtered == []} class="host-combobox__empty">No matches</span>
      </div>
    </div>
    """
  end

  defp sole_selected_object(selected_ids, canvas) do
    case MapSet.to_list(selected_ids) do
      [id] -> find_object(id, canvas)
      _ -> nil
    end
  end

  defp find_object("el-" <> _ = id, canvas), do: Map.get(canvas.elements, id)
  defp find_object("conn-" <> _ = id, canvas), do: Map.get(canvas.connections, id)
  defp find_object(_id, _canvas), do: nil

  defp zoom_percentage(%ViewBox{width: width}) do
    round(@base_viewbox_width / width * 100)
  end

  # --- Helpers ---

  defp push_canvas(socket, %Canvas{} = canvas) do
    history = History.push(socket.assigns.history, canvas)

    assign(socket, history: history, canvas: history.present)
    |> resolve_and_assign()
    |> register_elements()
  end

  defp update_canvas(socket, %Canvas{} = canvas) do
    history = %{socket.assigns.history | present: canvas}

    assign(socket, history: history, canvas: canvas)
    |> resolve_and_assign()
    |> register_elements()
  end

  defp register_elements(socket) do
    elements = Map.values(socket.assigns.resolved_elements)
    StatusManager.register_elements(elements)

    stream_data =
      if connected?(socket) and map_size(socket.assigns.resolved_elements) > 0 do
        register_stream_elements(socket.assigns.resolved_elements)
      else
        %{}
      end

    assign(socket, stream_data: Map.merge(socket.assigns.stream_data, stream_data))
  end

  defp resolve_and_assign(socket) do
    bindings = VariableResolver.bindings(socket.assigns.canvas.variables)
    resolved = VariableResolver.resolve_elements(socket.assigns.canvas.elements, bindings)
    assign(socket, resolved_elements: resolved)
  end

  defp refresh_variable_options(socket) do
    assign(socket, variable_options: build_variable_options(socket.assigns.canvas.variables))
  end

  defp schedule_debug_report(socket) do
    if connected?(socket) do
      Process.send_after(self(), :debug_report, @debug_report_interval)
    end

    socket
  end

  defp schedule_graph_refresh(socket) do
    if connected?(socket) do
      Process.send_after(self(), :graph_refresh, graph_refresh_interval())
    end

    socket
  end

  defp graph_refresh_interval do
    TimelessCanvas.data_source_config()
    |> Keyword.get(:poll_interval, @default_graph_refresh_interval)
  end

  defp bump_render_stat(key, delta) do
    Process.put(key, (Process.get(key) || 0) + delta)
  end

  defp consume_render_stats do
    %{
      sorted_calls: consume_render_stat(:sorted_calls),
      sorted_time_us: consume_render_stat(:sorted_time_us),
      graph_point_calls: consume_render_stat(:graph_point_calls),
      graph_point_time_us: consume_render_stat(:graph_point_time_us),
      canvas_element_calls: consume_render_stat(:canvas_element_calls),
      canvas_element_time_us: consume_render_stat(:canvas_element_time_us),
      graph_body_calls: consume_render_stat(:graph_body_calls),
      graph_body_time_us: consume_render_stat(:graph_body_time_us),
      expanded_graph_body_calls: consume_render_stat(:expanded_graph_body_calls),
      expanded_graph_body_time_us: consume_render_stat(:expanded_graph_body_time_us),
      log_stream_body_calls: consume_render_stat(:log_stream_body_calls),
      log_stream_body_time_us: consume_render_stat(:log_stream_body_time_us),
      trace_stream_body_calls: consume_render_stat(:trace_stream_body_calls),
      trace_stream_body_time_us: consume_render_stat(:trace_stream_body_time_us)
    }
  end

  defp consume_render_stat(key) do
    value = Process.get(key) || 0
    Process.delete(key)
    value
  end

  defp build_variable_options(variables) do
    Map.new(variables, fn {name, definition} ->
      case definition["type"] do
        "host" ->
          {name, StatusManager.list_hosts()}

        "label" ->
          label_key = definition["label_key"] || name
          {name, StatusManager.list_label_values(label_key)}

        "custom" ->
          {name, definition["options"] || []}

        _ ->
          {name, []}
      end
    end)
  end

  defp select_options(_field, selected, values) do
    current = selected || ""

    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> then(fn opts ->
      opts =
        if current != "" and current not in opts do
          [current | opts]
        else
          opts
        end

      [{"", "Select..."} | Enum.map(opts, &{&1, &1})]
    end)
  end

  defp graph_metric_options(series, selected_metric) do
    values =
      series
      |> Enum.map(fn {metric_name, _labels} -> metric_name end)
      |> Enum.uniq()
      |> Enum.sort()

    select_options("metric_name", selected_metric, values)
  end

  defp graph_series_options(series, metric_name, selected_labels) do
    selected_value = selected_graph_series_value(series, metric_name, selected_labels)

    options =
      series
      |> Enum.filter(fn {name, _labels} -> name == metric_name end)
      |> Enum.map(fn {_name, labels} ->
        encoded = encode_graph_series(labels)
        {encoded, format_series_labels(labels), encoded == selected_value}
      end)
      |> Enum.uniq()
      |> Enum.sort_by(fn {_value, label, _selected?} -> label end)

    [{"", "Any series", selected_value in [nil, ""]} | options]
  end

  defp selected_graph_series_value(series, metric_name, selected_labels) do
    Enum.find_value(series, fn
      {^metric_name, labels} ->
        if series_matches_labels?(labels, selected_labels),
          do: encode_graph_series(labels),
          else: nil

      _ ->
        nil
    end)
  end

  defp matching_graph_series(series, metric_name, selected_labels) do
    Enum.filter(series, fn {name, labels} ->
      name == metric_name and series_matches_labels?(labels, selected_labels)
    end)
  end

  defp format_series_labels(labels) when is_map(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp format_series_labels(_), do: ""

  defp series_matches_labels?(_labels, selected_labels) when selected_labels in [%{}, nil],
    do: true

  defp series_matches_labels?(labels, selected_labels)
       when is_map(labels) and is_map(selected_labels) do
    Enum.all?(selected_labels, fn {key, value} -> Map.get(labels, key) == value end)
  end

  defp series_matches_labels?(_labels, _selected_labels), do: false

  defp encode_graph_series(labels) when is_map(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_graph_series(""), do: %{}

  defp decode_graph_series(value) when is_binary(value) do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok, labels} <- Jason.decode(json),
         true <- is_map(labels) do
      labels
    else
      _ -> %{}
    end
  end

  defp display_meta_fields(fields, :graph) do
    fields
    |> List.insert_at(Enum.find_index(fields, &(&1 == "y_min")) || length(fields), "graph_series")
    |> Enum.uniq()
  end

  defp display_meta_fields(fields, _type), do: fields

  defp graph_query_labels_from_meta(meta) when is_map(meta) do
    base_meta =
      meta
      |> Map.drop([
        "metric_name",
        "series_label_key",
        "series_label_value",
        "y_min",
        "y_max",
        "icon",
        "os_icon"
      ])
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    case {meta["series_label_key"], meta["series_label_value"]} do
      {key, value} when is_binary(key) and key != "" and is_binary(value) and value != "" ->
        Map.put(base_meta, key, value)

      _ ->
        base_meta
    end
  end

  defp graph_query_labels_from_meta(_meta), do: %{}

  defp schedule_autosave(socket) do
    if Map.get(socket.assigns, :autosave_ref) do
      Process.cancel_timer(socket.assigns.autosave_ref)
    end

    ref = Process.send_after(self(), :autosave, 2000)
    assign(socket, autosave_ref: ref)
  end

  defp apply_statuses(canvas, statuses) do
    Enum.reduce(statuses, canvas, fn {id, status}, acc ->
      Canvas.set_element_status(acc, id, status)
    end)
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("canvas:pan", %{"dx" => dx, "dy" => dy}, socket) do
    canvas = Canvas.pan(socket.assigns.canvas, dx, dy)
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event(
        "canvas:zoom",
        %{"min_x" => min_x, "min_y" => min_y, "width" => width, "height" => height},
        socket
      ) do
    requested_vb = %ViewBox{
      min_x: min_x / 1,
      min_y: min_y / 1,
      width: width / 1,
      height: height / 1
    }

    vb = clamp_view_box(requested_vb)

    canvas = %{socket.assigns.canvas | view_box: vb}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("zoom_reset", _params, socket) do
    vb = socket.assigns.canvas.view_box
    target_w = @base_viewbox_width
    target_h = target_w * (vb.height / vb.width)
    {center_x, center_y} = content_center(socket.assigns.canvas.elements, vb)

    new_vb =
      clamp_view_box(%ViewBox{
        min_x: center_x - target_w / 2,
        min_y: center_y - target_h / 2,
        width: target_w,
        height: target_h
      })

    canvas = %{socket.assigns.canvas | view_box: new_vb}

    socket =
      socket
      |> update_canvas(canvas)
      |> push_event("set-viewbox", %{
        x: new_vb.min_x,
        y: new_vb.min_y,
        width: new_vb.width,
        height: new_vb.height
      })

    {:noreply, socket}
  end

  def handle_event("center_view", _params, socket) do
    vb = socket.assigns.canvas.view_box
    {center_x, center_y} = content_center(socket.assigns.canvas.elements, vb)

    new_vb = %ViewBox{
      min_x: center_x - vb.width / 2,
      min_y: center_y - vb.height / 2,
      width: vb.width,
      height: vb.height
    }

    canvas = %{socket.assigns.canvas | view_box: new_vb}

    socket =
      socket
      |> update_canvas(canvas)
      |> push_event("set-viewbox", %{
        x: new_vb.min_x,
        y: new_vb.min_y,
        width: new_vb.width,
        height: new_vb.height
      })

    {:noreply, socket}
  end

  def handle_event("fit_to_content", _params, socket) do
    elements = Map.values(socket.assigns.canvas.elements)

    if elements == [] do
      {:noreply, socket}
    else
      padding = 60

      min_x = elements |> Enum.map(& &1.x) |> Enum.min()
      min_y = elements |> Enum.map(& &1.y) |> Enum.min()
      max_x = elements |> Enum.map(&(&1.x + &1.width)) |> Enum.max()
      max_y = elements |> Enum.map(&(&1.y + &1.height)) |> Enum.max()

      content_w = max_x - min_x + padding * 2
      content_h = max_y - min_y + padding * 2

      vb = socket.assigns.canvas.view_box
      aspect = vb.width / vb.height

      {fit_w, fit_h} =
        if content_w / content_h > aspect do
          {content_w, content_w / aspect}
        else
          {content_h * aspect, content_h}
        end

      center_x = (min_x + max_x) / 2
      center_y = (min_y + max_y) / 2

      new_vb = %ViewBox{
        min_x: center_x - fit_w / 2,
        min_y: center_y - fit_h / 2,
        width: fit_w,
        height: fit_h
      }

      canvas = %{socket.assigns.canvas | view_box: new_vb}

      socket =
        socket
        |> update_canvas(canvas)
        |> push_event("set-viewbox", %{
          x: new_vb.min_x,
          y: new_vb.min_y,
          width: new_vb.width,
          height: new_vb.height
        })

      {:noreply, socket}
    end
  end

  def handle_event("canvas:click", %{"x" => x, "y" => y}, socket) do
    case socket.assigns.mode do
      :place ->
        require_edit(socket, fn ->
          case socket.assigns.place_kind do
            :host ->
              host = socket.assigns.place_host

              if host do
                place_host_element(socket, host, x / 1.0, y / 1.0)
              else
                {:noreply, socket}
              end

            type when type in [:rect, :canvas, :text, :text_series] ->
              place_typed_element(socket, type, x / 1.0, y / 1.0)
          end
        end)

      :connect ->
        {:noreply, assign(socket, connect_from: nil)}

      :select ->
        {:noreply,
         assign(socket, selected_ids: MapSet.new(), available_series: [], stream_popover: nil)}
    end
  end

  def handle_event("element:select", %{"id" => id}, socket) do
    case socket.assigns.mode do
      :connect ->
        require_edit(socket, fn ->
          case socket.assigns.connect_from do
            nil ->
              {:noreply, assign(socket, connect_from: id)}

            ^id ->
              {:noreply, assign(socket, connect_from: nil)}

            from_id ->
              {canvas, _conn} = Canvas.add_connection(socket.assigns.canvas, from_id, id)

              {:noreply,
               push_canvas(socket, canvas) |> assign(connect_from: nil) |> schedule_autosave()}
          end
        end)

      _ ->
        {:noreply,
         socket
         |> assign(selected_ids: MapSet.new([id]))
         |> fetch_series_for_selected(id)}
    end
  end

  def handle_event("element:dblclick", %{"id" => id}, socket) do
    case Map.get(socket.assigns.canvas.elements, id) do
      %{type: :canvas, meta: %{"canvas_id" => canvas_id}} when canvas_id != "" ->
        if socket.assigns.can_edit do
          data = Serializer.encode(socket.assigns.canvas)
          persistence().update_canvas_data(socket.assigns.canvas_id, data)
        end

        {:noreply, push_navigate(socket, to: "#{socket.assigns.tc_base_path}/#{canvas_id}")}

      %{type: :graph} ->
        if socket.assigns.expanded_graph_id == id do
          {:noreply,
           assign(socket,
             expanded_graph_id: nil,
             expanded_graph_data: [],
             pre_expand_viewbox: nil
           )}
        else
          expanded_data = fetch_expanded_data(socket, id)

          socket =
            assign(socket,
              expanded_graph_id: id,
              expanded_graph_data: expanded_data,
              pre_expand_viewbox: socket.assigns.canvas.view_box
            )

          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("element:shift_select", %{"id" => id}, socket) do
    selected_ids = socket.assigns.selected_ids

    selected_ids =
      if MapSet.member?(selected_ids, id),
        do: MapSet.delete(selected_ids, id),
        else: MapSet.put(selected_ids, id)

    {:noreply, assign(socket, selected_ids: selected_ids)}
  end

  def handle_event("marquee:select", %{"ids" => ids}, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new(ids))}
  end

  def handle_event("connection:select", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new([id]))}
  end

  def handle_event("element:move", %{"id" => id, "dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids

      canvas =
        if MapSet.member?(selected_ids, id) and MapSet.size(selected_ids) > 1 do
          Canvas.move_elements(
            socket.assigns.canvas,
            MapSet.to_list(selected_ids),
            dx / 1.0,
            dy / 1.0
          )
        else
          Canvas.move_element(socket.assigns.canvas, id, dx / 1.0, dy / 1.0)
        end

      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:resize", %{"id" => id, "width" => width, "height" => height}, socket) do
    require_edit(socket, fn ->
      canvas = Canvas.resize_element(socket.assigns.canvas, id, width / 1.0, height / 1.0)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("element:nudge", %{"dx" => dx, "dy" => dy}, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids
      element_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          canvas = Canvas.move_elements(socket.assigns.canvas, ids, dx / 1.0, dy / 1.0)
          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("toggle_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(mode), connect_from: nil)}
  end

  def handle_event("set_place_host", %{"host" => host}, socket) do
    {:noreply, assign(socket, place_host: host, host_filter: "", place_kind: :host)}
  end

  def handle_event("set_host_type", %{"host_type" => type}, socket) do
    {:noreply, assign(socket, place_host_type: String.to_existing_atom(type))}
  end

  def handle_event("set_place_kind", %{"kind" => kind}, socket) do
    {:noreply, assign(socket, place_kind: String.to_existing_atom(kind))}
  end

  def handle_event("host_combo:filter", %{"value" => value}, socket) do
    {:noreply, assign(socket, host_filter: value)}
  end

  def handle_event("host_combo:open", _params, socket) do
    {:noreply, assign(socket, host_filter: "")}
  end

  def handle_event("host_combo:close", _params, socket) do
    {:noreply, assign(socket, host_filter: "")}
  end

  def handle_event("toggle_grid", _params, socket) do
    canvas = %{socket.assigns.canvas | grid_visible: !socket.assigns.canvas.grid_visible}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("toggle_snap", _params, socket) do
    canvas = %{socket.assigns.canvas | snap_to_grid: !socket.assigns.canvas.snap_to_grid}
    {:noreply, update_canvas(socket, canvas)}
  end

  def handle_event("send_to_back", _params, socket) do
    require_edit(socket, fn ->
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          min_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.min()

          canvas =
            Enum.with_index(ids)
            |> Enum.reduce(socket.assigns.canvas, fn {id, i}, acc ->
              Canvas.update_element(acc, id, %{z_index: min_z - length(ids) + i})
            end)

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("bring_to_front", _params, socket) do
    require_edit(socket, fn ->
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      case element_ids do
        [] ->
          {:noreply, socket}

        ids ->
          max_z =
            socket.assigns.canvas.elements |> Map.values() |> Enum.map(& &1.z_index) |> Enum.max()

          canvas =
            Enum.with_index(ids)
            |> Enum.reduce(socket.assigns.canvas, fn {id, i}, acc ->
              Canvas.update_element(acc, id, %{z_index: max_z + 1 + i})
            end)

          {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      end
    end)
  end

  def handle_event("delete_selected", _params, socket) do
    require_edit(socket, fn ->
      selected_ids = socket.assigns.selected_ids

      if MapSet.size(selected_ids) == 0 do
        {:noreply, socket}
      else
        for id <- selected_ids, String.starts_with?(id, "el-") do
          el = socket.assigns.canvas.elements[id]

          if el && el.type in [:log_stream, :trace_stream] do
            StreamManager.unregister_stream(id)
          end
        end

        conn_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "conn-"))
        element_ids = Enum.filter(selected_ids, &String.starts_with?(&1, "el-"))

        canvas =
          Enum.reduce(conn_ids, socket.assigns.canvas, fn id, acc ->
            Canvas.remove_connection(acc, id)
          end)

        canvas = Canvas.remove_elements(canvas, element_ids)

        {:noreply,
         push_canvas(socket, canvas)
         |> assign(selected_ids: MapSet.new())
         |> schedule_autosave()}
      end
    end)
  end

  def handle_event("canvas:deselect", _params, socket) do
    {:noreply,
     assign(socket,
       selected_ids: MapSet.new(),
       connect_from: nil,
       available_series: [],
       stream_popover: nil
     )}
  end

  def handle_event(
        "stream:entry_click",
        %{"element_id" => element_id, "index" => index, "type" => type},
        socket
      ) do
    entries = Map.get(socket.assigns.stream_data, element_id, [])
    entry = Enum.at(entries, index)

    if entry do
      element = socket.assigns.canvas.elements[element_id]

      popover = %{
        type: type,
        entry: entry,
        x: element.x + element.width + 10,
        y: element.y + 15 + index * 14
      }

      {:noreply, assign(socket, stream_popover: popover)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stream:close_popover", _params, socket) do
    {:noreply, assign(socket, stream_popover: nil)}
  end

  def handle_event("select_all", _params, socket) do
    all_ids = socket.assigns.canvas.elements |> Map.keys() |> MapSet.new()
    {:noreply, assign(socket, selected_ids: all_ids)}
  end

  def handle_event("canvas:copy", _params, socket) do
    element_ids =
      socket.assigns.selected_ids
      |> Enum.filter(&String.starts_with?(&1, "el-"))

    templates =
      Enum.map(element_ids, &Map.get(socket.assigns.canvas.elements, &1))
      |> Enum.reject(&is_nil/1)

    {:noreply, assign(socket, clipboard: templates, paste_offset: 20)}
  end

  def handle_event("canvas:cut", _params, socket) do
    require_edit(socket, fn ->
      element_ids =
        socket.assigns.selected_ids
        |> Enum.filter(&String.starts_with?(&1, "el-"))

      templates =
        Enum.map(element_ids, &Map.get(socket.assigns.canvas.elements, &1))
        |> Enum.reject(&is_nil/1)

      canvas = Canvas.remove_elements(socket.assigns.canvas, element_ids)

      {:noreply,
       push_canvas(socket, canvas)
       |> assign(clipboard: templates, paste_offset: 20, selected_ids: MapSet.new())
       |> schedule_autosave()}
    end)
  end

  def handle_event("canvas:paste", _params, socket) do
    require_edit(socket, fn ->
      case socket.assigns.clipboard do
        [] ->
          {:noreply, socket}

        templates ->
          offset = socket.assigns.paste_offset

          {canvas, new_ids} =
            Canvas.duplicate_elements(socket.assigns.canvas, templates, offset)

          {:noreply,
           push_canvas(socket, canvas)
           |> assign(
             selected_ids: MapSet.new(new_ids),
             paste_offset: offset + 20
           )
           |> schedule_autosave()}
      end
    end)
  end

  def handle_event("start_rename", _params, socket) do
    {:noreply, assign(socket, renaming: true)}
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply, assign(socket, renaming: false)}
  end

  def handle_event("save_name", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, renaming: false)}
    else
      case persistence().rename_canvas(socket.assigns.canvas_id, socket.assigns.user_id, name) do
        {:ok, _} ->
          breadcrumbs = persistence().breadcrumb_chain(socket.assigns.canvas_id)

          {:noreply,
           assign(socket,
             canvas_name: name,
             renaming: false,
             page_title: name,
             breadcrumbs: breadcrumbs
           )}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:error, "Could not rename canvas")
           |> assign(renaming: false)}
      end
    end
  end

  def handle_event("toggle_share", _params, socket) do
    {:noreply, assign(socket, show_share: !socket.assigns.show_share)}
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, show_share: false)}
  end

  def handle_event("canvas:undo", _params, socket) do
    require_edit(socket, fn ->
      history = History.undo(socket.assigns.history)

      socket =
        assign(socket, history: history, canvas: history.present, selected_ids: MapSet.new())
        |> resolve_and_assign()
        |> refresh_variable_options()

      {:noreply, socket}
    end)
  end

  def handle_event("canvas:redo", _params, socket) do
    require_edit(socket, fn ->
      history = History.redo(socket.assigns.history)

      socket =
        assign(socket, history: history, canvas: history.present, selected_ids: MapSet.new())
        |> resolve_and_assign()
        |> refresh_variable_options()

      {:noreply, socket}
    end)
  end

  def handle_event(
        "place_child_element",
        %{"type" => type_str, "element_id" => source_id},
        socket
      ) do
    require_edit(socket, fn ->
      source =
        Map.get(socket.assigns.resolved_elements, source_id) ||
          Map.get(socket.assigns.canvas.elements, source_id)

      if source do
        type = String.to_existing_atom(type_str)
        host = source.meta["host"] || source.meta["service_name"]
        defaults = Element.defaults_for(type)

        {place_x, place_y} =
          find_open_position(
            socket.assigns.canvas.elements,
            source.x,
            source.y + source.height + 20,
            defaults.width,
            defaults.height
          )

        meta =
          case type do
            :log_stream -> if(host, do: %{"host" => host}, else: %{})
            :trace_stream -> if(host, do: %{"host" => host}, else: %{})
          end

        {canvas, el} =
          Canvas.add_element(socket.assigns.canvas, %{
            type: type,
            x: place_x,
            y: place_y,
            width: defaults.width,
            height: defaults.height,
            color: defaults.color,
            label: "#{if type == :log_stream, do: "Logs", else: "Traces"} (#{host})",
            meta: meta
          })

        case type do
          :log_stream ->
            StreamManager.register_log_stream(el.id, build_log_opts(meta))

          :trace_stream ->
            StreamManager.register_trace_stream(el.id, build_trace_opts(meta))
        end

        {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event(
        "place_series_graph",
        %{"metric_name" => metric_name, "element_id" => source_id},
        socket
      ) do
    require_edit(socket, fn ->
      source = socket.assigns.canvas.elements[source_id]

      if source do
        host_ref = source.meta["host"] || source.meta["service_name"]
        defaults = Element.defaults_for(:graph)

        {place_x, place_y} =
          find_open_position(
            socket.assigns.canvas.elements,
            source.x,
            source.y + source.height + 20,
            defaults.width,
            defaults.height
          )

        {canvas, el} =
          Canvas.add_element(socket.assigns.canvas, %{
            type: :graph,
            x: place_x,
            y: place_y,
            width: defaults.width,
            height: defaults.height,
            color: defaults.color,
            label: metric_name,
            meta: IconCatalog.graph_meta(source, host_ref, metric_name)
          })

        bindings = VariableResolver.bindings(canvas.variables)
        resolved_el = VariableResolver.resolve_element(el, bindings)
        StatusManager.register_elements([resolved_el])

        socket =
          socket
          |> push_canvas(canvas)
          |> fetch_metric_units()
          |> backfill_graph(resolved_el)
          |> schedule_autosave()

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end)
  end

  # --- Variable event handlers ---

  def handle_event("var:change", params, socket) do
    require_edit(socket, fn ->
      {var_name, new_value} =
        socket.assigns.canvas.variables
        |> Map.keys()
        |> Enum.find_value(fn name ->
          case params[name] do
            nil -> nil
            val -> {name, val}
          end
        end)

      if var_name do
        canvas = socket.assigns.canvas
        var_def = Map.put(canvas.variables[var_name], "current", new_value)
        variables = Map.put(canvas.variables, var_name, var_def)
        canvas = %{canvas | variables: variables}
        time = socket.assigns.timeline_time || DateTime.utc_now()

        socket =
          socket
          |> push_canvas(canvas)
          |> fetch_metric_units()
          |> fill_graph_data_at(time)
          |> fill_stream_data_at(time)
          |> schedule_autosave()

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("var:show_add", _params, socket) do
    {:noreply, assign(socket, show_add_variable: true)}
  end

  def handle_event("var:cancel_add", _params, socket) do
    {:noreply, assign(socket, show_add_variable: false)}
  end

  def handle_event("var:add", params, socket) do
    require_edit(socket, fn ->
      name = String.trim(params["name"] || "")

      if name != "" do
        canvas = socket.assigns.canvas
        var_def = %{"type" => "label", "label_key" => name, "current" => ""}
        variables = Map.put(canvas.variables, name, var_def)
        canvas = %{canvas | variables: variables}

        socket =
          socket
          |> push_canvas(canvas)
          |> refresh_variable_options()
          |> assign(show_add_variable: false)
          |> schedule_autosave()

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("var:remove", %{"name" => name}, socket) do
    require_edit(socket, fn ->
      canvas = socket.assigns.canvas
      variables = Map.delete(canvas.variables, name)
      canvas = %{canvas | variables: variables}

      socket =
        socket
        |> push_canvas(canvas)
        |> refresh_variable_options()
        |> schedule_autosave()

      {:noreply, socket}
    end)
  end

  # Properties panel updates

  def handle_event("property:update_element", %{"element_id" => id} = params, socket) do
    require_edit(socket, fn ->
      attrs =
        %{}
        |> maybe_put(:label, params["label"])
        |> maybe_put(:color, params["color"])
        |> maybe_put_float(:x, params["x"])
        |> maybe_put_float(:y, params["y"])
        |> maybe_put_float(:width, params["width"])
        |> maybe_put_float(:height, params["height"])
        |> maybe_put_atom(:type, params["type"])

      canvas = Canvas.update_element(socket.assigns.canvas, id, attrs)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  def handle_event("property:update_meta", %{"element_id" => id} = params, socket) do
    require_edit(socket, fn ->
      old_meta = socket.assigns.canvas.elements[id].meta
      old_type = socket.assigns.canvas.elements[id].type
      base_fields = Element.meta_fields(socket.assigns.canvas.elements[id].type)
      var_fields = Map.keys(socket.assigns.canvas.variables) |> Enum.reject(&(&1 in base_fields))
      meta_fields = base_fields ++ var_fields

      new_meta =
        Enum.reduce(meta_fields, old_meta, fn field, meta ->
          case params[field] do
            nil -> meta
            "" -> Map.delete(meta, field)
            val -> Map.put(meta, field, val)
          end
        end)
        |> maybe_apply_graph_series(old_meta, params["graph_series"])

      canvas = Canvas.update_element(socket.assigns.canvas, id, %{meta: new_meta})
      socket = push_canvas(socket, canvas) |> schedule_autosave()
      time = socket.assigns.timeline_time || DateTime.utc_now()

      case Map.get(socket.assigns.resolved_elements, id) do
        %{type: :log_stream} = resolved ->
          StreamManager.register_log_stream(id, build_log_opts(resolved.meta))

        %{type: :trace_stream} = resolved ->
          StreamManager.register_trace_stream(id, build_trace_opts(resolved.meta))

        _ ->
          :ok
      end

      socket =
        socket
        |> maybe_refresh_selected_series(id, old_meta, new_meta)
        |> maybe_refresh_element_data(id, old_type, time)

      {:noreply, socket}
    end)
  end

  defp maybe_apply_graph_series(meta, _old_meta, nil), do: meta

  defp maybe_apply_graph_series(meta, old_meta, graph_series_value) do
    selected_labels = decode_graph_series(graph_series_value)

    old_label_keys =
      old_meta
      |> graph_query_labels_from_meta()
      |> Map.keys()

    meta
    |> Map.drop(old_label_keys)
    |> Map.delete("series_label_key")
    |> Map.delete("series_label_value")
    |> Map.merge(selected_labels)
  end

  defp maybe_refresh_selected_series(socket, id, old_meta, new_meta) do
    if new_meta["host"] != old_meta["host"] do
      fetch_series_for_selected(socket, id)
    else
      socket
    end
  end

  defp maybe_refresh_element_data(socket, _id, :graph, time) do
    socket
    |> fetch_metric_units()
    |> fill_graph_data_at(time)
  end

  defp maybe_refresh_element_data(socket, _id, :text_series, time) do
    socket
    |> fetch_metric_units()
    |> fill_text_data_at(time)
  end

  defp maybe_refresh_element_data(socket, _id, _type, _time), do: socket

  defp icon_options(_field, nil, options), do: options
  defp icon_options(_field, "", options), do: options

  defp icon_options(_field, current, options) do
    if Enum.any?(options, fn {value, _label} -> value == current end) do
      options
    else
      [
        {"", "Auto"},
        {current, "Custom: #{current}"}
        | Enum.reject(options, fn {value, _label} -> value == "" end)
      ]
    end
  end

  def handle_event("property:update_connection", %{"conn_id" => id} = params, socket) do
    require_edit(socket, fn ->
      attrs =
        %{}
        |> maybe_put(:label, params["label"])
        |> maybe_put(:color, params["color"])
        |> maybe_put_atom(:style, params["style"])

      canvas = Canvas.update_connection(socket.assigns.canvas, id, attrs)
      {:noreply, push_canvas(socket, canvas) |> schedule_autosave()}
    end)
  end

  # Save/Load

  def handle_event("canvas:save", _params, socket) do
    require_edit(socket, fn ->
      data = Serializer.encode(socket.assigns.canvas)

      case persistence().update_canvas_data(socket.assigns.canvas_id, data) do
        {:ok, _} ->
          {:noreply, put_flash(socket, :info, "Canvas saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save canvas")}
      end
    end)
  end

  def handle_event("canvas:load", _params, socket) do
    case persistence().get_canvas(socket.assigns.canvas_id) do
      {:ok, record} ->
        case Serializer.decode(record.data) do
          {:ok, canvas} ->
            history = History.new(canvas)

            socket =
              assign(socket, history: history, canvas: canvas, selected_ids: MapSet.new())
              |> resolve_and_assign()
              |> refresh_variable_options()
              |> register_elements()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, socket}
        end

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # --- Timeline event handlers ---

  def handle_event("timeline:go_live", _params, socket) do
    {:noreply,
     socket
     |> assign(timeline_mode: :live, timeline_time: nil)
     |> refresh_data_range()
     |> fill_graph_data_at(DateTime.utc_now())
     |> push_slider_update()
     |> push_density_update()
     |> schedule_graph_refresh()}
  end

  def handle_event("timeline:change", %{"time" => center_ms}, socket)
      when is_number(center_ms) do
    half_span = div(socket.assigns.timeline_span * 1000, 2)
    time = DateTime.from_unix!(round(center_ms) + half_span, :millisecond)
    statuses = StatusManager.statuses_at(time)
    canvas = apply_statuses(socket.assigns.canvas, statuses)

    {:noreply,
     socket
     |> update_canvas(canvas)
     |> assign(timeline_mode: :historical, timeline_time: time)
     |> fill_graph_data_at(time)
     |> fill_text_data_at(time)
     |> fill_stream_data_at(time)}
  end

  def handle_event("timeline:change", %{"_target" => ["span"]} = params, socket) do
    span =
      case Integer.parse(params["span"] || "") do
        {s, _} -> s
        :error -> 900
      end

    {socket, time} =
      case socket.assigns.timeline_time do
        %DateTime{} = window_end ->
          old_half_span_ms = div(socket.assigns.timeline_span * 1000, 2)
          new_half_span_ms = div(span * 1000, 2)

          window_center_ms =
            DateTime.to_unix(window_end, :millisecond) - old_half_span_ms

          adjusted_window_end =
            DateTime.from_unix!(window_center_ms + new_half_span_ms, :millisecond)

          statuses = StatusManager.statuses_at(adjusted_window_end)
          canvas = apply_statuses(socket.assigns.canvas, statuses)

          {
            socket
            |> update_canvas(canvas)
            |> assign(timeline_span: span, timeline_time: adjusted_window_end),
            adjusted_window_end
          }

        nil ->
          updated_socket = assign(socket, timeline_span: span)
          {updated_socket, DateTime.utc_now()}
      end

    {:noreply,
     socket
     |> fill_graph_data_at(time)
     |> fill_text_data_at(time)
     |> fill_stream_data_at(time)
     |> push_slider_update()}
  end

  def handle_event("timeline:change", %{"_target" => ["range"]} = params, socket) do
    range = parse_timeline_range(params["range"])

    {socket, refresh_time?} =
      clamp_timeline_range(socket, range)

    socket =
      if refresh_time? do
        time = socket.assigns.timeline_time || DateTime.utc_now()

        socket
        |> fill_graph_data_at(time)
        |> fill_text_data_at(time)
        |> fill_stream_data_at(time)
      else
        socket
      end

    {:noreply, push_slider_update(socket)}
  end

  def handle_event("timeline:change", _params, socket) do
    {:noreply, socket}
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:element_status, element_id, status}, socket) do
    socket = update(socket, :debug_counts, &Map.update!(&1, :status_msgs, fn n -> n + 1 end))

    if socket.assigns.timeline_mode == :live do
      canvas = Canvas.set_element_status(socket.assigns.canvas, element_id, status)
      history = %{socket.assigns.history | present: canvas}
      {:noreply, assign(socket, history: history, canvas: canvas)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:element_metric, element_id, _metric_name, value, timestamp}, socket) do
    socket = update(socket, :debug_counts, &Map.update!(&1, :metric_msgs, fn n -> n + 1 end))
    _ = {element_id, value, timestamp}
    {:noreply, socket}
  end

  def handle_info({:element_text_metric, element_id, _metric_name, value, timestamp}, socket) do
    socket =
      update(socket, :debug_counts, &Map.update!(&1, :text_metric_msgs, fn n -> n + 1 end))

    if socket.assigns.timeline_mode == :live do
      text_data = Map.put(socket.assigns.text_data, element_id, {timestamp, value})
      {:noreply, assign(socket, text_data: text_data)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_entry, element_id, entry_map}, socket) do
    socket =
      update(socket, :debug_counts, &Map.update!(&1, :stream_entry_msgs, fn n -> n + 1 end))

    if @profile_skip_stream_updates do
      {:noreply, socket}
    else
      if socket.assigns.timeline_mode == :live do
        stream_data = socket.assigns.stream_data
        entries = Map.get(stream_data, element_id, [])
        entries = Enum.take([entry_map | entries], @max_stream_entries)
        stream_data = Map.put(stream_data, element_id, entries)
        {:noreply, assign(socket, stream_data: stream_data)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info({:stream_span, element_id, span_map}, socket) do
    socket = update(socket, :debug_counts, &Map.update!(&1, :stream_span_msgs, fn n -> n + 1 end))

    if @profile_skip_stream_updates do
      {:noreply, socket}
    else
      if socket.assigns.timeline_mode == :live do
        stream_data = socket.assigns.stream_data
        entries = Map.get(stream_data, element_id, [])
        entries = Enum.take([span_map | entries], @max_stream_entries)
        stream_data = Map.put(stream_data, element_id, entries)
        {:noreply, assign(socket, stream_data: stream_data)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_info(:autosave, socket) do
    if socket.assigns.can_edit do
      data = Serializer.encode(socket.assigns.canvas)
      persistence().update_canvas_data(socket.assigns.canvas_id, data)
    end

    {:noreply, socket}
  end

  def handle_info(:graph_refresh, socket) do
    socket =
      if socket.assigns.timeline_mode == :live do
        fill_graph_data_at(socket, DateTime.utc_now())
      else
        socket
      end

    {:noreply, schedule_graph_refresh(socket)}
  end

  def handle_info(:debug_report, socket) do
    counts = socket.assigns.debug_counts
    render_stats = consume_render_stats()

    Logger.info(
      "[canvas-prof] liveview canvas_id=#{socket.assigns.canvas_id} timeline_mode=#{socket.assigns.timeline_mode} " <>
        "resolved_elements=#{map_size(socket.assigns.resolved_elements)} status_msgs=#{counts.status_msgs} " <>
        "metric_msgs=#{counts.metric_msgs} text_metric_msgs=#{counts.text_metric_msgs} " <>
        "stream_entry_msgs=#{counts.stream_entry_msgs} stream_span_msgs=#{counts.stream_span_msgs} " <>
        "sorted_calls=#{render_stats.sorted_calls} sorted_time_ms=#{Float.round(render_stats.sorted_time_us / 1000, 1)} " <>
        "graph_point_calls=#{render_stats.graph_point_calls} graph_point_time_ms=#{Float.round(render_stats.graph_point_time_us / 1000, 1)} " <>
        "canvas_element_calls=#{render_stats.canvas_element_calls} canvas_element_time_ms=#{Float.round(render_stats.canvas_element_time_us / 1000, 1)} " <>
        "graph_body_calls=#{render_stats.graph_body_calls} graph_body_time_ms=#{Float.round(render_stats.graph_body_time_us / 1000, 1)} " <>
        "expanded_graph_body_calls=#{render_stats.expanded_graph_body_calls} expanded_graph_body_time_ms=#{Float.round(render_stats.expanded_graph_body_time_us / 1000, 1)} " <>
        "log_stream_body_calls=#{render_stats.log_stream_body_calls} log_stream_body_time_ms=#{Float.round(render_stats.log_stream_body_time_us / 1000, 1)} " <>
        "trace_stream_body_calls=#{render_stats.trace_stream_body_calls} trace_stream_body_time_ms=#{Float.round(render_stats.trace_stream_body_time_us / 1000, 1)}"
    )

    {:noreply,
     socket
     |> assign(:debug_counts, %{
       status_msgs: 0,
       metric_msgs: 0,
       text_metric_msgs: 0,
       stream_entry_msgs: 0,
       stream_span_msgs: 0
     })
     |> schedule_debug_report()}
  end

  # --- Guards ---

  defp require_edit(socket, fun) do
    if socket.assigns.can_edit do
      fun.()
    else
      {:noreply, socket}
    end
  end

  # --- Private helpers ---

  defp sorted_elements(elements, expanded_id) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        elements
        |> Map.values()
        |> Enum.sort_by(&{if(&1.id == expanded_id, do: 1, else: 0), &1.z_index, &1.id})
      end)

    bump_render_stat(:sorted_calls, 1)
    bump_render_stat(:sorted_time_us, elapsed_us)
    result
  end

  defp graph_points_for(%{type: :graph} = element, graph_data) do
    {elapsed_us, result} =
      :timer.tc(fn ->
        case Map.get(graph_data, element.id) do
          nil ->
            ""

          [] ->
            ""

          points ->
            points = Enum.reverse(points)
            {{first_ts, _}, {last_ts, _}} = {List.first(points), List.last(points)}
            time_range = max(last_ts - first_ts, 1)

            {_data_min, data_max} =
              Enum.min_max_by(points, &elem(&1, 1))
              |> then(fn {min, max} -> {elem(min, 1), elem(max, 1)} end)

            meta = element.meta || %{}
            min_val = graph_min_bound(meta, points)
            max_val = parse_bound(meta["y_max"], data_max)
            val_range = max(max_val - min_val, 0.1)
            padding = 14

            points
            |> Enum.map(fn {ts, val} ->
              x = element.x + (ts - first_ts) / time_range * element.width
              clamped = max(min(val, max_val), min_val)

              y =
                element.y + padding +
                  (1 - (clamped - min_val) / val_range) * (element.height - padding - 2)

              "#{Float.round(x, 1)},#{Float.round(y, 1)}"
            end)
            |> Enum.join(" ")
        end
      end)

    bump_render_stat(:graph_point_calls, 1)
    bump_render_stat(:graph_point_time_us, elapsed_us)
    result
  end

  defp graph_points_for(_element, _graph_data), do: ""

  defp graph_data_points_for(%{type: :graph} = element, graph_data) do
    Map.get(graph_data, element.id, [])
  end

  defp graph_data_points_for(_element, _graph_data), do: []

  defp parse_bound(nil, fallback), do: fallback
  defp parse_bound("", fallback), do: fallback

  defp parse_bound(str, fallback) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> fallback
    end
  end

  defp graph_min_bound(meta, points) do
    {data_min, _data_max} =
      Enum.min_max_by(points, &elem(&1, 1))
      |> then(fn {min, max} -> {elem(min, 1), elem(max, 1)} end)

    cond do
      explicit_nonzero_bound?(meta["y_min"]) ->
        parse_bound(meta["y_min"], data_min)

      counter_series?(meta) ->
        data_min

      true ->
        parse_bound(meta["y_min"], 0.0)
    end
  end

  defp explicit_nonzero_bound?(nil), do: false
  defp explicit_nonzero_bound?(""), do: false

  defp explicit_nonzero_bound?(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} when parsed == 0.0 -> false
      {_nonzero, _} -> true
      :error -> false
    end
  end

  defp counter_series?(meta) when is_map(meta) do
    case Map.get(meta, "type") do
      "counter32" -> true
      "counter64" -> true
      _ -> false
    end
  end

  defp counter_series?(_meta), do: false

  defp graph_value_for(%{type: :graph} = element, graph_data, metric_units) do
    case Map.get(graph_data, element.id) do
      [{_ts, val} | _] ->
        unit = Map.get(metric_units, element.id)
        MetricFormatter.format(val / 1.0, unit)

      _ ->
        nil
    end
  end

  defp graph_value_for(_element, _graph_data, _metric_units), do: nil

  defp backfill_graph(socket, %{type: :graph} = el) do
    time = socket.assigns.timeline_time || DateTime.utc_now()
    span = socket.assigns.timeline_span
    from = DateTime.add(time, -span, :second)
    metric_name = Map.get(el.meta, "metric_name", "default")

    points =
      case StatusManager.metric_range(el.id, metric_name, from, time) do
        {:ok, pts} when pts != [] -> downsample(pts, @max_graph_points)
        _ -> []
      end

    graph_data = Map.put(socket.assigns.graph_data, el.id, points)
    assign(socket, graph_data: graph_data)
  end

  defp backfill_graph(socket, _el), do: socket

  defp fill_graph_data_at(socket, time) do
    trace_canvas_span(
      "canvas.fill_graph_data",
      %{
        "canvas.id" => socket.assigns.canvas_id,
        "canvas.timeline_mode" => to_string(socket.assigns.timeline_mode),
        "canvas.timeline_span_seconds" => socket.assigns.timeline_span,
        "canvas.query_time_unix_ms" => DateTime.to_unix(time, :millisecond),
        "canvas.graph_count" => count_elements(socket.assigns.resolved_elements, :graph),
        "canvas.expanded_graph" => socket.assigns.expanded_graph_id || ""
      },
      fn ->
        graph_elements =
          socket.assigns.resolved_elements
          |> Enum.filter(fn {_id, el} -> el.type == :graph end)

        span = socket.assigns.timeline_span
        from = DateTime.add(time, -span, :second)

        graph_data =
          Enum.reduce(graph_elements, socket.assigns.graph_data, fn {id, element}, acc ->
            metric_name = Map.get(element.meta, "metric_name", "default")

            points =
              case StatusManager.metric_range(id, metric_name, from, time) do
                {:ok, pts} when pts != [] ->
                  downsample(pts, @max_graph_points)

                _ ->
                  []
              end

            Map.put(acc, id, points)
          end)

        socket = assign(socket, graph_data: graph_data)

        case socket.assigns.expanded_graph_id do
          nil ->
            socket

          expanded_id ->
            expanded_data = fetch_expanded_data(socket, expanded_id)
            assign(socket, expanded_graph_data: expanded_data)
        end
      end
    )
  end

  defp fill_text_data_at(socket, time) do
    trace_canvas_span(
      "canvas.fill_text_data",
      %{
        "canvas.id" => socket.assigns.canvas_id,
        "canvas.timeline_mode" => to_string(socket.assigns.timeline_mode),
        "canvas.timeline_span_seconds" => socket.assigns.timeline_span,
        "canvas.query_time_unix_ms" => DateTime.to_unix(time, :millisecond),
        "canvas.text_series_count" =>
          count_elements(socket.assigns.resolved_elements, :text_series)
      },
      fn ->
        text_elements =
          socket.assigns.resolved_elements
          |> Enum.filter(fn {_id, el} -> el.type == :text_series end)

        text_data =
          Enum.reduce(text_elements, socket.assigns.text_data, fn {id, element}, acc ->
            metric_name = Map.get(element.meta, "metric_name", "default")

            case StatusManager.text_metric_at(id, metric_name, time) do
              {:ok, value} -> Map.put(acc, id, {DateTime.to_unix(time, :millisecond), value})
              :no_data -> acc
            end
          end)

        assign(socket, text_data: text_data)
      end
    )
  end

  defp fetch_expanded_data(socket, element_id) do
    trace_canvas_span(
      "canvas.fetch_expanded_graph",
      %{
        "canvas.id" => socket.assigns.canvas_id,
        "canvas.element_id" => element_id,
        "canvas.timeline_mode" => to_string(socket.assigns.timeline_mode),
        "canvas.timeline_span_seconds" => socket.assigns.timeline_span
      },
      fn ->
        case Map.get(socket.assigns.resolved_elements, element_id) do
          %{type: :graph} = element ->
            metric_name = Map.get(element.meta, "metric_name", "default")
            span = socket.assigns.timeline_span
            time = socket.assigns.timeline_time || DateTime.utc_now()
            from = DateTime.add(time, -span, :second)

            case StatusManager.metric_range(element_id, metric_name, from, time) do
              {:ok, pts} when pts != [] -> downsample(pts, @max_graph_points_expanded)
              _ -> []
            end

          _ ->
            []
        end
      end
    )
  end

  defp downsample(points, max_count) when length(points) <= max_count do
    Enum.reverse(points)
  end

  defp downsample(points, max_count) do
    total = length(points)
    step = total / max_count

    0..(max_count - 1)
    |> Enum.map(fn i -> Enum.at(points, round(i * step)) end)
    |> Enum.reverse()
  end

  defp fill_stream_data_at(socket, time) do
    trace_canvas_span(
      "canvas.fill_stream_data",
      %{
        "canvas.id" => socket.assigns.canvas_id,
        "canvas.timeline_mode" => to_string(socket.assigns.timeline_mode),
        "canvas.timeline_span_seconds" => socket.assigns.timeline_span,
        "canvas.query_time_unix_ms" => DateTime.to_unix(time, :millisecond),
        "canvas.log_stream_count" =>
          count_elements(socket.assigns.resolved_elements, :log_stream),
        "canvas.trace_stream_count" =>
          count_elements(socket.assigns.resolved_elements, :trace_stream)
      },
      fn ->
        span = socket.assigns.timeline_span
        from = DateTime.add(time, -span, :second)
        backends = TimelessCanvas.stream_backends()

        stream_elements =
          socket.assigns.resolved_elements
          |> Enum.filter(fn {_id, el} -> el.type in [:log_stream, :trace_stream] end)

        stream_data =
          Enum.reduce(stream_elements, socket.assigns.stream_data, fn {id, element}, acc ->
            entries = query_stream_historical(element, from, time, backends)
            Map.put(acc, id, entries)
          end)

        assign(socket, stream_data: stream_data)
      end
    )
  end

  defp count_elements(elements, type) do
    Enum.count(elements, fn
      {_id, %{type: ^type}} -> true
      _ -> false
    end)
  end

  defp trace_canvas_span(name, attributes, fun) when is_function(fun, 0) do
    if otel_available?() do
      tracer = apply(:opentelemetry, :get_application_tracer, [__MODULE__])

      apply(:otel_tracer, :with_span, [
        tracer,
        name,
        %{attributes: attributes},
        fn _span_ctx ->
          try do
            fun.()
          rescue
            exception ->
              maybe_record_exception(exception, __STACKTRACE__)
              maybe_set_span_status(:error, Exception.message(exception))
              reraise(exception, __STACKTRACE__)
          catch
            kind, reason ->
              maybe_set_span_status(:error, Exception.format_banner(kind, reason))
              :erlang.raise(kind, reason, __STACKTRACE__)
          end
        end
      ])
    else
      fun.()
    end
  end

  defp otel_available? do
    Code.ensure_loaded?(:opentelemetry) and Code.ensure_loaded?(:otel_tracer) and
      Code.ensure_loaded?(OpenTelemetry.Tracer)
  end

  defp maybe_record_exception(exception, stacktrace) do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      apply(OpenTelemetry.Tracer, :record_exception, [exception, stacktrace])
    end
  end

  defp maybe_set_span_status(code, message) do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      apply(OpenTelemetry.Tracer, :set_status, [code, message])
    end
  end

  defp query_stream_historical(%{type: :log_stream} = element, from, to, backends) do
    case Keyword.get(backends, :log) do
      nil ->
        []

      backend ->
        filters =
          build_log_opts(element.meta)
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: entries}} ->
            Enum.map(entries, fn e ->
              %{
                timestamp: e.timestamp,
                level: e.level,
                message: e.message,
                metadata: e.metadata
              }
            end)

          _ ->
            []
        end
    end
  end

  defp query_stream_historical(%{type: :trace_stream} = element, from, to, backends) do
    case Keyword.get(backends, :trace) do
      nil ->
        []

      backend ->
        filters =
          build_trace_opts(element.meta)
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: spans}} ->
            Enum.map(spans, fn s ->
              %{
                timestamp: Map.get(s, :start_time) || Map.get(s, :timestamp),
                trace_id: s.trace_id,
                span_id: s.span_id,
                name: s.name,
                kind: s.kind,
                duration_ns: s.duration_ns,
                status: s.status,
                status_message: s.status_message,
                service: get_span_service(s)
              }
            end)

          _ ->
            []
        end
    end
  end

  defp query_stream_historical(_element, _from, _to, _backends), do: []

  defp get_span_service(span) do
    cond do
      is_map(span.attributes) && Map.has_key?(span.attributes, "service.name") ->
        span.attributes["service.name"]

      is_map(span.resource) && Map.has_key?(span.resource, "service.name") ->
        span.resource["service.name"]

      true ->
        nil
    end
  end

  defp refresh_data_range(socket) do
    case StatusManager.time_range() do
      :empty -> assign(socket, timeline_data_range: nil)
      range -> assign(socket, timeline_data_range: range)
    end
  end

  defp maybe_seed_historical_timeline(socket) do
    now = DateTime.utc_now()
    live_window_start = DateTime.add(now, -socket.assigns.timeline_span, :second)

    case socket.assigns.timeline_data_range do
      {_data_start, %DateTime{} = newest} ->
        if DateTime.compare(newest, live_window_start) == :lt do
          assign(socket, timeline_mode: :historical, timeline_time: newest)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp push_slider_update(socket) do
    now_ms = System.system_time(:millisecond)
    span_ms = socket.assigns.timeline_span * 1000
    half_span = div(span_ms, 2)

    window_end_ms =
      case socket.assigns.timeline_time do
        nil -> now_ms
        %DateTime{} = t -> DateTime.to_unix(t, :millisecond)
      end

    is_live = socket.assigns.timeline_time == nil

    {slider_min, slider_max} =
      timeline_slider_bounds(
        socket.assigns.timeline_data_range,
        socket.assigns.timeline_range,
        window_end_ms,
        span_ms,
        half_span,
        is_live,
        now_ms
      )

    value =
      (window_end_ms - half_span)
      |> max(slider_min + half_span)
      |> min(slider_max - half_span)

    window_ratio = min(span_ms / max(slider_max - slider_min, 1), 1.0)

    push_event(socket, "update-slider", %{
      min: slider_min,
      max: slider_max,
      value: value,
      windowRatio: window_ratio,
      live: is_live
    })
  end

  defp push_density_update(socket) do
    case socket.assigns.timeline_data_range do
      {data_start, data_end} ->
        buckets = StatusManager.data_density(data_start, data_end, 80)
        push_event(socket, "update-density", %{buckets: buckets})

      _ ->
        push_event(socket, "update-density", %{buckets: []})
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

  defp parse_timeline_range("all"), do: :all

  defp parse_timeline_range(value) do
    case Integer.parse(to_string(value || "")) do
      {seconds, _} when seconds > 0 -> seconds
      _ -> 86_400
    end
  end

  defp clamp_timeline_range(socket, range) do
    socket = assign(socket, timeline_range: range)

    case socket.assigns.timeline_time do
      %DateTime{} = window_end ->
        now_ms = System.system_time(:millisecond)
        span_ms = socket.assigns.timeline_span * 1000
        half_span = div(span_ms, 2)
        window_end_ms = DateTime.to_unix(window_end, :millisecond)

        {slider_min, slider_max} =
          timeline_slider_bounds(
            socket.assigns.timeline_data_range,
            socket.assigns.timeline_range,
            window_end_ms,
            span_ms,
            half_span,
            false,
            now_ms
          )

        clamped_window_end_ms =
          window_end_ms
          |> max(slider_min + span_ms)
          |> min(slider_max)

        if clamped_window_end_ms == window_end_ms do
          {socket, false}
        else
          time = DateTime.from_unix!(clamped_window_end_ms, :millisecond)
          statuses = StatusManager.statuses_at(time)
          canvas = apply_statuses(socket.assigns.canvas, statuses)

          {
            socket
            |> update_canvas(canvas)
            |> assign(timeline_mode: :historical, timeline_time: time),
            true
          }
        end

      nil ->
        {socket, false}
    end
  end

  defp text_value_for(%{type: :text_series} = element, text_data) do
    case Map.get(text_data, element.id) do
      {_ts, val} -> val
      _ -> nil
    end
  end

  defp text_value_for(_element, _text_data), do: nil

  defp stream_entries_for(%{type: type} = element, stream_data)
       when type in [:log_stream, :trace_stream] do
    max_rows = max(floor((element.height - 24) / 14), 1)
    Enum.take(Map.get(stream_data, element.id, []), max_rows)
  end

  defp stream_entries_for(_element, _stream_data), do: []

  defp register_stream_elements(elements) do
    Enum.reduce(elements, %{}, fn {_id, el}, acc ->
      case el.type do
        :log_stream ->
          opts = build_log_opts(el.meta)
          StreamManager.register_log_stream(el.id, opts)
          Map.put(acc, el.id, StreamManager.get_buffer(el.id))

        :trace_stream ->
          opts = build_trace_opts(el.meta)
          StreamManager.register_trace_stream(el.id, opts)
          Map.put(acc, el.id, StreamManager.get_buffer(el.id))

        _ ->
          acc
      end
    end)
  end

  defp build_log_opts(meta) do
    opts = []

    opts =
      case Map.get(meta, "host") do
        nil -> opts
        "" -> opts
        host -> Keyword.put(opts, :metadata, %{"host" => host})
      end

    opts =
      case Map.get(meta, "level") do
        nil -> opts
        "" -> opts
        level -> Keyword.put(opts, :level, String.to_existing_atom(level))
      end

    case Map.get(meta, "metadata_filter") do
      nil ->
        opts

      "" ->
        opts

      filter_str ->
        metadata =
          filter_str
          |> String.split(",")
          |> Enum.reduce(%{}, fn pair, acc ->
            case String.split(String.trim(pair), "=", parts: 2) do
              [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
              _ -> acc
            end
          end)

        if map_size(metadata) > 0 do
          merged =
            opts
            |> Keyword.get(:metadata, %{})
            |> Map.merge(metadata)

          Keyword.put(opts, :metadata, merged)
        else
          opts
        end
    end
  end

  defp build_trace_opts(meta) do
    opts = []

    opts =
      case Map.get(meta, "host") do
        nil ->
          opts

        "" ->
          opts

        host ->
          Keyword.put(opts, :attributes, %{"host.name" => host})
      end

    opts =
      case Map.get(meta, "service") do
        nil -> opts
        "" -> opts
        svc -> Keyword.put(opts, :service, svc)
      end

    opts =
      case Map.get(meta, "name") do
        nil -> opts
        "" -> opts
        name -> Keyword.put(opts, :name, name)
      end

    case Map.get(meta, "kind") do
      nil -> opts
      "" -> opts
      kind -> Keyword.put(opts, :kind, String.to_existing_atom(kind))
    end
  end

  defp fetch_metric_units(socket) do
    units =
      socket.assigns.resolved_elements
      |> Enum.filter(fn {_id, el} -> el.type == :graph end)
      |> Enum.reduce(%{}, fn {id, el}, acc ->
        metric_name = Map.get(el.meta || %{}, "metric_name")

        if metric_name do
          case StatusManager.metric_metadata(metric_name) do
            {:ok, %{unit: unit}} when not is_nil(unit) -> Map.put(acc, id, unit)
            _ -> acc
          end
        else
          acc
        end
      end)

    assign(socket, metric_units: units)
  end

  defp refresh_discovered_hosts(socket) do
    hosts = StatusManager.list_hosts()
    first = List.first(hosts)
    assign(socket, discovered_hosts: hosts, place_host: first)
  end

  defp refresh_pin_ifnames(socket) do
    pin_ifnames = StatusManager.list_label_values("ifname") || []
    assign(socket, pin_ifnames: pin_ifnames)
  end

  defp place_host_element(socket, host, x, y) do
    type = socket.assigns.place_host_type
    defaults = Element.defaults_for(type)
    canvas = socket.assigns.canvas

    variables =
      case canvas.variables["host"] do
        nil ->
          Map.put(canvas.variables, "host", %{"type" => "host", "current" => host})

        existing ->
          Map.put(canvas.variables, "host", Map.put(existing, "current", host))
      end

    canvas = %{canvas | variables: variables}

    {canvas, el} =
      Canvas.add_element(canvas, %{
        type: type,
        x: x,
        y: y,
        color: defaults.color,
        width: defaults.width,
        height: defaults.height,
        label: "$host",
        meta: %{"host" => "$host"}
      })

    bindings = VariableResolver.bindings(canvas.variables)
    resolved_el = VariableResolver.resolve_element(el, bindings)
    StatusManager.register_elements([resolved_el])

    socket =
      socket
      |> push_canvas(canvas)
      |> refresh_variable_options()
      |> assign(selected_ids: MapSet.new([el.id]))
      |> fetch_series_for_selected(el.id)
      |> schedule_autosave()

    {:noreply, socket}
  end

  defp place_typed_element(socket, type, x, y) do
    defaults = Element.defaults_for(type)

    meta =
      if type == :canvas do
        case persistence().create_child_canvas(
               socket.assigns.canvas_id,
               "Sub-canvas #{socket.assigns.canvas.next_id}"
             ) do
          {:ok, child} -> %{"canvas_id" => to_string(child.id)}
          {:error, _} -> %{}
        end
      else
        %{}
      end

    {canvas, _el} =
      Canvas.add_element(socket.assigns.canvas, %{
        type: type,
        x: x,
        y: y,
        color: defaults.color,
        width: defaults.width,
        height: defaults.height,
        label: "#{type |> to_string() |> String.capitalize()} #{socket.assigns.canvas.next_id}",
        meta: meta
      })

    {:noreply,
     socket
     |> push_canvas(canvas)
     |> assign(mode: :select, place_kind: :host)
     |> schedule_autosave()}
  end

  defp find_open_position(elements, anchor_x, anchor_y, width, height, gap \\ 20) do
    others = Map.values(elements)

    # Try placing below the anchor, scanning downward
    find_clear_y(others, anchor_x, anchor_y, width, height, gap)
  end

  defp find_clear_y(others, x, y, w, h, gap) do
    if overlaps_any?(others, x, y, w, h) do
      # Find the bottom edge of the overlapping element(s) and try below it
      next_y =
        others
        |> Enum.filter(&boxes_overlap?(&1.x, &1.y, &1.width, &1.height, x, y, w, h))
        |> Enum.map(&(&1.y + &1.height + gap))
        |> Enum.max()

      find_clear_y(others, x, next_y, w, h, gap)
    else
      {x, y}
    end
  end

  defp overlaps_any?(others, x, y, w, h) do
    Enum.any?(others, &boxes_overlap?(&1.x, &1.y, &1.width, &1.height, x, y, w, h))
  end

  defp boxes_overlap?(ax, ay, aw, ah, bx, by, bw, bh) do
    ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
  end

  defp fetch_series_for_selected(socket, element_id) do
    case Map.get(socket.assigns.resolved_elements, element_id) do
      %Element{meta: meta} when is_map(meta) ->
        host = meta["host"] || meta["service_name"]

        if host && host != "" do
          series = StatusManager.list_series_for_host(host)
          assign(socket, available_series: series)
        else
          assign(socket, available_series: [])
        end

      _ ->
        assign(socket, available_series: [])
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_float(map, _key, nil), do: map
  defp maybe_put_float(map, _key, ""), do: map

  defp maybe_put_float(map, key, val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> Map.put(map, key, f)
      :error -> map
    end
  end

  defp clamp_view_box(%ViewBox{} = vb) do
    zoomed_width =
      @base_viewbox_width * 100.0 /
        min(max(zoom_percentage(vb), @min_zoom_percent), @max_zoom_percent)

    scale = zoomed_width / vb.width

    %ViewBox{
      min_x: vb.min_x,
      min_y: vb.min_y,
      width: zoomed_width,
      height: vb.height * scale
    }
  end

  defp content_center(elements, %ViewBox{} = vb) when map_size(elements) == 0 do
    {vb.min_x + vb.width / 2, vb.min_y + vb.height / 2}
  end

  defp content_center(elements, _vb) do
    list = Map.values(elements)
    min_x = list |> Enum.map(& &1.x) |> Enum.min()
    min_y = list |> Enum.map(& &1.y) |> Enum.min()
    max_x = list |> Enum.map(&(&1.x + &1.width)) |> Enum.max()
    max_y = list |> Enum.map(&(&1.y + &1.height)) |> Enum.max()
    {(min_x + max_x) / 2, (min_y + max_y) / 2}
  end

  defp maybe_put_float(map, key, val) when is_number(val) do
    Map.put(map, key, val / 1.0)
  end

  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, _key, ""), do: map

  defp maybe_put_atom(map, key, val) when is_binary(val) do
    Map.put(map, key, String.to_existing_atom(val))
  end
end

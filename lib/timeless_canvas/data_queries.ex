defmodule TimelessCanvas.DataQueries do
  @moduledoc """
  Pure data-source query helpers shared by `TimelessCanvas.Web.CanvasLive`
  and `TimelessCanvas.CanvasPoller`.

  Every function takes plain data (resolved elements, a time, a span) and
  returns plain data — no socket, no process state — so the same code can
  run inside a LiveView, an async task, or the per-canvas poller. Queries
  execute in the calling process (see `TimelessCanvas.DataSource.Manager`);
  per-element fan-out uses `Task.async_stream` with bounded concurrency.
  """

  alias TimelessCanvas.DataSource.Manager

  @max_graph_points 60
  @max_graph_points_expanded 300
  @max_stream_entries 50
  @default_top_limit 10
  @max_top_limit 50
  @max_window 86_400
  @aggregates ~w(sum avg max min)
  # Per-element queries run in the caller process; fan them out with
  # bounded concurrency so backend I/O overlaps.
  @element_query_concurrency 8
  @element_query_timeout 5_000

  @doc "Maximum number of entries kept per stream element."
  def max_stream_entries, do: @max_stream_entries

  @doc """
  Stamp a stable `:id` onto a stream entry map, derived from its content.

  Historical fills (`query_stream_data/3`) and live prepends
  (`TimelessCanvas.StreamManager`) build entry maps with the same keys,
  so the same entry always gets the same id no matter which path
  delivered it. Rows carry only this id in the DOM and
  `stream:entry_click` resolves it against `stream_data`, which cannot
  race live prepends the way the old index-based lookup did.
  """
  def put_entry_id(entry) when is_map(entry) do
    id =
      entry
      |> Map.delete(:id)
      |> Map.delete("id")
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 12)
      |> Base.url_encode64(padding: false)

    Map.put(entry, :id, id)
  end

  @doc """
  Latest graph window for every graph-type element:
  `%{id => [{ts, val}] | :error}`.

  A backend query error is distinguishable from "no data": the element
  maps to `:error` instead of `[]`, so a down backend does not render
  identically to an empty series. A later successful query replaces the
  `:error` entry, so the state recovers on its own.
  """
  def query_graph_data(canvas_id, resolved_elements, time, span) do
    from = DateTime.add(time, -span, :second)

    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :graph end)
    |> concurrent_element_query(fn {id, element} ->
      metric_name = Map.get(element.meta || %{}, "metric_name", "default")
      opts = build_range_opts(element.meta)

      points =
        case Manager.metric_range(canvas_id, id, metric_name, from, time, opts) do
          {:ok, pts} -> downsample(pts, @max_graph_points)
          {:error, _reason} -> :error
          _ -> []
        end

      {id, points}
    end)
  end

  @doc """
  Text metric values for every text_series element:
  `%{id => {unix_ms, value} | :error}`. Elements without data are omitted;
  elements whose query errored map to `:error` (see `query_graph_data/4`).
  """
  def query_text_data(canvas_id, resolved_elements, time) do
    timestamp = DateTime.to_unix(time, :millisecond)

    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :text_series end)
    |> concurrent_element_query(fn {id, element} ->
      metric_name = Map.get(element.meta || %{}, "metric_name", "default")

      case Manager.text_metric_at(canvas_id, id, metric_name, time) do
        {:ok, value} -> {id, {timestamp, value}}
        {:error, _reason} -> {id, :error}
        :no_data -> :skip
      end
    end)
  end

  @doc """
  Ranked rows for every top_n element: `%{id => {unix_ms, [row]} | :error}`,
  each row `%{labels: map, value: number}` in rank order.

  Elements with no metric chosen are omitted, as are all of them when the
  backend cannot rank (the element type is not offered then, but a canvas
  authored against another backend may still hold one).
  """
  def query_top_data(canvas_id, resolved_elements, time) do
    timestamp = DateTime.to_unix(time, :millisecond)

    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :top_n end)
    |> concurrent_element_query(fn {id, element} ->
      meta = element.meta || %{}

      case Map.get(meta, "metric_name") do
        metric_name when is_binary(metric_name) and metric_name != "" ->
          opts = build_top_opts(meta)

          case Manager.top_series(canvas_id, id, metric_name, time, opts) do
            {:ok, rows} when is_list(rows) -> {id, {timestamp, top_rows(rows, opts[:limit])}}
            :unsupported -> :skip
            _ -> {id, :error}
          end

        _ ->
          :skip
      end
    end)
  end

  @doc """
  Latest value for every element that shows one: text_series and top_n,
  keyed by element id. Both refresh on the same tick and travel in the same
  diff, so callers query and merge them together.
  """
  def query_value_data(canvas_id, resolved_elements, time) do
    Map.merge(
      query_text_data(canvas_id, resolved_elements, time),
      query_top_data(canvas_id, resolved_elements, time)
    )
  end

  @doc """
  Historical stream entries for every log/trace stream element:
  `%{id => [entry_map] | :error}`. A backend query error maps the element
  to `:error` (distinct from an empty backfill); a missing backend maps
  to `[]` (nothing to query is not an error).
  """
  def query_stream_data(resolved_elements, time, span) do
    from = DateTime.add(time, -span, :second)
    backends = TimelessCanvas.stream_backends()

    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type in [:log_stream, :trace_stream] end)
    |> concurrent_element_query(fn {id, element} ->
      {id, query_stream_historical(element, from, time, backends)}
    end)
  end

  @doc """
  High-resolution point list for one expanded graph element (`:error`
  when the backend query fails, mirroring `query_graph_data/4`).
  """
  def query_expanded_data(canvas_id, resolved_elements, element_id, time, span) do
    case Map.get(resolved_elements, element_id) do
      %{type: :graph} = element ->
        metric_name = Map.get(element.meta || %{}, "metric_name", "default")
        from = DateTime.add(time, -span, :second)
        opts = build_range_opts(element.meta)

        case Manager.metric_range(canvas_id, element_id, metric_name, from, time, opts) do
          {:ok, pts} -> downsample(pts, @max_graph_points_expanded)
          {:error, _reason} -> :error
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc "Data range of the active source, or nil when empty."
  def query_data_range do
    case Manager.time_range() do
      :empty -> nil
      range -> range
    end
  end

  @doc "Bounded host probe: `{hosts_available?, first_host_or_nil}`."
  def query_host_probe do
    hosts =
      case Manager.list_hosts(limit: 1) do
        {:ok, hosts} when is_list(hosts) -> hosts
        hosts when is_list(hosts) -> hosts
        _ -> []
      end

    {hosts != [], List.first(hosts)}
  end

  @doc """
  Metric units per graph and top_n element id, from metric metadata.

  A top_n element ranks counters by rate, so a counter's unit would mislabel
  its values (CPU seconds per second are not seconds) and is left out.
  """
  def query_metric_units(resolved_elements) do
    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type in [:graph, :top_n] end)
    |> concurrent_element_query(fn {id, el} ->
      metric_name = Map.get(el.meta || %{}, "metric_name")

      if metric_name do
        case Manager.metric_metadata(metric_name) do
          {:ok, %{} = metadata} -> unit_for(id, el.type, metadata)
          _ -> :skip
        end
      else
        :skip
      end
    end)
  end

  defp unit_for(id, type, metadata) do
    unit = Map.get(metadata, :unit) || Map.get(metadata, "unit")
    counter? = to_string(Map.get(metadata, :type) || Map.get(metadata, "type")) == "counter"

    if is_nil(unit) or (type == :top_n and counter?), do: :skip, else: {id, unit}
  end

  @doc "Event density buckets over a data range (empty list without one)."
  def query_density_buckets({%DateTime{} = data_start, %DateTime{} = data_end}) do
    Manager.data_density(data_start, data_end, 80)
  end

  def query_density_buckets(_data_range), do: []

  @doc """
  Fan out one query per element with bounded concurrency; results are
  keyed by element id. Timed-out or crashed queries map to `:error`, so
  callers can distinguish a failed backend from an empty result.
  A `fun` returning `:skip` omits the element from the result.
  """
  def concurrent_element_query(elements, fun) do
    elements = Enum.to_list(elements)

    results =
      Task.async_stream(elements, &safe_element_query(&1, fun),
        max_concurrency: @element_query_concurrency,
        ordered: true,
        timeout: @element_query_timeout,
        on_timeout: :kill_task
      )

    elements
    |> Enum.zip(results)
    |> Enum.reduce(%{}, fn
      {_element, {:ok, :skip}}, acc -> acc
      {_element, {:ok, {:query_error, id}}}, acc -> Map.put(acc, id, :error)
      {_element, {:ok, {id, value}}}, acc -> Map.put(acc, id, value)
      {{id, _element}, {:exit, _reason}}, acc -> Map.put(acc, id, :error)
    end)
  end

  defp safe_element_query({id, _element} = item, fun) do
    fun.(item)
  rescue
    _error -> {:query_error, id}
  catch
    _kind, _reason -> {:query_error, id}
  end

  @doc """
  Build `metric_range/6` opts from a graph element's meta: `:aggregate` and
  `:window`, each only when the element sets it.
  """
  def build_range_opts(meta) do
    meta = if is_map(meta), do: meta, else: %{}

    meta
    |> window_opts()
    |> maybe_put_known_atom(:aggregate, Map.get(meta, "aggregate"), @aggregates)
  end

  @doc """
  Build `top_series/5` opts from a top_n element's meta. Every option but
  `:window` is present, and all are bounded, so a backend never has to defend
  against a blank or oversized value typed into the properties panel.

  `:window` has no default here. How long a sample stays current depends on
  how often the series are sampled, which the backend knows and the canvas
  does not.
  """
  def build_top_opts(meta) do
    meta = if is_map(meta), do: meta, else: %{}

    [
      group_by: parse_group_by(Map.get(meta, "group_by")),
      limit: bounded_integer(Map.get(meta, "limit"), @default_top_limit, @max_top_limit)
    ]
    |> Keyword.merge(window_opts(meta))
    |> Keyword.merge(
      maybe_put_known_atom([order: :desc], :order, Map.get(meta, "order"), ~w(desc asc))
    )
    |> Keyword.merge(
      maybe_put_known_atom([aggregate: :sum], :aggregate, Map.get(meta, "aggregate"), @aggregates)
    )
  end

  @doc "Build stream-backend query opts from a log_stream element's meta."
  def build_log_opts(meta) do
    meta = if is_map(meta), do: meta, else: %{}
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
        level -> maybe_put_known_atom(opts, :level, level, ~w(all debug info warning error))
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

  @doc "Build stream-backend query opts from a trace_stream element's meta."
  def build_trace_opts(meta) do
    meta = if is_map(meta), do: meta, else: %{}
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
      nil ->
        opts

      "" ->
        opts

      kind ->
        maybe_put_known_atom(
          opts,
          :kind,
          kind,
          ~w(unspecified internal server client producer consumer)
        )
    end
  end

  # --- Private ---

  defp parse_group_by(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_group_by(_value), do: []

  defp window_opts(meta) do
    case bounded_integer(Map.get(meta, "window"), nil, @max_window) do
      nil -> []
      seconds -> [window: seconds]
    end
  end

  defp bounded_integer(value, default, max) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n > 0 -> min(n, max)
      _ -> default
    end
  end

  # Rows cross a behaviour boundary, so keep only well-formed ones and never
  # more than were asked for.
  defp top_rows(rows, limit) do
    rows
    |> Enum.flat_map(fn
      %{labels: labels, value: value} when is_map(labels) and is_number(value) ->
        [%{labels: labels, value: value}]

      _ ->
        []
    end)
    |> Enum.take(limit)
  end

  defp downsample(points, max_count)
       when is_list(points) and is_integer(max_count) and max_count > 1 do
    total = length(points)

    if total <= max_count do
      Enum.reverse(points)
    else
      tuple = List.to_tuple(points)
      last_index = total - 1

      for i <- 0..(max_count - 1) do
        elem(tuple, round(i * last_index / (max_count - 1)))
      end
      |> Enum.reverse()
    end
  end

  defp downsample(_points, _max_count), do: []

  defp query_stream_historical(%{type: :log_stream} = element, from, to, backends) do
    case Keyword.get(backends, :log) do
      nil ->
        []

      backend ->
        filters =
          build_log_opts(element.meta || %{})
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: entries}} ->
            Enum.map(entries, fn e ->
              put_entry_id(%{
                timestamp: value(e, :timestamp),
                level: value(e, :level),
                message: value(e, :message, ""),
                metadata: value(e, :metadata, %{})
              })
            end)

          _ ->
            :error
        end
    end
  end

  defp query_stream_historical(%{type: :trace_stream} = element, from, to, backends) do
    case Keyword.get(backends, :trace) do
      nil ->
        []

      backend ->
        filters =
          build_trace_opts(element.meta || %{})
          |> Keyword.put(:since, from)
          |> Keyword.put(:until, to)
          |> Keyword.put(:limit, @max_stream_entries)
          |> Keyword.put(:order, :desc)

        case backend.query(filters) do
          {:ok, %{entries: spans}} ->
            Enum.map(spans, fn s ->
              put_entry_id(%{
                timestamp: value(s, :start_time) || value(s, :timestamp),
                trace_id: value(s, :trace_id),
                span_id: value(s, :span_id),
                name: value(s, :name, ""),
                kind: value(s, :kind),
                duration_ns: value(s, :duration_ns),
                status: value(s, :status),
                status_message: value(s, :status_message),
                service: get_span_service(s)
              })
            end)

          _ ->
            :error
        end
    end
  end

  defp query_stream_historical(_element, _from, _to, _backends), do: []

  defp get_span_service(span) do
    attributes = value(span, :attributes, %{})
    resource = value(span, :resource, %{})

    cond do
      is_map(attributes) && Map.has_key?(attributes, "service.name") ->
        attributes["service.name"]

      is_map(resource) && Map.has_key?(resource, "service.name") ->
        resource["service.name"]

      true ->
        nil
    end
  end

  defp maybe_put_known_atom(opts, key, value, allowed) when is_atom(value) do
    if Atom.to_string(value) in allowed, do: Keyword.put(opts, key, value), else: opts
  end

  defp maybe_put_known_atom(opts, key, value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(&1 == value)) do
      nil -> opts
      known -> Keyword.put(opts, key, String.to_existing_atom(known))
    end
  end

  defp maybe_put_known_atom(opts, _key, _value, _allowed), do: opts

  defp value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, nil} -> Map.get(map, Atom.to_string(key), default)
      {:ok, found} -> found
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end

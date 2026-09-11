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

      points =
        case Manager.metric_range(canvas_id, id, metric_name, from, time) do
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

        case Manager.metric_range(canvas_id, element_id, metric_name, from, time) do
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

  @doc "Metric units per graph element id, from metric metadata."
  def query_metric_units(resolved_elements) do
    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :graph end)
    |> concurrent_element_query(fn {id, el} ->
      metric_name = Map.get(el.meta || %{}, "metric_name")

      if metric_name do
        case Manager.metric_metadata(metric_name) do
          {:ok, %{unit: unit}} when not is_nil(unit) -> {id, unit}
          {:ok, %{"unit" => unit}} when not is_nil(unit) -> {id, unit}
          _ -> :skip
        end
      else
        :skip
      end
    end)
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

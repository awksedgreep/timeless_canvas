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
  @element_query_timeout 30_000

  @doc "Maximum number of entries kept per stream element."
  def max_stream_entries, do: @max_stream_entries

  @doc """
  Latest graph window for every graph-type element: `%{id => [{ts, val}]}`.
  """
  def query_graph_data(resolved_elements, time, span) do
    from = DateTime.add(time, -span, :second)

    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :graph end)
    |> concurrent_element_query(fn {id, element} ->
      metric_name = Map.get(element.meta, "metric_name", "default")

      points =
        case Manager.metric_range(id, metric_name, from, time) do
          {:ok, pts} when pts != [] -> downsample(pts, @max_graph_points)
          _ -> []
        end

      {id, points}
    end)
  end

  @doc """
  Text metric values for every text_series element:
  `%{id => {unix_ms, value}}`. Elements without data are omitted.
  """
  def query_text_data(resolved_elements, time) do
    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :text_series end)
    |> concurrent_element_query(fn {id, element} ->
      metric_name = Map.get(element.meta, "metric_name", "default")

      case Manager.text_metric_at(id, metric_name, time) do
        {:ok, value} -> {id, {DateTime.to_unix(time, :millisecond), value}}
        :no_data -> :skip
      end
    end)
  end

  @doc """
  Historical stream entries for every log/trace stream element:
  `%{id => [entry_map]}`.
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
  High-resolution point list for one expanded graph element.
  """
  def query_expanded_data(resolved_elements, element_id, time, span) do
    case Map.get(resolved_elements, element_id) do
      %{type: :graph} = element ->
        metric_name = Map.get(element.meta, "metric_name", "default")
        from = DateTime.add(time, -span, :second)

        case Manager.metric_range(element_id, metric_name, from, time) do
          {:ok, pts} when pts != [] -> downsample(pts, @max_graph_points_expanded)
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
    hosts = Manager.list_hosts(limit: 1)
    {hosts != [], List.first(hosts)}
  end

  @doc "Metric units per graph element id, from metric metadata."
  def query_metric_units(resolved_elements) do
    resolved_elements
    |> Enum.filter(fn {_id, el} -> el.type == :graph end)
    |> Enum.reduce(%{}, fn {id, el}, acc ->
      metric_name = Map.get(el.meta || %{}, "metric_name")

      if metric_name do
        case Manager.metric_metadata(metric_name) do
          {:ok, %{unit: unit}} when not is_nil(unit) -> Map.put(acc, id, unit)
          _ -> acc
        end
      else
        acc
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
  keyed by element id so ordering does not matter. Timed-out or crashed
  queries are skipped, leaving any previously assigned data in place.
  A `fun` returning `:skip` omits the element from the result.
  """
  def concurrent_element_query(elements, fun) do
    elements
    |> Task.async_stream(fun,
      max_concurrency: @element_query_concurrency,
      ordered: false,
      timeout: @element_query_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, :skip}, acc -> acc
      {:ok, {id, value}}, acc -> Map.put(acc, id, value)
      {:exit, _reason}, acc -> acc
    end)
  end

  @doc "Build stream-backend query opts from a log_stream element's meta."
  def build_log_opts(meta) do
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

  @doc "Build stream-backend query opts from a trace_stream element's meta."
  def build_trace_opts(meta) do
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

  # --- Private ---

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
end

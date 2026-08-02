defmodule TimelessCanvas.IconCatalog do
  @moduledoc """
  Curated icon mappings for canvas elements.
  """

  alias TimelessCanvas.Canvas.Element

  # The Timeless infinity mark (same path as the toolbar logo), embedded
  # as a data URI so it renders without depending on host-app assets.
  @timeless_logo_svg ~S(<svg xmlns="http://www.w3.org/2000/svg" width="28" height="16" viewBox="0 0 28 16" fill="none"><path d="M8 2C4.5 2 2 4.7 2 8s2.5 6 6 6c2.2 0 4-1.2 5.5-3L14 10.5l.5.5c1.5 1.8 3.3 3 5.5 3 3.5 0 6-2.7 6-6s-2.5-6-6-6c-2.2 0-4 1.2-5.5 3L14 5.5 13.5 5C12 3.2 10.2 2 8 2z" stroke="#6366f1" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>)
  @timeless_icon "data:image/svg+xml," <> URI.encode(@timeless_logo_svg, &URI.char_unreserved?/1)

  @service_icons %{
    "apache" => "logos:apache",
    "httpd" => "logos:apache",
    "nginx" => "logos:nginx",
    "cloudflare" => "logos:cloudflare",
    "envoy" => "logos:envoy",
    "kafka" => "logos:kafka-icon",
    "redis" => "logos:redis",
    "postgres" => "logos:postgresql",
    "postgresql" => "logos:postgresql",
    "mysql" => "logos:mysql",
    "mariadb" => "logos:mariadb",
    "rabbitmq" => "logos:rabbitmq-icon",
    "grafana" => "logos:grafana",
    "prometheus" => "logos:prometheus",
    "docker" => "logos:docker-icon",
    "kubernetes" => "logos:kubernetes",
    "k8s" => "logos:kubernetes",
    "elasticsearch" => "logos:elasticsearch",
    "elastic" => "logos:elasticsearch",
    "opentelemetry" => "logos:opentelemetry"
  }

  @semantic_icons %{
    "timeless" => @timeless_icon,
    "cpu" => "heroicons:cpu-chip-solid",
    "memory" => "heroicons:server-stack-solid",
    "disk" => "heroicons:circle-stack-solid",
    "database" => "heroicons:circle-stack-solid",
    "network" => "heroicons:signal-solid",
    "latency" => "heroicons:clock-solid",
    "throughput" => "heroicons:chart-bar-solid",
    "errors" => "heroicons:exclamation-triangle-solid",
    "alerts" => "heroicons:bell-alert-solid",
    "logs" => "heroicons:document-text-solid",
    "traces" => "heroicons:command-line-solid",
    "availability" => "heroicons:eye-solid",
    "cache" => "heroicons:bolt-solid",
    "queue" => "heroicons:archive-box-solid",
    "fire" => "heroicons:fire-solid",
    "cloud" => "heroicons:cloud-solid",
    "bugs" => "heroicons:bug-ant-solid"
  }

  @os_icons %{
    "debian" => "logos:debian",
    "ubuntu" => "logos:ubuntu",
    "macos" => "logos:apple",
    "mac os" => "logos:apple",
    "osx" => "logos:apple",
    "mac" => "logos:apple",
    "darwin" => "logos:apple",
    "rhel" => "logos:redhat-icon",
    "redhat" => "logos:redhat-icon",
    "red hat" => "logos:redhat-icon",
    "rocky" => "logos:rocky-linux",
    "rockylinux" => "logos:rocky-linux",
    "alma" => "simple-icons:almalinux",
    "almalinux" => "simple-icons:almalinux",
    "windows" => "logos:microsoft-windows-icon"
  }

  @icon_options [
    {"", "Auto"},
    {"timeless", "Timeless"},
    {"cpu", "CPU"},
    {"memory", "Memory"},
    {"disk", "Disk"},
    {"network", "Network"},
    {"latency", "Latency"},
    {"throughput", "Throughput"},
    {"errors", "Errors"},
    {"alerts", "Alerts"},
    {"logs", "Logs"},
    {"traces", "Traces"},
    {"availability", "Availability"},
    {"cache", "Cache"},
    {"queue", "Queue"},
    {"cloud", "Cloud"},
    {"apache", "Apache"},
    {"nginx", "Nginx"},
    {"cloudflare", "Cloudflare"},
    {"envoy", "Envoy"},
    {"kafka", "Kafka"},
    {"redis", "Redis"},
    {"postgres", "PostgreSQL"},
    {"mysql", "MySQL"},
    {"mariadb", "MariaDB"},
    {"rabbitmq", "RabbitMQ"},
    {"grafana", "Grafana"},
    {"prometheus", "Prometheus"},
    {"docker", "Docker"},
    {"kubernetes", "Kubernetes"},
    {"elasticsearch", "Elasticsearch"},
    {"opentelemetry", "OpenTelemetry"}
  ]

  @os_options [
    {"", "Auto"},
    {"debian", "Debian"},
    {"ubuntu", "Ubuntu"},
    {"macos", "macOS"},
    {"rhel", "RHEL"},
    {"rocky", "Rocky Linux"},
    {"alma", "AlmaLinux"},
    {"windows", "Windows"}
  ]

  def icon_options, do: @icon_options
  def os_options, do: @os_options

  def element_icon_name(%Element{} = element) do
    explicit_icon(element) || inferred_primary_icon(element)
  end

  def graph_icon_name(%Element{} = element) do
    explicit_icon(element) || inferred_graph_icon(element)
  end

  def badge_icon_name(%Element{} = element) do
    explicit_os_icon(element) || inferred_os_icon(element)
  end

  def graph_meta(%Element{} = source, host_ref, metric_name) do
    %{
      "host" => host_ref,
      "metric_name" => metric_name,
      "y_min" => "0"
    }
    |> maybe_put("icon", element_icon_name(source))
  end

  defp explicit_icon(%Element{meta: meta}) do
    meta
    |> Map.get("icon")
    |> normalize_icon(Map.merge(@semantic_icons, @service_icons), :primary)
  end

  defp explicit_os_icon(%Element{meta: meta}) do
    meta
    |> Map.get("os_icon")
    |> normalize_icon(@os_icons, :os)
  end

  defp inferred_primary_icon(%Element{type: :service, meta: meta}) do
    meta |> Map.get("service_name") |> normalize_icon(@service_icons, :service)
  end

  defp inferred_primary_icon(%Element{type: :database, meta: meta}) do
    meta |> Map.get("engine") |> normalize_icon(@service_icons, :service)
  end

  defp inferred_primary_icon(%Element{type: :cache, meta: meta}) do
    meta |> Map.get("engine") |> normalize_icon(@service_icons, :service)
  end

  defp inferred_primary_icon(%Element{type: :queue, meta: meta}) do
    meta |> Map.get("broker") |> normalize_icon(@service_icons, :service)
  end

  defp inferred_primary_icon(%Element{type: :graph} = element), do: inferred_graph_icon(element)

  defp inferred_primary_icon(%Element{type: :text_series} = element),
    do: inferred_graph_icon(element)

  defp inferred_primary_icon(_element), do: nil

  defp inferred_graph_icon(%Element{meta: meta}) do
    [Map.get(meta, "service_name"), Map.get(meta, "icon"), Map.get(meta, "metric_name")]
    |> Enum.find_value(&normalize_icon(&1, Map.merge(@semantic_icons, @service_icons), :primary))
  end

  defp inferred_os_icon(%Element{meta: meta}) do
    meta |> Map.get("os") |> normalize_icon(@os_icons, :os)
  end

  defp normalize_icon(nil, _map, _domain), do: nil
  defp normalize_icon("", _map, _domain), do: nil

  defp normalize_icon(value, map, domain) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, ":") ->
        value

      true ->
        cache_key = {__MODULE__, :normalized_icon, domain, value}

        case :persistent_term.get(cache_key, :missing) do
          :missing ->
            normalized = normalize_key(value)
            resolved = Map.get(map, normalized) || scan_aliases(normalized, map)
            :persistent_term.put(cache_key, resolved)
            resolved

          resolved ->
            resolved
        end
    end
  end

  defp normalize_key(value) do
    value
    |> String.downcase()
    |> String.to_charlist()
    |> Enum.reduce({[], false}, fn char, {acc, last_sep?} ->
      if separator_char?(char) do
        if last_sep? do
          {acc, true}
        else
          {[?\s | acc], true}
        end
      else
        {[char | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
    |> String.trim()
  end

  defp separator_char?(char) when char in [?_, ?-, ?., ?\s, ?\t, ?\n, ?\r], do: true
  defp separator_char?(_char), do: false

  # Match alias keys against whole (separator-normalized) words, never
  # bare substrings: "cpu_temp" → ["cpu", "temp"] still matches "cpu",
  # but "diskless" must not match "disk" nor "cachet" match "cache".
  # Multi-word keys ("mac os", "red hat") match as a contiguous word run.
  defp scan_aliases(text, map) do
    words = String.split(text, " ", trim: true)

    Enum.find_value(map, fn {key, icon} ->
      if contains_word_run?(words, String.split(key, " ", trim: true)), do: icon, else: nil
    end)
  end

  defp contains_word_run?(_words, []), do: false

  defp contains_word_run?(words, key_words) do
    words
    |> Enum.chunk_every(length(key_words), 1, :discard)
    |> Enum.any?(&(&1 == key_words))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule TimelessCanvas.IconCatalogTest do
  use ExUnit.Case, async: true

  alias TimelessCanvas.Canvas.Element
  alias TimelessCanvas.IconCatalog

  defp graph_el(meta) do
    Element.new(%{id: "el-1", type: :graph, meta: meta})
  end

  defp service_el(meta) do
    Element.new(%{id: "el-1", type: :service, meta: meta})
  end

  describe "alias scanning keeps useful token matches" do
    test "metric names infer icons from whole tokens" do
      assert IconCatalog.graph_icon_name(graph_el(%{"metric_name" => "cpu_temp"})) ==
               "heroicons:cpu-chip-solid"

      assert IconCatalog.graph_icon_name(graph_el(%{"metric_name" => "node_cpu_seconds_total"})) ==
               "heroicons:cpu-chip-solid"

      assert IconCatalog.graph_icon_name(graph_el(%{"metric_name" => "errors_total"})) ==
               "heroicons:exclamation-triangle-solid"
    end

    test "timeless_* metrics and graph service names get the brand icon" do
      assert IconCatalog.graph_icon_name(graph_el(%{"metric_name" => "timeless_ingest_rate"})) =~
               "data:image/svg+xml,"

      assert IconCatalog.graph_icon_name(graph_el(%{"service_name" => "timeless_ui"})) =~
               "data:image/svg+xml,"
    end

    test "exact service names still map directly" do
      assert IconCatalog.element_icon_name(service_el(%{"service_name" => "nginx"})) ==
               "logos:nginx"

      assert IconCatalog.element_icon_name(service_el(%{"service_name" => "Apache HTTPD"})) ==
               "logos:apache"
    end
  end

  describe "alias scanning rejects substring-in-word false positives" do
    test "'diskless' does not infer the disk icon" do
      assert IconCatalog.graph_icon_name(graph_el(%{"metric_name" => "diskless_boot_count"})) ==
               nil
    end

    test "'cachet' does not infer the cache icon" do
      assert IconCatalog.graph_icon_name(graph_el(%{"service_name" => "cachet"})) == nil
    end

    test "'cloudflare' still wins over the semantic 'cloud' icon" do
      assert IconCatalog.element_icon_name(service_el(%{"service_name" => "cloudflare"})) ==
               "logos:cloudflare"
    end
  end

  describe "explicit icon values" do
    test "iconify-style and data-URI values pass through untouched" do
      assert IconCatalog.element_icon_name(service_el(%{"icon" => "logos:redis"})) ==
               "logos:redis"

      data_uri = "data:image/svg+xml,%3Csvg%3E%3C/svg%3E"

      assert IconCatalog.element_icon_name(service_el(%{"icon" => data_uri})) == data_uri
    end
  end
end

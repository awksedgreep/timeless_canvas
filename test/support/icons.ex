defmodule TimelessCanvas.Test.Icons do
  @moduledoc """
  Pre-seeds placeholder SVG files for every icon `TimelessCanvas.IconCatalog`
  can resolve.

  `iconify_ex` generates icon SVGs on first render by reading `@iconify/json`
  npm assets, which are not installed in test/CI environments (generation
  raises). It skips generation entirely when the target file already exists,
  so we point its static path at a temp directory and create placeholders
  there before the test suite starts.
  """

  # Union of the icon identifiers in TimelessCanvas.IconCatalog
  # (@semantic_icons, @service_icons, @os_icons) plus iconify's fallback icon.
  @icons ~w(
    heroicons:cpu-chip-solid
    heroicons:server-stack-solid
    heroicons:circle-stack-solid
    heroicons:signal-solid
    heroicons:clock-solid
    heroicons:chart-bar-solid
    heroicons:exclamation-triangle-solid
    heroicons:bell-alert-solid
    heroicons:document-text-solid
    heroicons:command-line-solid
    heroicons:eye-solid
    heroicons:bolt-solid
    heroicons:archive-box-solid
    heroicons:fire-solid
    heroicons:cloud-solid
    heroicons:bug-ant-solid
    heroicons:question-mark-circle-solid
    logos:apache
    logos:nginx
    logos:cloudflare
    logos:envoy
    logos:kafka-icon
    logos:redis
    logos:postgresql
    logos:mysql
    logos:mariadb
    logos:rabbitmq-icon
    logos:grafana
    logos:prometheus
    logos:docker-icon
    logos:kubernetes
    logos:elasticsearch
    logos:opentelemetry
    logos:debian
    logos:ubuntu
    logos:apple
    logos:redhat-icon
    logos:rockylinux-icon
    logos:almalinux-icon
    logos:microsoft-windows-icon
  )

  @placeholder ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"></svg>\n)

  @doc """
  Redirect iconify's generated-icon path to a temp directory and create
  placeholder SVGs there. Call once from test_helper before any render.
  """
  def ensure_placeholders! do
    dir = Path.join(System.tmp_dir!(), "timeless_canvas_test_icons")
    Application.put_env(:iconify_ex, :generated_icon_static_path, dir)

    for icon <- @icons do
      [family, name] = String.split(icon, ":", parts: 2)
      family_dir = Path.join(dir, family)
      File.mkdir_p!(family_dir)
      File.write!(Path.join(family_dir, name <> ".svg"), @placeholder)
    end

    :ok
  end
end

defmodule TimelessCanvas.E2ECase do
  @moduledoc """
  Case template for the browser E2E suite (`mix test.e2e`).

  Each test seeds state through the existing fakes (`FakePersistence`,
  `FakeDataSource`, `FakeStreamBackend`) exactly like `ConnCase` tests do,
  then drives a real browser via a Node/playwright sidecar:
  `run_flow/2` executes one named flow from `test/e2e/flows.js` against
  the test endpoint (booted with a real HTTP server by `test_helper.exs`
  when `E2E=1`).

  All tests are tagged `:e2e` (excluded from plain `mix test`) and
  `async: false` (shared fakes + singletons + one browser at a time).
  """

  use ExUnit.CaseTemplate

  alias TimelessCanvas.Canvas
  alias TimelessCanvas.Canvas.Serializer

  @e2e_dir Path.expand("../../e2e", __DIR__)

  using do
    quote do
      import TimelessCanvas.E2ECase

      alias TimelessCanvas.Canvas
      alias TimelessCanvas.Test.{FakeDataSource, FakePersistence, FakeStreamBackend}

      @moduletag :e2e
    end
  end

  setup do
    TimelessCanvas.Test.FakePersistence.reset()
    TimelessCanvas.Test.FakeDataSource.reset()
    :ok
  end

  @doc "The user the E2E browser logs in as."
  def e2e_user, do: TimelessCanvas.Test.Auth.default_user()

  @doc "Base URL of the running test endpoint."
  def base_url do
    {:ok, {ip, port}} = TimelessCanvas.Test.Endpoint.server_info(:http)
    "http://#{:inet.ntoa(ip)}:#{port}"
  end

  @doc """
  Browser login URL: sets the session user then redirects to `to`
  (see `TimelessCanvas.Test.E2E.SessionController`).
  """
  def login_url(user, to) do
    token = user |> :erlang.term_to_binary() |> Base.url_encode64()
    "#{base_url()}/e2e/login?token=#{token}&to=#{URI.encode_www_form(to)}"
  end

  @doc "Serialize a `Canvas` the way a DB round trip would."
  def encode(%Canvas{} = canvas) do
    canvas |> Serializer.encode() |> Jason.encode!() |> Jason.decode!()
  end

  @doc """
  Run one named flow from `test/e2e/flows.js` in the browser and assert it
  passes. `opts`:

    * `:path`  — where the browser lands after login (default `"/canvas/1"`)
    * `:user`  — session user (default `e2e_user/0`)
    * `:params` — map passed to the flow as JSON (FLOW_PARAMS)
  """
  def run_flow(flow, opts \\ []) do
    ensure_node_modules!()

    user = Keyword.get(opts, :user, e2e_user())
    path = Keyword.get(opts, :path, "/canvas/1")
    params = Keyword.get(opts, :params, %{})

    env = [
      {"BASE_URL", base_url()},
      {"LOGIN_URL", login_url(user, path)},
      {"E2E_BROWSER", System.get_env("E2E_BROWSER", "chromium")},
      {"FLOW_PARAMS", Jason.encode!(params)},
      {"ARTIFACT_DIR", Path.join(@e2e_dir, "artifacts")}
    ]

    {output, status} =
      System.cmd("node", ["run_flow.js", flow],
        cd: @e2e_dir,
        env: env,
        stderr_to_stdout: true
      )

    if status != 0 do
      ExUnit.Assertions.flunk("""
      E2E flow #{inspect(flow)} failed (exit #{status}):

      #{output}
      """)
    end

    output
  end

  # `npm install` once per run (no-op when node_modules is current).
  defp ensure_node_modules! do
    if :persistent_term.get({__MODULE__, :npm_ready}, false) do
      :ok
    else
      unless File.dir?(Path.join(@e2e_dir, "node_modules")) do
        {output, status} =
          System.cmd("npm", ["install", "--no-audit", "--no-fund"],
            cd: @e2e_dir,
            stderr_to_stdout: true
          )

        if status != 0 do
          raise "npm install failed in test/e2e:\n#{output}"
        end
      end

      :persistent_term.put({__MODULE__, :npm_ready}, true)
      :ok
    end
  end
end

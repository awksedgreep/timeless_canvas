defmodule TimelessCanvas.Profiling do
  @moduledoc """
  Gate for the `[canvas-prof]` instrumentation (render timing wrappers,
  per-process render counters, and the periodic debug-report timers in
  `CanvasLive` and `DataSource.Manager`).

  Off by default. Enable with:

      config :timeless_canvas, :profiling, true

  The flag is read once from the application environment and cached in
  `:persistent_term`, so `enabled?/0` is cheap enough to call from render
  hot paths. Call `refresh/0` after changing the app env at runtime
  (tests do this).
  """

  @key {__MODULE__, :enabled?}

  @doc "Whether profiling instrumentation is enabled (default `false`)."
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@key, :unset) do
      :unset -> refresh()
      value -> value
    end
  end

  @doc """
  Re-read `config :timeless_canvas, :profiling` into the cache.

  Returns the new value.
  """
  @spec refresh() :: boolean()
  def refresh do
    value = Application.get_env(:timeless_canvas, :profiling, false) == true
    :persistent_term.put(@key, value)
    value
  end

  @doc """
  Run `fun` under `:timer.tc` when profiling is enabled; when disabled,
  call it directly and report 0 elapsed microseconds.
  """
  @spec timed((-> result)) :: {non_neg_integer(), result} when result: var
  def timed(fun) do
    if enabled?() do
      :timer.tc(fun)
    else
      {0, fun.()}
    end
  end
end

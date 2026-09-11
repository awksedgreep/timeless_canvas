defmodule TimelessCanvas.AlertSourceTest do
  @moduledoc """
  The seam between the canvas and whatever stores alert rules.

  The canvas must never derive the metric labels itself: which labels a graph
  queries is the backend's decision (it drops presentation keys and applies
  the series filter), so a rule built from canvas-side guesses could watch a
  different series than the graph draws — and look correct while doing it.
  """
  use ExUnit.Case, async: false

  alias TimelessCanvas.AlertSource

  setup do
    original = Application.get_env(:timeless_canvas, :alert_backend)

    on_exit(fn ->
      if original,
        do: Application.put_env(:timeless_canvas, :alert_backend, original),
        else: Application.delete_env(:timeless_canvas, :alert_backend)
    end)

    :ok
  end

  test "no configured backend means alerting is not offered" do
    # A form that accepted rules nothing would store is worse than no form.
    Application.delete_env(:timeless_canvas, :alert_backend)

    refute AlertSource.configured?()
    assert AlertSource.backend() == nil
  end

  test "a configured backend is reported" do
    Application.put_env(:timeless_canvas, :alert_backend, SomeBackend)

    assert AlertSource.configured?()
    assert AlertSource.backend() == SomeBackend
  end

  test "the behaviour takes elements, not metric/label pairs" do
    # Guards the design decision above: if these arities ever change to accept
    # a selector, the canvas has started deciding labels and can diverge from
    # what the graph queries.
    callbacks = AlertSource.behaviour_info(:callbacks)

    assert {:list_rules, 1} in callbacks
    assert {:create_rule, 2} in callbacks
    assert {:update_rule, 2} in callbacks
    assert {:delete_rule, 1} in callbacks
  end

  test "delivery_formats is optional" do
    assert {:delivery_formats, 0} in AlertSource.behaviour_info(:optional_callbacks)
    assert {:statuses, 1} in AlertSource.behaviour_info(:optional_callbacks)
    assert {:list_all_rules, 1} in AlertSource.behaviour_info(:optional_callbacks)
    assert {:list_history, 2} in AlertSource.behaviour_info(:optional_callbacks)
    assert {:acknowledge_alert, 2} in AlertSource.behaviour_info(:optional_callbacks)
  end
end

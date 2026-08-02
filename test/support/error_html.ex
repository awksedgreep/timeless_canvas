defmodule TimelessCanvas.Test.ErrorHTML do
  @moduledoc """
  Minimal error renderer for the test endpoint so browser requests for
  missing paths (favicon.ico and friends) 404 quietly instead of raising
  about an undefined ErrorView.
  """

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

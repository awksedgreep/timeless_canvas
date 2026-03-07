defmodule TimelessCanvas.Web do
  @moduledoc """
  Provides `use TimelessCanvas.Web, :live_view` and `:live_component`
  for the package's LiveView modules.
  """

  def live_view do
    quote do
      use Phoenix.LiveView

      import TimelessCanvas.Components.CanvasComponents
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

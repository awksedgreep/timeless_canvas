defmodule TimelessCanvas.Auth do
  @moduledoc """
  Behaviour for canvas authorization.
  Implementations check whether a user can perform actions on a canvas.
  """

  @callback admin?(user :: map()) :: boolean()

  @callback authorize(user :: map(), canvas_record :: map(), action :: atom()) ::
              :ok | {:error, :unauthorized}
end

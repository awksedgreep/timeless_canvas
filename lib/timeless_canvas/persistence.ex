defmodule TimelessCanvas.Persistence do
  @moduledoc """
  Behaviour for canvas CRUD operations.
  Implementations handle database storage for canvas records and access control.
  """

  @type canvas_id :: integer()
  @type user_id :: integer()

  @callback get_canvas(canvas_id()) ::
              {:ok, map()} | {:error, :not_found}

  @callback save_canvas(user_id(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}

  @callback create_canvas(user_id(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback create_child_canvas(canvas_id(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback update_canvas_data(canvas_id(), map()) ::
              {:ok, map()} | {:error, term()}

  @callback rename_canvas(canvas_id(), user_id(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback delete_canvas(canvas_id(), user_id()) ::
              {:ok, map()} | {:error, term()}

  @callback list_accessible_canvases(user :: map()) :: [map()]

  @callback breadcrumb_chain(canvas_id()) :: [{integer(), String.t()}]

  @callback grant_access(canvas_id(), user_id(), atom()) ::
              {:ok, map()} | {:error, term()}

  @callback revoke_access(canvas_id(), user_id()) ::
              {:ok, map()} | {:error, term()}

  @callback list_access(canvas_id()) :: [map()]

  @callback lookup_user_by_username(username :: String.t()) :: struct() | nil
end

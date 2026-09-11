defmodule TimelessCanvas.Schemas.CanvasAccess do
  use Ecto.Schema
  import Ecto.Changeset

  schema "canvas_accesses" do
    field(:role, Ecto.Enum, values: [:owner, :editor, :viewer])
    belongs_to(:canvas, TimelessCanvas.Schemas.CanvasRecord)
    field(:user_id, :integer)
    field(:user, :map, virtual: true)

    timestamps()
  end

  def changeset(access, attrs) do
    access
    |> cast(attrs, [:canvas_id, :user_id, :role])
    |> validate_required([:canvas_id, :user_id, :role])
    |> foreign_key_constraint(:canvas_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id, name: :canvas_accesses_canvas_id_user_id_index)
  end
end

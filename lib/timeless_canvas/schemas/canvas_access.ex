defmodule TimelessCanvas.Schemas.CanvasAccess do
  use Ecto.Schema
  import Ecto.Changeset

  @user_schema Application.compile_env(:timeless_canvas, :user_schema)

  schema "canvas_accesses" do
    field :role, Ecto.Enum, values: [:owner, :editor, :viewer]
    belongs_to :canvas, TimelessCanvas.Schemas.CanvasRecord

    if @user_schema do
      belongs_to :user, @user_schema
    else
      field :user_id, :integer
    end

    timestamps()
  end

  def changeset(access, attrs) do
    access
    |> cast(attrs, [:canvas_id, :user_id, :role])
    |> validate_required([:canvas_id, :user_id, :role])
    |> foreign_key_constraint(:canvas_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:canvas_id, :user_id])
  end
end

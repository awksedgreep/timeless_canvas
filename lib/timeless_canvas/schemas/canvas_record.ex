defmodule TimelessCanvas.Schemas.CanvasRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @user_schema Application.compile_env(:timeless_canvas, :user_schema)

  schema "canvases" do
    field :name, :string
    field :data, :map

    if @user_schema do
      belongs_to :user, @user_schema
    else
      field :user_id, :integer
    end

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :data, :user_id, :parent_id])
    |> validate_required([:name, :data, :user_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint([:user_id, :name])
  end
end

defmodule TimelessCanvas.Schemas.CanvasRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "canvases" do
    field(:name, :string)
    field(:data, :map)
    field(:user_id, :integer)

    belongs_to(:parent, __MODULE__)
    has_many(:children, __MODULE__, foreign_key: :parent_id)

    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :data, :user_id, :parent_id])
    |> validate_required([:name, :data, :user_id])
    |> validate_length(:name, max: 255)
    |> validate_change(:data, &validate_data_size/2)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:name, name: :canvases_user_id_name_index)
  end

  defp validate_data_size(:data, data) do
    case Jason.encode(data) do
      {:ok, encoded} when byte_size(encoded) <= 1_048_576 -> []
      {:ok, _encoded} -> [data: {"is too large", [code: :data_too_large]}]
      {:error, _reason} -> [data: {"is invalid", [code: :invalid_data]}]
    end
  end
end

defmodule TimelessCanvas.Test.Repo do
  use Ecto.Repo,
    otp_app: :timeless_canvas,
    adapter: Ecto.Adapters.SQLite3
end

defmodule TimelessCanvas.Test.User do
  use Ecto.Schema

  schema "users" do
    field(:username, :string)
  end
end

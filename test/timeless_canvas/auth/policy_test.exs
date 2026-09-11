defmodule TimelessCanvas.Auth.PolicyTest do
  use ExUnit.Case, async: false

  alias TimelessCanvas.Auth.Policy
  alias TimelessCanvas.Persistence.Ecto, as: EctoPersistence
  alias TimelessCanvas.Test.{Repo, User}

  setup do
    previous_repo = Application.get_env(:timeless_canvas, :repo)
    previous_user_schema = Application.get_env(:timeless_canvas, :user_schema)
    Application.put_env(:timeless_canvas, :repo, Repo)
    Application.put_env(:timeless_canvas, :user_schema, User)

    Repo.delete_all(TimelessCanvas.Schemas.CanvasAccess)
    Repo.delete_all(TimelessCanvas.Schemas.CanvasRecord)
    Repo.delete_all(User)

    owner = Repo.insert!(%User{username: "owner"})
    member = Repo.insert!(%User{username: "member"})
    {:ok, canvas} = EctoPersistence.create_canvas(owner.id, "Policy")

    on_exit(fn ->
      restore_env(:repo, previous_repo)
      restore_env(:user_schema, previous_user_schema)
    end)

    %{owner: owner, member: member, canvas: canvas}
  end

  test "nil and malformed users or records are denied", %{canvas: canvas} do
    assert Policy.authorize(nil, canvas, :view) == {:error, :unauthorized}
    assert Policy.authorize(%{}, canvas, :view) == {:error, :unauthorized}
    assert Policy.authorize(%{id: 1}, %{}, :view) == {:error, :unauthorized}
  end

  test "string and atom admins plus owners have full access", %{owner: owner, canvas: canvas} do
    for user <- [%{id: -1, role: "admin"}, %{id: -1, role: :admin}, owner],
        action <- [:view, :edit, :share, :delete] do
      assert Policy.authorize(user, canvas, action) == :ok
    end
  end

  test "editor and viewer permissions are bounded", %{member: member, canvas: canvas} do
    {:ok, _} = EctoPersistence.grant_access(canvas.id, member.id, :editor)
    assert Policy.authorize(member, canvas, :view) == :ok
    assert Policy.authorize(member, canvas, :edit) == :ok
    assert Policy.authorize(member, canvas, :share) == {:error, :unauthorized}
    assert Policy.authorize(member, canvas, :delete) == {:error, :unauthorized}

    {:ok, _} = EctoPersistence.grant_access(canvas.id, member.id, :viewer)
    assert Policy.authorize(member, canvas, :view) == :ok
    assert Policy.authorize(member, canvas, :edit) == {:error, :unauthorized}
  end

  test "unknown stored roles are denied rather than crashing", %{member: member, canvas: canvas} do
    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO canvas_accesses (role, canvas_id, user_id, inserted_at, updated_at) VALUES ('future', ?, ?, datetime('now'), datetime('now'))",
      [canvas.id, member.id]
    )

    assert Policy.authorize(member, canvas, :view) == {:error, :unauthorized}
  end

  defp restore_env(key, nil), do: Application.delete_env(:timeless_canvas, key)
  defp restore_env(key, value), do: Application.put_env(:timeless_canvas, key, value)
end

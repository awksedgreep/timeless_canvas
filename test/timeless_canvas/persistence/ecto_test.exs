defmodule TimelessCanvas.Persistence.EctoTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias TimelessCanvas.Persistence.Ecto, as: Persistence
  alias TimelessCanvas.Schemas.{CanvasAccess, CanvasRecord}
  alias TimelessCanvas.Test.{Repo, User}

  setup do
    previous_repo = Application.get_env(:timeless_canvas, :repo)
    previous_user_schema = Application.get_env(:timeless_canvas, :user_schema)
    Application.put_env(:timeless_canvas, :repo, Repo)
    Application.put_env(:timeless_canvas, :user_schema, User)

    Repo.delete_all(CanvasAccess)
    Repo.delete_all(CanvasRecord)
    Repo.delete_all(User)
    user = Repo.insert!(%User{username: "owner"})

    on_exit(fn ->
      restore_env(:repo, previous_repo)
      restore_env(:user_schema, previous_user_schema)
    end)

    %{user: user}
  end

  test "unique constraints return changeset errors", %{user: user} do
    assert {:ok, _} = Persistence.create_canvas(user.id, "same")
    assert {:error, changeset} = Persistence.create_canvas(user.id, "same")
    assert "has already been taken" in errors_on(changeset).name
  end

  test "save_canvas atomically inserts or replaces current data", %{user: user} do
    assert {:ok, first} = Persistence.save_canvas(user.id, "upsert", %{"n" => 1})
    assert {:ok, second} = Persistence.save_canvas(user.id, "upsert", %{"n" => 2})
    assert first.id == second.id
    assert second.data == %{"n" => 2}
    assert Repo.aggregate(CanvasRecord, :count) == 1
  end

  test "schema bounds names and encoded canvas data", %{user: user} do
    assert {:error, changeset} = Persistence.create_canvas(user.id, String.duplicate("n", 256))
    assert "should be at most 255 character(s)" in errors_on(changeset).name

    huge = %{"blob" => String.duplicate("x", 1_048_576)}

    changeset =
      CanvasRecord.changeset(%CanvasRecord{}, %{user_id: user.id, name: "huge", data: huge})

    assert changeset.errors[:data] == {"is too large", [code: :data_too_large]}
  end

  test "list_access attaches users without a nonexistent association", %{user: owner} do
    member = Repo.insert!(%User{username: "member"})
    {:ok, canvas} = Persistence.create_canvas(owner.id, "shared")
    {:ok, _} = Persistence.grant_access(canvas.id, member.id, :viewer)

    assert [%{user: %User{username: "member"}, role: :viewer}] =
             Persistence.list_access(canvas.id)
  end

  test "accessible canvases are returned in bounded pages without loading data blobs", %{
    user: user
  } do
    for name <- ["c", "a", "b"] do
      assert {:ok, _} = Persistence.save_canvas(user.id, name, %{"large" => "not selected"})
    end

    assert [%{name: "b", data: nil}, %{name: "c", data: nil}] =
             Persistence.list_accessible_canvases(user, limit: 2, offset: 1)
  end

  test "breadcrumb cycles terminate and delete explicitly cleans dependents", %{user: user} do
    {:ok, parent} = Persistence.create_canvas(user.id, "parent")
    {:ok, child} = Persistence.create_child_canvas(parent.id, "child")

    Repo.update_all(from(c in CanvasRecord, where: c.id == ^parent.id),
      set: [parent_id: child.id]
    )

    assert length(Persistence.breadcrumb_chain(child.id)) == 2

    {:ok, _} = Persistence.grant_access(parent.id, user.id, :viewer)
    assert {:ok, _} = Persistence.delete_canvas(parent.id, user.id)
    assert Repo.get_by(CanvasAccess, canvas_id: parent.id) == nil
    assert Repo.get!(CanvasRecord, child.id).parent_id == nil
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:timeless_canvas, key)
  defp restore_env(key, value), do: Application.put_env(:timeless_canvas, key, value)
end

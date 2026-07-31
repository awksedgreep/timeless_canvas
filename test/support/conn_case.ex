defmodule TimelessCanvas.ConnCase do
  @moduledoc """
  Case template for tests that exercise the LiveViews through the test
  endpoint.

  Resets `FakePersistence` and `FakeDataSource` before each test and provides
  a conn plus `test_user/1` and `log_in_user/2` helpers.

  Tests using this case should be `async: false`: they share the
  FakePersistence Agent, the FakeDataSource ETS table, and the
  DataSource.Manager / StreamManager singletons.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import TimelessCanvas.ConnCase

      alias TimelessCanvas.Test.{FakeDataSource, FakePersistence}

      @endpoint TimelessCanvas.Test.Endpoint
    end
  end

  setup do
    TimelessCanvas.Test.FakePersistence.reset()
    TimelessCanvas.Test.FakeDataSource.reset()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Build a user map with an `:id` (plus `:username`/`:email` for share flows).
  """
  def test_user(attrs \\ %{}) do
    Map.merge(TimelessCanvas.Test.Auth.default_user(), Map.new(attrs))
  end

  @doc """
  Store the user in the test session so `TimelessCanvas.Test.Auth` assigns it
  as `:current_user` on mount.
  """
  def log_in_user(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user" => user})
  end
end

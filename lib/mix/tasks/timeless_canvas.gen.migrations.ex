defmodule Mix.Tasks.TimelessCanvas.Gen.Migrations do
  @moduledoc """
  Generates Ecto migrations for TimelessCanvas tables.

      mix timeless_canvas.gen.migrations

  Creates two migration files:
  - `create_canvases` - The canvases table
  - `create_canvas_accesses` - The canvas access control table
  """

  use Mix.Task

  import Mix.Generator

  @shortdoc "Generates TimelessCanvas Ecto migrations"

  @impl true
  def run(_args) do
    app_dir = Mix.Project.app_path()
    migrations_dir = Path.join([app_dir, "..", "..", "priv", "repo", "migrations"])
    migrations_dir = Path.expand(migrations_dir)

    File.mkdir_p!(migrations_dir)

    ts1 = timestamp()
    ts2 = timestamp(1)

    create_file(
      Path.join(migrations_dir, "#{ts1}_create_canvases.exs"),
      canvases_migration_template(ts1)
    )

    create_file(
      Path.join(migrations_dir, "#{ts2}_create_canvas_accesses.exs"),
      canvas_accesses_migration_template(ts2)
    )

    Mix.shell().info("""

    Migrations created. Run:

        mix ecto.migrate
    """)
  end

  defp timestamp(offset \\ 0) do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    ss = ss + offset
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i), do: String.pad_leading("#{i}", 2, "0")

  defp canvases_migration_template(_ts) do
    """
    defmodule Repo.Migrations.CreateCanvases do
      use Ecto.Migration

      def change do
        create table(:canvases) do
          add :name, :string, null: false
          add :data, :map, null: false, default: %{}
          add :user_id, references(:users, on_delete: :delete_all), null: false
          add :parent_id, references(:canvases, on_delete: :nilify_all)

          timestamps()
        end

        create unique_index(:canvases, [:user_id, :name])
        create index(:canvases, [:parent_id])
      end
    end
    """
  end

  defp canvas_accesses_migration_template(_ts) do
    """
    defmodule Repo.Migrations.CreateCanvasAccesses do
      use Ecto.Migration

      def change do
        create table(:canvas_accesses) do
          add :role, :string, null: false
          add :canvas_id, references(:canvases, on_delete: :delete_all), null: false
          add :user_id, references(:users, on_delete: :delete_all), null: false

          timestamps()
        end

        create unique_index(:canvas_accesses, [:canvas_id, :user_id])
        create index(:canvas_accesses, [:user_id])
      end
    end
    """
  end
end

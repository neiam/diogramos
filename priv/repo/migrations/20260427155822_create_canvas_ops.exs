defmodule Diogramos.Repo.Migrations.CreateCanvasOps do
  use Ecto.Migration

  def change do
    create table(:canvas_ops) do
      add :canvas_id, references(:canvases, on_delete: :delete_all), null: false
      add :version, :bigint, null: false
      add :op, :map, null: false
      add :actor_id, references(:users, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime,
        null: false,
        default: fragment("(now() at time zone 'utc')")
    end

    create unique_index(:canvas_ops, [:canvas_id, :version])
    create index(:canvas_ops, [:actor_id])
  end
end

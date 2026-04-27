defmodule Diogramos.Repo.Migrations.CreateCanvases do
  use Ecto.Migration

  def change do
    create table(:canvases) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :folder_id, references(:folders, on_delete: :nilify_all)
      add :slug, :citext, null: false
      add :title, :string, null: false
      add :theme, :string, null: false, default: "afterdark"
      add :document, :map, null: false, default: %{}
      add :version, :bigint, null: false, default: 0
      add :embed_token, :string
      add :embed_show_cursors, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:canvases, [:owner_id])
    create index(:canvases, [:folder_id])
    create unique_index(:canvases, [:slug])

    create unique_index(:canvases, [:embed_token],
             where: "embed_token IS NOT NULL",
             name: :canvases_embed_token_index
           )
  end
end

defmodule Diogramos.Repo.Migrations.CreateFolders do
  use Ecto.Migration

  def change do
    create table(:folders) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :parent_id, references(:folders, on_delete: :delete_all)
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:folders, [:owner_id])
    create index(:folders, [:parent_id])
    create index(:folders, [:owner_id, :parent_id])
  end
end

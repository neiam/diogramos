defmodule Diogramos.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  def change do
    create table(:invites) do
      add :token, :string, null: false
      add :note, :string
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :consumed_by_id, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invites, [:token])
    create index(:invites, [:created_by_id])
  end
end

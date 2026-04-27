defmodule Diogramos.Repo.Migrations.CreateShareLinks do
  use Ecto.Migration

  def change do
    create table(:share_links) do
      add :token, :string, null: false
      add :subject_type, :string, null: false
      add :subject_id, :bigint, null: false
      add :role, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:share_links, [:token])
    create index(:share_links, [:subject_type, :subject_id])

    create constraint(:share_links, :share_links_subject_type_check,
             check: "subject_type in ('folder','canvas')"
           )

    create constraint(:share_links, :share_links_role_check, check: "role in ('viewer','editor')")
  end
end

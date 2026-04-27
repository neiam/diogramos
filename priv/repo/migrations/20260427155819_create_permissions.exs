defmodule Diogramos.Repo.Migrations.CreatePermissions do
  use Ecto.Migration

  def change do
    create table(:permissions) do
      add :subject_type, :string, null: false
      add :subject_id, :bigint, null: false
      add :principal_type, :string, null: false
      add :principal_id, :bigint, null: false
      add :role, :string, null: false
      add :granted_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:permissions, :permissions_subject_type_check,
             check: "subject_type in ('folder','canvas')"
           )

    create constraint(:permissions, :permissions_principal_type_check,
             check: "principal_type in ('user','share_link')"
           )

    create constraint(:permissions, :permissions_role_check,
             check: "role in ('viewer','editor','owner')"
           )

    create unique_index(
             :permissions,
             [:subject_type, :subject_id, :principal_type, :principal_id],
             name: :permissions_subject_principal_index
           )

    create index(:permissions, [:principal_type, :principal_id])
  end
end

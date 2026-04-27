defmodule Diogramos.Repo.Migrations.AddKindAndDisplayNameToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :kind, :string, null: false, default: "registered"
      add :display_name, :string
      modify :email, :citext, null: true, from: {:citext, null: false}
    end

    create constraint(:users, :users_kind_check, check: "kind in ('registered','anonymous')")

    drop unique_index(:users, [:email])
    create unique_index(:users, [:email], where: "email IS NOT NULL", name: :users_email_index)
  end
end

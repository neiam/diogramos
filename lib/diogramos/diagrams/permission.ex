defmodule Diogramos.Diagrams.Permission do
  @moduledoc """
  Polymorphic grant table linking a principal (user or share_link) to a
  subject (folder or canvas) with a role. Effective permission for a
  user-on-canvas is the max role across direct grants, ancestor folder
  grants, and ownership.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @subject_types ~w(folder canvas)
  @principal_types ~w(user share_link)
  @roles ~w(viewer editor owner)

  schema "permissions" do
    field :subject_type, :string
    field :subject_id, :integer
    field :principal_type, :string
    field :principal_id, :integer
    field :role, :string
    field :granted_by_id, :integer

    timestamps(type: :utc_datetime)
  end

  def subject_types, do: @subject_types
  def principal_types, do: @principal_types
  def roles, do: @roles

  @doc false
  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [
      :subject_type,
      :subject_id,
      :principal_type,
      :principal_id,
      :role,
      :granted_by_id
    ])
    |> validate_required([:subject_type, :subject_id, :principal_type, :principal_id, :role])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(
      [:subject_type, :subject_id, :principal_type, :principal_id],
      name: :permissions_subject_principal_index
    )
  end
end

defmodule Diogramos.Diagrams.ShareLink do
  @moduledoc """
  A revocable, optionally-expiring URL token granting viewer or editor
  access to a folder or canvas. Visiting `/s/:token` either binds to the
  current session or creates an anonymous user.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Diogramos.Accounts.User

  @subject_types ~w(folder canvas)
  @roles ~w(viewer editor)

  schema "share_links" do
    field :token, :string
    field :subject_type, :string
    field :subject_id, :integer
    field :role, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  def subject_types, do: @subject_types
  def roles, do: @roles

  @doc false
  def create_changeset(share_link, attrs) do
    share_link
    |> cast(attrs, [:subject_type, :subject_id, :role, :created_by_id, :expires_at])
    |> put_token_if_missing()
    |> validate_required([:token, :subject_type, :subject_id, :role])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:token)
  end

  defp put_token_if_missing(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, generate_token())
      _ -> changeset
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  @doc """
  Returns true if the share link is currently usable.
  """
  def active?(%__MODULE__{revoked_at: nil, expires_at: nil}), do: true

  def active?(%__MODULE__{revoked_at: nil, expires_at: %DateTime{} = exp}) do
    DateTime.compare(exp, DateTime.utc_now()) == :gt
  end

  def active?(_), do: false
end

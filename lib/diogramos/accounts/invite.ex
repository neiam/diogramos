defmodule Diogramos.Accounts.Invite do
  @moduledoc """
  A single-use registration invite. When `Diogramos.registration_open?/0`
  returns false, `/users/register` only accepts visitors carrying a
  valid invite token in the URL.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Diogramos.Accounts.User

  schema "invites" do
    field :token, :string
    field :note, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :created_by, User
    belongs_to :consumed_by, User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:note, :created_by_id, :expires_at])
    |> put_token_if_missing()
    |> validate_required([:token])
    |> validate_length(:note, max: 200)
    |> unique_constraint(:token)
  end

  @doc """
  Stamps the invite as consumed by the given user. Idempotent: a second
  call returns the same record without re-stamping.
  """
  def consume_changeset(invite, %User{id: user_id}) do
    if invite.consumed_at do
      change(invite)
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      change(invite, consumed_at: now, consumed_by_id: user_id)
    end
  end

  @spec active?(%__MODULE__{}) :: boolean()
  def active?(%__MODULE__{consumed_at: nil, expires_at: nil}), do: true

  def active?(%__MODULE__{consumed_at: nil, expires_at: %DateTime{} = exp}) do
    DateTime.compare(exp, DateTime.utc_now()) == :gt
  end

  def active?(_), do: false

  defp put_token_if_missing(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, generate_token())
      _ -> changeset
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end

defmodule Diogramos.Diagrams.ShareLinks do
  @moduledoc """
  Creation, lookup, and redemption of share links.

  Redemption is the multi-step path that turns an arbitrary visitor into
  someone with permission on a folder or canvas. If the visitor is
  signed in, we attach a grant to their existing user. Otherwise we
  mint an anonymous user and attach the grant to that.
  """
  import Ecto.Query

  alias Diogramos.Repo
  alias Diogramos.Accounts
  alias Diogramos.Accounts.{Scope, User}
  alias Diogramos.Diagrams.{Canvas, Folder, Permissions, ShareLink}

  @spec create(Scope.t(), %Canvas{} | %Folder{}, String.t(), keyword()) ::
          {:ok, ShareLink.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create(%Scope{user: %User{id: user_id}} = scope, subject, role, opts \\ [])
      when role in ["viewer", "editor"] do
    with :ok <- Permissions.authorize(scope, :admin, subject) do
      attrs = %{
        subject_type: subject_type(subject),
        subject_id: subject.id,
        role: role,
        created_by_id: user_id,
        expires_at: opts[:expires_at]
      }

      %ShareLink{}
      |> ShareLink.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @spec get_active_by_token(String.t()) :: ShareLink.t() | nil
  def get_active_by_token(token) when is_binary(token) do
    case Repo.get_by(ShareLink, token: token) do
      nil -> nil
      link -> if ShareLink.active?(link), do: link, else: nil
    end
  end

  @spec list_for(%Canvas{} | %Folder{}) :: [ShareLink.t()]
  def list_for(subject) do
    type = subject_type(subject)

    from(s in ShareLink,
      where: s.subject_type == ^type and s.subject_id == ^subject.id,
      where: is_nil(s.revoked_at),
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  @spec revoke(Scope.t(), ShareLink.t()) ::
          {:ok, ShareLink.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def revoke(%Scope{} = scope, %ShareLink{} = link) do
    with :ok <- authorize_admin_for_subject(scope, link) do
      link
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()
    end
  end

  @doc """
  Redeems a share link.

  Outcomes:
    * Caller is already signed in → attaches a grant to their user.
    * Caller is anonymous → creates an anonymous user and attaches a
      grant to that user.

  Returns `{:ok, user, subject}` so the controller can log the user in
  and redirect to the subject. Idempotent: re-redeeming with the same
  current user just refreshes the existing grant.
  """
  @spec redeem(String.t(), User.t() | nil) ::
          {:ok, User.t(), %Canvas{} | %Folder{}}
          | {:error, :invalid_link | :subject_missing | Ecto.Changeset.t()}
  def redeem(token, current_user) when is_binary(token) do
    with %ShareLink{} = link <- get_active_by_token(token),
         {:ok, subject} <- load_subject(link),
         {:ok, %User{} = user} <- ensure_user(current_user),
         {:ok, _} <-
           Permissions.grant(
             link.subject_type,
             link.subject_id,
             "user",
             user.id,
             link.role,
             granted_by_id: link.created_by_id
           ) do
      {:ok, user, subject}
    else
      nil -> {:error, :invalid_link}
      {:error, _} = err -> err
    end
  end

  ## Helpers

  defp subject_type(%Canvas{}), do: "canvas"
  defp subject_type(%Folder{}), do: "folder"

  defp load_subject(%ShareLink{subject_type: "canvas", subject_id: id}) do
    case Repo.get(Canvas, id) do
      nil -> {:error, :subject_missing}
      canvas -> {:ok, canvas}
    end
  end

  defp load_subject(%ShareLink{subject_type: "folder", subject_id: id}) do
    case Repo.get(Folder, id) do
      nil -> {:error, :subject_missing}
      folder -> {:ok, folder}
    end
  end

  defp ensure_user(%User{} = user), do: {:ok, user}

  defp ensure_user(nil) do
    Accounts.register_anonymous_user(%{display_name: "Guest"})
  end

  defp authorize_admin_for_subject(scope, %ShareLink{subject_type: "canvas", subject_id: id}) do
    case Repo.get(Canvas, id) do
      nil -> {:error, :forbidden}
      c -> Permissions.authorize(scope, :admin, c)
    end
  end

  defp authorize_admin_for_subject(scope, %ShareLink{subject_type: "folder", subject_id: id}) do
    case Repo.get(Folder, id) do
      nil -> {:error, :forbidden}
      f -> Permissions.authorize(scope, :admin, f)
    end
  end
end

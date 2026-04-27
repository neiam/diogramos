defmodule Diogramos.Diagrams.Folders do
  @moduledoc """
  Folder CRUD scoped to the calling user. List queries return both
  owned folders and folders the user has any direct grant on.
  """
  import Ecto.Query

  alias Diogramos.Repo
  alias Diogramos.Accounts.{Scope, User}
  alias Diogramos.Diagrams.{Folder, Permission, Permissions}

  @doc """
  Returns folders the user can see — owned folders plus folders with a
  direct permission grant. Tree shape isn't materialized here; callers
  build the tree from `parent_id`.
  """
  @spec list(Scope.t()) :: [Folder.t()]
  def list(%Scope{user: %User{id: user_id}}) do
    granted_ids =
      from(p in Permission,
        where: p.subject_type == "folder",
        where: p.principal_type == "user" and p.principal_id == ^user_id,
        select: p.subject_id
      )

    from(f in Folder,
      where: f.owner_id == ^user_id or f.id in subquery(granted_ids),
      order_by: [asc: f.parent_id, asc: f.name]
    )
    |> Repo.all()
  end

  @spec get!(Scope.t(), integer()) :: Folder.t()
  def get!(%Scope{} = scope, id) when is_integer(id) do
    folder = Repo.get!(Folder, id)
    :ok = enforce(scope, :read, folder)
    folder
  end

  @spec create(Scope.t(), map()) :: {:ok, Folder.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{user: %User{id: user_id}} = scope, attrs) do
    with :ok <- ensure_parent_writable(scope, attrs) do
      %Folder{owner_id: user_id}
      |> Folder.changeset(attrs)
      |> Repo.insert()
    end
  end

  @spec rename(Scope.t(), Folder.t(), String.t()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def rename(%Scope{} = scope, %Folder{} = folder, new_name) do
    with :ok <- enforce(scope, :write, folder) do
      folder
      |> Folder.changeset(%{name: new_name})
      |> Repo.update()
    end
  end

  @spec move(Scope.t(), Folder.t(), integer() | nil) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t() | :forbidden | :cycle}
  def move(%Scope{} = scope, %Folder{} = folder, new_parent_id) do
    with :ok <- enforce(scope, :write, folder),
         :ok <- ensure_no_cycle(folder, new_parent_id),
         :ok <- ensure_parent_writable(scope, %{parent_id: new_parent_id}) do
      folder
      |> Folder.changeset(%{parent_id: new_parent_id})
      |> Repo.update()
    end
  end

  @spec delete(Scope.t(), Folder.t()) ::
          {:ok, Folder.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete(%Scope{} = scope, %Folder{} = folder) do
    with :ok <- enforce(scope, :admin, folder) do
      Repo.delete(folder)
    end
  end

  ## Helpers

  defp enforce(scope, action, folder) do
    Permissions.authorize(scope, action, folder)
  end

  defp ensure_parent_writable(_scope, %{parent_id: nil}), do: :ok
  defp ensure_parent_writable(_scope, %{"parent_id" => nil}), do: :ok

  defp ensure_parent_writable(scope, attrs) do
    parent_id = attrs[:parent_id] || attrs["parent_id"]

    cond do
      is_nil(parent_id) ->
        :ok

      true ->
        case Repo.get(Folder, parent_id) do
          nil -> {:error, :parent_not_found}
          parent -> Permissions.authorize(scope, :write, parent)
        end
    end
  end

  defp ensure_no_cycle(_folder, nil), do: :ok

  defp ensure_no_cycle(%Folder{id: id}, new_parent_id) when id == new_parent_id,
    do: {:error, :cycle}

  defp ensure_no_cycle(%Folder{id: id}, new_parent_id) do
    if descendant?(id, new_parent_id), do: {:error, :cycle}, else: :ok
  end

  defp descendant?(folder_id, candidate_id) do
    case Repo.one(from f in Folder, where: f.id == ^candidate_id, select: f.parent_id) do
      nil -> false
      ^folder_id -> true
      parent_id -> descendant?(folder_id, parent_id)
    end
  end
end

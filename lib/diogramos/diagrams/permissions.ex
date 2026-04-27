defmodule Diogramos.Diagrams.Permissions do
  @moduledoc """
  Computes effective roles and authorizes actions on folders and canvases.

  Effective role for a user on a canvas is the strongest of:
    1. ownership (`canvas.owner_id == user.id` ⇒ :owner)
    2. direct grant on the canvas
    3. grant on any ancestor folder (closest ancestor wins, then strongest)

  For folders the same rules apply minus the canvas-specific lookup.

  Roles ranked weakest → strongest: viewer < editor < owner.
  """
  import Ecto.Query

  alias Diogramos.Repo
  alias Diogramos.Accounts.{Scope, User}
  alias Diogramos.Diagrams.{Canvas, Folder, Permission}

  @rank %{"viewer" => 1, "editor" => 2, "owner" => 3}

  @type role :: String.t()
  @type action :: :read | :write | :admin

  @doc """
  Returns the highest-ranking role the scope's user holds for the given
  resource, or nil if they have no access at all.
  """
  @spec effective_role(Scope.t() | nil, Canvas.t() | Folder.t()) :: role() | nil
  def effective_role(nil, _resource), do: nil
  def effective_role(%Scope{user: nil}, _resource), do: nil

  def effective_role(%Scope{user: %User{id: user_id}}, %Canvas{owner_id: user_id}), do: "owner"

  def effective_role(%Scope{user: %User{id: user_id}}, %Folder{owner_id: user_id}), do: "owner"

  def effective_role(%Scope{user: %User{id: user_id}}, %Canvas{} = canvas) do
    folder_chain = ancestor_folder_ids(canvas.folder_id)

    grants =
      from(p in Permission,
        where: p.principal_type == "user" and p.principal_id == ^user_id,
        where:
          (p.subject_type == "canvas" and p.subject_id == ^canvas.id) or
            (p.subject_type == "folder" and p.subject_id in ^folder_chain),
        select: p.role
      )
      |> Repo.all()

    strongest(grants)
  end

  def effective_role(%Scope{user: %User{id: user_id}}, %Folder{} = folder) do
    folder_chain = [folder.id | ancestor_folder_ids(folder.parent_id)]

    grants =
      from(p in Permission,
        where: p.principal_type == "user" and p.principal_id == ^user_id,
        where: p.subject_type == "folder" and p.subject_id in ^folder_chain,
        select: p.role
      )
      |> Repo.all()

    strongest(grants)
  end

  @doc """
  Authorizes an action against a resource.

      action ∈ [:read, :write, :admin]

  Returns `:ok` or `{:error, :forbidden}`.
  """
  @spec authorize(Scope.t() | nil, action(), Canvas.t() | Folder.t()) ::
          :ok | {:error, :forbidden}
  def authorize(scope, action, resource) do
    case effective_role(scope, resource) do
      nil -> {:error, :forbidden}
      role -> if allows?(role, action), do: :ok, else: {:error, :forbidden}
    end
  end

  @doc """
  Lists permission grants on a subject. Useful for sharing UIs.
  """
  def list_grants(subject_type, subject_id)
      when subject_type in ["folder", "canvas"] and is_integer(subject_id) do
    from(p in Permission,
      where: p.subject_type == ^subject_type and p.subject_id == ^subject_id,
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists user-targeted grants on a subject. Each grant is annotated with
  `:user` (the loaded `%User{}`) so UIs can render emails/display names
  without an N+1.
  """
  def list_user_grants(subject_type, subject_id)
      when subject_type in ["folder", "canvas"] and is_integer(subject_id) do
    grants =
      from(p in Permission,
        where: p.subject_type == ^subject_type and p.subject_id == ^subject_id,
        where: p.principal_type == "user",
        order_by: [desc: p.inserted_at]
      )
      |> Repo.all()

    user_ids = Enum.map(grants, & &1.principal_id)

    users =
      from(u in Diogramos.Accounts.User, where: u.id in ^user_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(grants, fn g -> Map.put(g, :user, users[g.principal_id]) end)
  end

  @doc """
  Inserts or updates a grant.
  """
  def grant(subject_type, subject_id, principal_type, principal_id, role, opts \\ [])
      when role in ["viewer", "editor", "owner"] do
    attrs = %{
      subject_type: subject_type,
      subject_id: subject_id,
      principal_type: principal_type,
      principal_id: principal_id,
      role: role,
      granted_by_id: Keyword.get(opts, :granted_by_id)
    }

    %Permission{}
    |> Permission.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:role, :granted_by_id, :updated_at]},
      conflict_target: [:subject_type, :subject_id, :principal_type, :principal_id]
    )
  end

  @doc """
  Removes a grant.
  """
  def revoke(subject_type, subject_id, principal_type, principal_id) do
    from(p in Permission,
      where:
        p.subject_type == ^subject_type and p.subject_id == ^subject_id and
          p.principal_type == ^principal_type and p.principal_id == ^principal_id
    )
    |> Repo.delete_all()
  end

  ## Internal helpers

  @doc false
  def allows?("owner", _), do: true
  def allows?("editor", :admin), do: false
  def allows?("editor", _), do: true
  def allows?("viewer", :read), do: true
  def allows?("viewer", _), do: false
  def allows?(_, _), do: false

  defp strongest([]), do: nil

  defp strongest(roles) do
    roles
    |> Enum.max_by(&Map.fetch!(@rank, &1))
  end

  defp ancestor_folder_ids(nil), do: []

  defp ancestor_folder_ids(folder_id) when is_integer(folder_id) do
    walk_ancestors(folder_id, [])
  end

  defp walk_ancestors(nil, acc), do: Enum.reverse(acc)

  defp walk_ancestors(folder_id, acc) do
    case Repo.one(from f in Folder, where: f.id == ^folder_id, select: f.parent_id) do
      nil -> Enum.reverse([folder_id | acc])
      parent_id -> walk_ancestors(parent_id, [folder_id | acc])
    end
  end
end

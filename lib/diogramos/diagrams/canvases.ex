defmodule Diogramos.Diagrams.Canvases do
  @moduledoc """
  Canvas CRUD scoped to the calling user. The `document` and `version`
  fields are owned by the live op pipeline (Phase 5) — these functions
  only manage metadata.
  """
  import Ecto.Query

  alias Diogramos.Repo
  alias Diogramos.Accounts.{Scope, User}
  alias Diogramos.Diagrams.{Canvas, Permission, Permissions}

  @spec list(Scope.t()) :: [Canvas.t()]
  def list(%Scope{user: %User{id: user_id}}) do
    direct =
      from(p in Permission,
        where: p.subject_type == "canvas",
        where: p.principal_type == "user" and p.principal_id == ^user_id,
        select: p.subject_id
      )

    from(c in Canvas,
      where: c.owner_id == ^user_id or c.id in subquery(direct),
      order_by: [desc: c.updated_at]
    )
    |> Repo.all()
  end

  @spec list_in_folder(Scope.t(), integer() | nil) :: [Canvas.t()]
  def list_in_folder(%Scope{user: %User{id: user_id}} = _scope, folder_id) do
    direct =
      from(p in Permission,
        where: p.subject_type == "canvas",
        where: p.principal_type == "user" and p.principal_id == ^user_id,
        select: p.subject_id
      )

    base =
      from(c in Canvas,
        where: c.owner_id == ^user_id or c.id in subquery(direct),
        order_by: [desc: c.updated_at]
      )

    case folder_id do
      nil -> from(c in base, where: is_nil(c.folder_id)) |> Repo.all()
      id -> from(c in base, where: c.folder_id == ^id) |> Repo.all()
    end
  end

  @spec get!(Scope.t(), integer()) :: Canvas.t()
  def get!(%Scope{} = scope, id) when is_integer(id) do
    canvas = Repo.get!(Canvas, id)
    :ok = Permissions.authorize(scope, :read, canvas)
    canvas
  end

  @spec get_by_slug(Scope.t(), String.t()) :: Canvas.t() | nil
  def get_by_slug(%Scope{} = scope, slug) when is_binary(slug) do
    case Repo.get_by(Canvas, slug: slug) do
      nil ->
        nil

      canvas ->
        case Permissions.authorize(scope, :read, canvas) do
          :ok -> canvas
          _ -> nil
        end
    end
  end

  @spec get_for_embed(String.t()) :: Canvas.t() | nil
  def get_for_embed(token) when is_binary(token) do
    Repo.get_by(Canvas, embed_token: token)
  end

  @spec create(Scope.t(), map()) :: {:ok, Canvas.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{user: %User{id: user_id}} = scope, attrs) do
    with :ok <- ensure_folder_writable(scope, attrs) do
      %Canvas{owner_id: user_id, document: empty_document()}
      |> Canvas.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @spec update_metadata(Scope.t(), Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def update_metadata(%Scope{} = scope, %Canvas{} = canvas, attrs) do
    with :ok <- Permissions.authorize(scope, :write, canvas),
         :ok <- ensure_folder_writable(scope, attrs) do
      canvas
      |> Canvas.metadata_changeset(attrs)
      |> Repo.update()
    end
  end

  @spec delete(Scope.t(), Canvas.t()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def delete(%Scope{} = scope, %Canvas{} = canvas) do
    with :ok <- Permissions.authorize(scope, :admin, canvas) do
      Repo.delete(canvas)
    end
  end

  @spec set_embed_token(Scope.t(), Canvas.t(), String.t() | nil) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def set_embed_token(%Scope{} = scope, %Canvas{} = canvas, token) do
    with :ok <- Permissions.authorize(scope, :admin, canvas) do
      canvas
      |> Canvas.embed_token_changeset(token)
      |> Repo.update()
    end
  end

  @spec generate_embed_token(Scope.t(), Canvas.t()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def generate_embed_token(scope, canvas) do
    set_embed_token(scope, canvas, fresh_token())
  end

  @doc """
  Persists a new document for an in-flight edit. The Phase-5 op pipeline
  will replace direct calls to this with GenServer-coordinated writes,
  but in Phase 3 the LiveView calls it directly after each successful
  `Document.apply_op/2`.
  """
  @spec replace_document(Scope.t(), Canvas.t(), map()) ::
          {:ok, Canvas.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def replace_document(%Scope{} = scope, %Canvas{} = canvas, document) when is_map(document) do
    with :ok <- Permissions.authorize(scope, :write, canvas) do
      canvas
      |> Ecto.Changeset.change(document: document, version: canvas.version + 1)
      |> Repo.update()
    end
  end

  @export_format "diogramos.canvas.v1"

  @doc """
  Returns a serializable representation of a canvas suitable for download.
  The shape is the canonical `import_canvas/2` input format.
  """
  @spec export(Scope.t(), Canvas.t()) :: {:ok, map()} | {:error, :forbidden}
  def export(%Scope{} = scope, %Canvas{} = canvas) do
    with :ok <- Permissions.authorize(scope, :read, canvas) do
      {:ok,
       %{
         "format" => @export_format,
         "title" => canvas.title,
         "theme" => canvas.theme,
         "document" => canvas.document,
         "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc """
  Creates a new canvas owned by the scope's user from an exported
  document map. Slug defaults to a randomly-suffixed kebab-case form of
  the title; pass `slug:` in opts to override.
  """
  @spec import_canvas(Scope.t(), map(), keyword()) ::
          {:ok, Canvas.t()} | {:error, :invalid_format | Ecto.Changeset.t()}
  def import_canvas(%Scope{user: %User{id: owner_id}} = _scope, %{} = data, opts \\ []) do
    with :ok <- ensure_export_format(data),
         {:ok, document} <- ensure_document_shape(data["document"]) do
      title = data["title"] || "Imported canvas"
      theme = data["theme"] || "afterdark"
      slug = Keyword.get(opts, :slug) || generate_unique_slug(title)

      %Canvas{owner_id: owner_id, document: document}
      |> Canvas.create_changeset(%{
        slug: slug,
        title: title,
        theme: if(theme in Diogramos.Themes.all(), do: theme, else: "afterdark"),
        folder_id: Keyword.get(opts, :folder_id)
      })
      |> Repo.insert()
    end
  end

  defp ensure_export_format(%{"format" => @export_format}), do: :ok
  defp ensure_export_format(_), do: {:error, :invalid_format}

  defp ensure_document_shape(%{"elements" => _, "order" => _, "connectors" => _} = doc),
    do: {:ok, doc}

  defp ensure_document_shape(_), do: {:error, :invalid_format}

  defp generate_unique_slug(title) do
    base =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    base = if base == "", do: "canvas", else: base
    suffix = :crypto.strong_rand_bytes(3) |> Base.url_encode64(padding: false) |> String.downcase()
    base <> "-" <> suffix
  end

  ## Helpers

  defp empty_document do
    %{"elements" => %{}, "order" => [], "connectors" => %{}}
  end

  defp fresh_token do
    :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  end

  defp ensure_folder_writable(_scope, attrs) when attrs == %{}, do: :ok

  defp ensure_folder_writable(scope, attrs) do
    folder_id = attrs[:folder_id] || attrs["folder_id"]

    if folder_id do
      case Repo.get(Diogramos.Diagrams.Folder, folder_id) do
        nil -> {:error, :folder_not_found}
        folder -> Permissions.authorize(scope, :write, folder)
      end
    else
      :ok
    end
  end
end

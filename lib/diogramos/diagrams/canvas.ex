defmodule Diogramos.Diagrams.Canvas do
  @moduledoc """
  A drawable canvas. Holds the authoritative document JSON, its monotonic
  version counter, and the optional embed token used by the read-only
  embed route.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Diogramos.Accounts.User
  alias Diogramos.Diagrams.Folder

  @derive {Jason.Encoder,
           only: [
             :id,
             :slug,
             :title,
             :theme,
             :document,
             :version,
             :embed_show_cursors,
             :inserted_at,
             :updated_at
           ]}

  schema "canvases" do
    field :slug, :string
    field :title, :string
    field :theme, :string, default: "afterdark"
    field :document, :map, default: %{}
    field :version, :integer, default: 0
    field :embed_token, :string
    field :embed_show_cursors, :boolean, default: true

    belongs_to :owner, User
    belongs_to :folder, Folder

    timestamps(type: :utc_datetime)
  end

  @doc false
  def create_changeset(canvas, attrs) do
    canvas
    |> cast(attrs, [:slug, :title, :theme, :folder_id])
    |> validate_required([:slug, :title])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{0,63}$/,
      message: "must be 1-64 chars, lowercase a-z, 0-9, hyphens"
    )
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:theme, Diogramos.Themes.all())
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:folder_id)
    |> foreign_key_constraint(:owner_id)
  end

  @doc """
  Updates user-editable metadata. Excludes `document` and `version` —
  those flow through the live op pipeline, not Ecto changesets.
  """
  def metadata_changeset(canvas, attrs) do
    canvas
    |> cast(attrs, [:title, :theme, :folder_id, :embed_show_cursors])
    |> validate_required([:title, :theme])
    |> validate_length(:title, min: 1, max: 200)
    |> validate_inclusion(:theme, Diogramos.Themes.all())
    |> foreign_key_constraint(:folder_id)
  end

  @doc """
  Sets or clears the embed token. Pass `nil` to disable embedding.
  """
  def embed_token_changeset(canvas, token) when is_binary(token) or is_nil(token) do
    canvas
    |> change(embed_token: token)
    |> unique_constraint(:embed_token, name: :canvases_embed_token_index)
  end
end

defmodule Diogramos.Diagrams.Folder do
  @moduledoc """
  A virtual folder that owns canvases and other folders. Permissions
  granted on a folder cascade to its contents.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Diogramos.Accounts.User

  schema "folders" do
    field :name, :string

    belongs_to :owner, User
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :canvases, Diogramos.Diagrams.Canvas

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:name, :parent_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:owner_id)
  end
end

defmodule Diogramos.Diagrams.CanvasOp do
  @moduledoc """
  Append-only WAL row capturing a single op applied to a canvas. The
  authoritative GenServer writes one of these per accepted op, so we can
  recover from a crash by replaying ops past the last persisted snapshot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Diogramos.Accounts.User
  alias Diogramos.Diagrams.Canvas

  @primary_key {:id, :id, autogenerate: true}
  schema "canvas_ops" do
    field :version, :integer
    field :op, :map
    field :inserted_at, :utc_datetime, read_after_writes: true

    belongs_to :canvas, Canvas
    belongs_to :actor, User
  end

  @doc false
  def changeset(canvas_op, attrs) do
    canvas_op
    |> cast(attrs, [:canvas_id, :version, :op, :actor_id])
    |> validate_required([:canvas_id, :version, :op])
    |> unique_constraint([:canvas_id, :version])
  end
end

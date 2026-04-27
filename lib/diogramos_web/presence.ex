defmodule DiogramosWeb.Presence do
  @moduledoc """
  Tracks per-canvas presence: who's editing, where their cursor is, and
  what (if anything) they're currently dragging.
  """
  use Phoenix.Presence,
    otp_app: :diogramos,
    pubsub_server: Diogramos.PubSub
end

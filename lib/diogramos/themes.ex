defmodule Diogramos.Themes do
  @moduledoc """
  Catalog of UI themes available to the app and to canvas embeds.

  Names map 1:1 to daisyUI theme plugin entries in `assets/css/app.css`.
  """

  @neiam ~w(her afterdark forest sky clays stones)
  @builtin ~w(light dark)
  @custom ~w(blueprint)

  @type theme :: String.t()

  @spec all() :: [theme()]
  def all, do: @builtin ++ @neiam ++ @custom

  @spec neiam() :: [theme()]
  def neiam, do: @neiam

  @spec default() :: theme()
  def default, do: "afterdark"

  @spec valid?(theme()) :: boolean()
  def valid?(theme) when is_binary(theme), do: theme in all() or theme == "system"
  def valid?(_), do: false

  @color_tokens ~w(
    transparent
    base-100 base-200 base-300 base-content
    primary secondary accent
    info success warning error
  )

  @doc """
  Whitelist of daisyUI color tokens that shape `fill` / `stroke` and
  connector `stroke` may reference. Stored as plain strings; the
  renderer maps them to `var(--color-<token>)`.
  """
  @spec color_tokens() :: [String.t()]
  def color_tokens, do: @color_tokens

  @spec valid_color?(String.t()) :: boolean()
  def valid_color?(token) when is_binary(token), do: token in @color_tokens
  def valid_color?(_), do: false
end

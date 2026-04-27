defmodule Diogramos.Features do
  @moduledoc """
  Reads phase-gated feature flags from `config :diogramos, :features`.

  Call sites use `Features.enabled?(:flag_name)` rather than reading
  `Application.get_env/3` directly so flag names are typo-checked here
  and so a single grep finds every usage.
  """

  @type flag :: atom()

  @spec enabled?(flag()) :: boolean()
  def enabled?(flag) when is_atom(flag) do
    flags()
    |> Keyword.get(flag, false)
    |> truthy?()
  end

  @spec all() :: keyword()
  def all, do: flags()

  defp flags do
    Application.get_env(:diogramos, :features, [])
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end

defmodule DiogramosWeb.CanvasPresence do
  @moduledoc """
  Thin wrapper around `Phoenix.Presence` for canvas editing sessions.

  Each presence entry is keyed by the user id (or a per-tab synthetic key
  for anonymous viewers) and carries `:name`, `:color`, `:cursor`, and
  `:lock` metas. The editor and embed LiveViews use these to render
  ghost cursors and ghosted-out elements while another peer drags them.
  """

  alias DiogramosWeb.Presence

  @type peer :: %{
          key: String.t(),
          name: String.t(),
          color: String.t(),
          cursor: %{x: number(), y: number()} | nil,
          lock: String.t() | nil,
          source: String.t()
        }

  @palette ~w(#f97316 #ef4444 #eab308 #22c55e #06b6d4 #3b82f6 #8b5cf6 #ec4899)

  @animals ~w(
    otter penguin badger fox owl raven heron quokka panda lemur tapir gecko
    axolotl narwhal pangolin ibis kakapo capybara raccoon ferret hedgehog koala
    lynx serval finch toucan platypus salamander octopus stingray manatee
  )

  @color_words ~w(
    crimson saffron amber jade teal indigo violet magenta scarlet sage
    maroon plum cobalt cerulean coral mint apricot lilac garnet ochre
    russet azure cinnabar emerald onyx ivory chartreuse tangerine moss
  )

  @doc "Returns the colour palette used for randomly-assigned cursor colours."
  def palette, do: @palette

  @doc """
  Returns a fun two-word display name like \"Mauve Otter\" — used as the
  default identity for embed-side cursor presences.
  """
  def random_animal_name do
    "#{Enum.random(@color_words)} #{Enum.random(@animals)}"
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "Returns a random colour from `palette/0`."
  def random_color, do: Enum.random(@palette)

  @spec track(pid(), String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def track(pid, topic, %{key: key} = identity) do
    Presence.track(pid, topic, key, %{
      name: identity[:name] || "Guest",
      color: identity[:color] || color_for(key),
      cursor: nil,
      lock: nil,
      source: identity[:source] || "editor",
      joined_at: System.system_time(:millisecond)
    })
  end

  @spec update(pid(), String.t(), String.t(), (map() -> map())) :: {:ok, binary()} | :error
  def update(pid, topic, key, fun) do
    Presence.update(pid, topic, key, fun)
  end

  @doc """
  Returns one peer entry per key (collapsing multiple tabs into the
  most-recent cursor/lock). The peer matching `self_key` is dropped so
  the LV doesn't render its own ghost cursor.
  """
  @spec list_peers(String.t(), String.t() | nil, keyword()) :: [peer()]
  def list_peers(topic, self_key, opts \\ []) do
    exclude_sources = Keyword.get(opts, :exclude_sources, [])

    Presence.list(topic)
    |> Enum.reject(fn {key, _} -> key == self_key end)
    |> Enum.map(fn {key, %{metas: metas}} ->
      latest = Enum.max_by(metas, & &1.joined_at)

      %{
        key: key,
        name: latest.name,
        color: latest.color,
        cursor: latest.cursor,
        lock: latest.lock,
        source: Map.get(latest, :source, "editor")
      }
    end)
    |> Enum.reject(fn peer -> peer.source in exclude_sources end)
  end

  @doc """
  Returns the union of element ids currently being dragged by some peer.
  Used to ghost-out shapes that are mid-drag elsewhere.
  """
  @spec locked_elements(String.t(), String.t() | nil) :: MapSet.t()
  def locked_elements(topic, self_key) do
    list_peers(topic, self_key)
    |> Enum.reduce(MapSet.new(), fn
      %{lock: nil}, acc -> acc
      %{lock: id}, acc -> MapSet.put(acc, id)
    end)
  end

  defp color_for(key) do
    idx = :erlang.phash2(key, length(@palette))
    Enum.at(@palette, idx)
  end
end

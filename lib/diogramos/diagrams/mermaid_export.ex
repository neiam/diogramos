defmodule Diogramos.Diagrams.MermaidExport do
  @moduledoc """
  Renders a canvas document as a Mermaid `flowchart LR` source string.

  Mappings:

    * `rect`     → `id["label"]`
    * `rounded`  → `id("label")`
    * `circle`   → `id(("label"))`
    * `text`     → emitted as a comment node

  Connector arrow styles follow the connector's `marker_end` and `dash`:

      marker_end | dash    → arrow
      ---------- | ------- | -----
      none       | solid   → ---
      none       | dashed  → -.-
      arrow      | solid   → -->
      arrow      | dashed  → -.->

  Connector labels become `|label|` between the arrow and the target.
  """

  alias Diogramos.Diagrams.Document

  @spec to_mermaid(Document.document()) :: String.t()
  def to_mermaid(document) do
    elements = document["elements"] || %{}
    connectors = document["connectors"] || %{}

    id_map = build_id_map(elements)

    nodes =
      document["order"]
      |> Enum.map(&elements[&1])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&render_node(&1, id_map))
      |> Enum.reject(&(&1 == ""))

    edges =
      connectors
      |> Map.values()
      |> Enum.map(&render_edge(&1, id_map, elements))
      |> Enum.reject(&(&1 == ""))

    ["flowchart LR" | indent(nodes ++ edges)]
    |> Enum.join("\n")
  end

  ## Nodes -----------------------------------------------------------------

  defp render_node(%{"id" => id, "type" => "rect", "label" => label}, ids),
    do: "#{ids[id]}[\"#{escape(label)}\"]"

  defp render_node(%{"id" => id, "type" => "rounded", "label" => label}, ids),
    do: "#{ids[id]}(\"#{escape(label)}\")"

  defp render_node(%{"id" => id, "type" => "circle", "label" => label}, ids),
    do: "#{ids[id]}((\"#{escape(label)}\"))"

  defp render_node(%{"type" => "text", "label" => label}, _ids),
    do: "%% text: #{escape(label)}"

  defp render_node(_, _), do: ""

  ## Edges -----------------------------------------------------------------

  defp render_edge(connector, ids, elements) do
    from_id = connector["from"]["element"]
    to_id = connector["to"]["element"]

    cond do
      is_nil(elements[from_id]) or is_nil(elements[to_id]) ->
        ""

      true ->
        arrow = arrow_for(connector)
        label = connector["label"] || ""

        if label == "" do
          "#{ids[from_id]} #{arrow} #{ids[to_id]}"
        else
          "#{ids[from_id]} #{arrow}|#{escape(label)}| #{ids[to_id]}"
        end
    end
  end

  defp arrow_for(%{"marker_end" => "none", "dash" => dash}), do: line(dash)
  defp arrow_for(%{"marker_end" => _, "dash" => dash}), do: line(dash) <> ">"

  defp line("dashed"), do: "-.-"
  defp line("dash-dot"), do: "-.-"
  defp line("dotted"), do: "-.-"
  defp line(_), do: "---"

  ## Helpers ---------------------------------------------------------------

  defp build_id_map(elements) do
    elements
    |> Map.keys()
    |> Enum.with_index()
    |> Map.new(fn {id, idx} -> {id, "n#{idx}"} end)
  end

  defp escape(label) when is_binary(label) do
    label
    |> String.replace("\"", "&quot;")
    |> String.replace("\n", " ")
  end

  defp escape(_), do: ""

  defp indent(lines), do: Enum.map(lines, &("  " <> &1))
end

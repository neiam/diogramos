defmodule Diogramos.Diagrams.ConnectorGeometry do
  @moduledoc """
  Computes SVG path data for a connector given the document it lives in.

  Three routing modes:

    * `"straight"` — a single line from anchor-to-anchor, shrunk by
      `start_gap` and `end_gap` along the line.
    * `"orthogonal"` — an L- or Z-shaped path that exits the source
      perpendicular to the chosen anchor edge, meets the target's
      anchor edge perpendicular, and shrinks by the gaps.
    * `"curve"` — a cubic Bézier with control points pulled along the
      anchor normals.

  Anchors are resolved per `auto` / `n|e|s|w` / `point`:
    * `auto` picks the cardinal edge of the source/target whose center
      direction best aligns with the line between bounding boxes.
    * `point` is an absolute coordinate (used for connectors anchored to
      empty canvas positions, e.g. labels).
  """

  alias Diogramos.Diagrams.Document

  @type point :: {number(), number()}
  @type rendered :: %{
          d: String.t(),
          stroke_width: number(),
          dash_array: String.t() | nil,
          marker_start: String.t(),
          marker_end: String.t()
        }

  @dash_arrays %{
    "solid" => nil,
    "dotted" => "2 4",
    "dashed" => "8 6",
    "dash-dot" => "8 4 2 4"
  }

  @doc """
  Returns rendering data for a connector. Returns `nil` if either
  endpoint element is missing (caller can choose to skip).
  """
  @spec render(map(), Document.document()) :: rendered() | nil
  def render(connector, document) do
    with {:ok, from_pt, from_normal} <- resolve_endpoint(connector["from"], document),
         {:ok, to_pt, to_normal} <- resolve_endpoint(connector["to"], document) do
      from_pt = shrink(from_pt, from_normal, connector["start_gap"] || 6)
      to_pt = shrink(to_pt, to_normal, connector["end_gap"] || 6)

      d =
        case Map.get(connector, "routing", "orthogonal") do
          "straight" -> path_straight(from_pt, to_pt)
          "orthogonal" -> path_orthogonal(from_pt, from_normal, to_pt, to_normal)
          "curve" -> path_curve(from_pt, from_normal, to_pt, to_normal)
        end

      %{
        d: d,
        stroke_width: Map.get(connector, "stroke_width", 2),
        dash_array: Map.fetch!(@dash_arrays, Map.get(connector, "dash", "solid")),
        marker_start: Map.get(connector, "marker_start", "none"),
        marker_end: Map.get(connector, "marker_end", "arrow")
      }
    else
      _ -> nil
    end
  end

  ## Anchor resolution -----------------------------------------------------

  defp resolve_endpoint(%{"element" => id} = anchor, document) do
    case document["elements"][id] do
      nil ->
        :error

      element ->
        case Map.get(anchor, "anchor", "auto") do
          "point" -> {:ok, {anchor["x"], anchor["y"]}, {0, 0}}
          a -> point_for_anchor(element, a, anchor, document)
        end
    end
  end

  defp resolve_endpoint(_, _), do: :error

  defp point_for_anchor(element, "auto", anchor_def, document) do
    other_id = anchor_def["_other"] || nil
    bbox = bbox(element)
    other_center = other_center(other_id, document) || center(bbox)
    {pt, normal} = best_edge(bbox, other_center)
    {:ok, pt, normal}
  end

  defp point_for_anchor(element, side, _anchor_def, _document) when side in ~w(n e s w) do
    bbox = bbox(element)
    {pt, normal} = edge(bbox, side)
    {:ok, pt, normal}
  end

  defp point_for_anchor(_, _, _, _), do: :error

  ## Geometry helpers ------------------------------------------------------

  defp bbox(%{"type" => "circle", "cx" => cx, "cy" => cy, "r" => r}) do
    {cx - r, cy - r, 2 * r, 2 * r}
  end

  defp bbox(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: {x, y, w, h}

  defp center({x, y, w, h}), do: {x + w / 2, y + h / 2}

  defp edge({x, y, w, h}, side) do
    case side do
      "n" -> {{x + w / 2, y}, {0, -1}}
      "s" -> {{x + w / 2, y + h}, {0, 1}}
      "e" -> {{x + w, y + h / 2}, {1, 0}}
      "w" -> {{x, y + h / 2}, {-1, 0}}
    end
  end

  defp best_edge(bbox, {ox, oy}) do
    {cx, cy} = center(bbox)
    dx = ox - cx
    dy = oy - cy

    cond do
      abs(dx) >= abs(dy) and dx >= 0 -> edge(bbox, "e")
      abs(dx) >= abs(dy) -> edge(bbox, "w")
      dy >= 0 -> edge(bbox, "s")
      true -> edge(bbox, "n")
    end
  end

  defp other_center(nil, _), do: nil

  defp other_center(id, document) do
    case document["elements"][id] do
      nil -> nil
      element -> center(bbox(element))
    end
  end

  defp shrink({x, y}, {nx, ny}, gap) when is_number(gap) and gap > 0 do
    {x + nx * gap, y + ny * gap}
  end

  defp shrink(point, _normal, _gap), do: point

  ## Path construction -----------------------------------------------------

  defp path_straight({x1, y1}, {x2, y2}) do
    "M #{f(x1)} #{f(y1)} L #{f(x2)} #{f(y2)}"
  end

  defp path_orthogonal({x1, y1} = a, {nx, ny}, {x2, y2} = b, _to_normal) do
    cond do
      # Source exits horizontally → meet at midpoint x
      ny == 0 ->
        mx = (x1 + x2) / 2
        "M #{f(x1)} #{f(y1)} L #{f(mx)} #{f(y1)} L #{f(mx)} #{f(y2)} L #{f(x2)} #{f(y2)}"

      # Source exits vertically → meet at midpoint y
      nx == 0 ->
        my = (y1 + y2) / 2
        "M #{f(x1)} #{f(y1)} L #{f(x1)} #{f(my)} L #{f(x2)} #{f(my)} L #{f(x2)} #{f(y2)}"

      true ->
        path_straight(a, b)
    end
  end

  defp path_curve({x1, y1}, {nx1, ny1}, {x2, y2}, {nx2, ny2}) do
    distance = max(:math.sqrt(:math.pow(x2 - x1, 2) + :math.pow(y2 - y1, 2)), 1.0)
    pull = distance * 0.4

    c1x = x1 + nx1 * pull
    c1y = y1 + ny1 * pull
    c2x = x2 + nx2 * pull
    c2y = y2 + ny2 * pull

    "M #{f(x1)} #{f(y1)} C #{f(c1x)} #{f(c1y)}, #{f(c2x)} #{f(c2y)}, #{f(x2)} #{f(y2)}"
  end

  defp f(n) when is_integer(n), do: Integer.to_string(n)

  defp f(n) when is_float(n) do
    truncated = trunc(n)

    if n == truncated do
      Integer.to_string(truncated)
    else
      :erlang.float_to_binary(n, [:compact, {:decimals, 2}])
    end
  end
end

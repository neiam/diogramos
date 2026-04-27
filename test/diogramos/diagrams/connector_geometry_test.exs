defmodule Diogramos.Diagrams.ConnectorGeometryTest do
  use ExUnit.Case, async: true
  alias Diogramos.Diagrams.{ConnectorGeometry, Document}

  defp doc do
    Document.new()
    |> apply!(%{
      "type" => "insert_element",
      "element" => %{"id" => "a", "type" => "rect", "x" => 0, "y" => 0, "w" => 100, "h" => 60}
    })
    |> apply!(%{
      "type" => "insert_element",
      "element" => %{
        "id" => "b",
        "type" => "rect",
        "x" => 300,
        "y" => 200,
        "w" => 100,
        "h" => 60
      }
    })
  end

  defp apply!(d, op) do
    {:ok, d2} = Document.apply_op(d, op)
    d2
  end

  defp connector(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "k1",
        "from" => %{"element" => "a", "anchor" => "e"},
        "to" => %{"element" => "b", "anchor" => "w"},
        "routing" => "straight",
        "dash" => "solid",
        "marker_start" => "none",
        "marker_end" => "arrow",
        "start_gap" => 0,
        "end_gap" => 0,
        "stroke_width" => 2
      },
      extra
    )
  end

  test "straight routing draws line between cardinal anchors" do
    rendered = ConnectorGeometry.render(connector(), doc())
    # source east edge (100, 30), target west edge (300, 230)
    assert rendered.d == "M 100 30 L 300 230"
    assert rendered.dash_array == nil
    assert rendered.marker_end == "arrow"
  end

  test "applies start_gap and end_gap along the anchor normal" do
    rendered = ConnectorGeometry.render(connector(%{"start_gap" => 10, "end_gap" => 5}), doc())
    # east anchor (100,30) shrinks +10 along x-normal → (110, 30)
    # west anchor (300,230) shrinks -5 along x-normal → (295, 230)
    assert rendered.d == "M 110 30 L 295 230"
  end

  test "orthogonal routing emits a Z-shape from horizontal anchor" do
    rendered = ConnectorGeometry.render(connector(%{"routing" => "orthogonal"}), doc())
    # midpoint x = 200; from (100,30) → (200,30) → (200,230) → (300,230)
    assert rendered.d =~ "M 100 30"
    assert rendered.d =~ "L 200 30"
    assert rendered.d =~ "L 200 230"
    assert rendered.d =~ "L 300 230"
  end

  test "curve routing emits a cubic Bezier" do
    rendered = ConnectorGeometry.render(connector(%{"routing" => "curve"}), doc())
    assert rendered.d =~ ~r/^M [\d.]+ [\d.]+ C /
  end

  test "dash presets translate to stroke-dasharray" do
    for {preset, expected} <- [
          {"solid", nil},
          {"dotted", "2 4"},
          {"dashed", "8 6"},
          {"dash-dot", "8 4 2 4"}
        ] do
      rendered = ConnectorGeometry.render(connector(%{"dash" => preset}), doc())
      assert rendered.dash_array == expected, "dash=#{preset}"
    end
  end

  test "missing endpoint returns nil" do
    bad =
      connector()
      |> Map.put("to", %{"element" => "ghost", "anchor" => "auto"})

    assert ConnectorGeometry.render(bad, doc()) == nil
  end

  test "auto anchor picks the appropriate edge based on relative position" do
    # b is south-east of a, so auto from a should pick east
    c =
      connector()
      |> Map.put("from", %{"element" => "a", "anchor" => "auto", "_other" => "b"})
      |> Map.put("to", %{"element" => "b", "anchor" => "auto", "_other" => "a"})

    rendered = ConnectorGeometry.render(c, doc())
    # from = east edge of a = (100, 30); to = west edge of b = (300, 230)
    assert rendered.d == "M 100 30 L 300 230"
  end
end

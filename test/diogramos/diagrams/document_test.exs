defmodule Diogramos.Diagrams.DocumentTest do
  use ExUnit.Case, async: true
  alias Diogramos.Diagrams.Document

  defp rect(id, x \\ 0, y \\ 0, w \\ 100, h \\ 60) do
    %{"id" => id, "type" => "rect", "x" => x, "y" => y, "w" => w, "h" => h}
  end

  defp insert!(doc, element) do
    {:ok, doc} = Document.apply_op(doc, %{"type" => "insert_element", "element" => element})
    doc
  end

  describe "elements" do
    test "insert_element adds to elements + order" do
      doc =
        Document.new()
        |> insert!(rect("a"))
        |> insert!(rect("b", 200))

      assert doc["order"] == ["a", "b"]
      assert map_size(doc["elements"]) == 2
    end

    test "insert_element rejects duplicate ids" do
      doc = Document.new() |> insert!(rect("a"))

      assert {:error, :duplicate_id} =
               Document.apply_op(doc, %{"type" => "insert_element", "element" => rect("a")})
    end

    test "insert_element rejects malformed geometry" do
      bad = %{"id" => "x", "type" => "rect", "x" => 0, "y" => 0, "w" => -5, "h" => 10}

      assert {:error, :invalid_element_geometry} =
               Document.apply_op(Document.new(), %{"type" => "insert_element", "element" => bad})
    end

    test "circle requires cx/cy/r" do
      good = %{"id" => "c", "type" => "circle", "cx" => 50, "cy" => 50, "r" => 25}

      assert {:ok, _} =
               Document.apply_op(Document.new(), %{"type" => "insert_element", "element" => good})

      bad = %{"id" => "c", "type" => "circle", "cx" => 50, "cy" => 50, "r" => -1}

      assert {:error, :invalid_element_geometry} =
               Document.apply_op(Document.new(), %{"type" => "insert_element", "element" => bad})
    end

    test "update_element merges patch" do
      doc = Document.new() |> insert!(rect("a"))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "update_element",
          "id" => "a",
          "patch" => %{"x" => 50, "label" => "hi"}
        })

      assert doc["elements"]["a"]["x"] == 50
      assert doc["elements"]["a"]["label"] == "hi"
    end

    test "update_element rejects type/id changes" do
      doc = Document.new() |> insert!(rect("a"))

      assert {:error, :id_immutable} =
               Document.apply_op(doc, %{
                 "type" => "update_element",
                 "id" => "a",
                 "patch" => %{"id" => "b"}
               })

      assert {:error, :type_immutable} =
               Document.apply_op(doc, %{
                 "type" => "update_element",
                 "id" => "a",
                 "patch" => %{"type" => "circle"}
               })
    end

    test "delete_element removes referencing connectors" do
      doc =
        Document.new()
        |> insert!(rect("a"))
        |> insert!(rect("b", 200))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "insert_connector",
          "connector" => %{
            "id" => "k1",
            "from" => %{"element" => "a", "anchor" => "auto"},
            "to" => %{"element" => "b", "anchor" => "auto"}
          }
        })

      {:ok, doc} = Document.apply_op(doc, %{"type" => "delete_element", "id" => "a"})
      assert doc["connectors"] == %{}
      refute Map.has_key?(doc["elements"], "a")
    end
  end

  describe "connectors" do
    test "insert_connector requires both endpoints to exist" do
      assert {:error, :missing_endpoint} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_connector",
                 "connector" => %{
                   "id" => "k1",
                   "from" => %{"element" => "ghost", "anchor" => "auto"},
                   "to" => %{"element" => "alsoghost", "anchor" => "auto"}
                 }
               })
    end

    test "insert_connector applies defaults" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "insert_connector",
          "connector" => %{
            "id" => "k1",
            "from" => %{"element" => "a", "anchor" => "auto"},
            "to" => %{"element" => "b", "anchor" => "auto"}
          }
        })

      c = doc["connectors"]["k1"]
      assert c["routing"] == "orthogonal"
      assert c["dash"] == "solid"
      assert c["marker_end"] == "arrow"
      assert c["start_gap"] == 6
      assert c["end_gap"] == 6
      assert c["stroke_width"] == 2
    end

    test "insert_connector rejects invalid routing/dash/marker" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))

      base = %{
        "id" => "k1",
        "from" => %{"element" => "a", "anchor" => "auto"},
        "to" => %{"element" => "b", "anchor" => "auto"}
      }

      for {key, value, err} <- [
            {"routing", "wiggly", :invalid_routing},
            {"dash", "rainbow", :invalid_dash},
            {"marker_end", "lightning", :invalid_marker},
            {"end_gap", -1, :invalid_gap},
            {"stroke_width", 0, :invalid_stroke_width}
          ] do
        bad = Map.put(base, key, value)

        assert {:error, ^err} =
                 Document.apply_op(doc, %{"type" => "insert_connector", "connector" => bad})
      end
    end

    test "update_connector rejects invalid patches and accepts valid ones" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "insert_connector",
          "connector" => %{
            "id" => "k1",
            "from" => %{"element" => "a", "anchor" => "auto"},
            "to" => %{"element" => "b", "anchor" => "auto"}
          }
        })

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "update_connector",
          "id" => "k1",
          "patch" => %{"dash" => "dashed", "stroke_width" => 4}
        })

      assert doc["connectors"]["k1"]["dash"] == "dashed"
      assert doc["connectors"]["k1"]["stroke_width"] == 4
    end
  end

  describe "z order" do
    test "set_z_order rejects mismatched element sets" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))

      assert {:error, :order_mismatch} =
               Document.apply_op(doc, %{"type" => "set_z_order", "order" => ["a"]})

      assert {:error, :order_mismatch} =
               Document.apply_op(doc, %{"type" => "set_z_order", "order" => ["a", "b", "c"]})
    end

    test "set_z_order replaces order" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))
      {:ok, doc} = Document.apply_op(doc, %{"type" => "set_z_order", "order" => ["b", "a"]})
      assert doc["order"] == ["b", "a"]
    end
  end

  describe "style validation" do
    test "insert_element rejects unknown color tokens" do
      bad =
        rect("a")
        |> Map.put("style", %{"fill" => "rainbow"})

      assert {:error, :invalid_color} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "update_element merges style without dropping siblings" do
      doc =
        Document.new()
        |> insert!(rect("a") |> Map.put("style", %{"fill" => "primary", "stroke" => "accent"}))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "update_element",
          "id" => "a",
          "patch" => %{"style" => %{"fill" => "secondary"}}
        })

      style = doc["elements"]["a"]["style"]
      assert style["fill"] == "secondary"
      assert style["stroke"] == "accent"
    end

    test "insert_connector defaults color to base-content" do
      doc =
        Document.new()
        |> insert!(rect("a"))
        |> insert!(rect("b", 200))

      {:ok, doc} =
        Document.apply_op(doc, %{
          "type" => "insert_connector",
          "connector" => %{
            "id" => "k1",
            "from" => %{"element" => "a", "anchor" => "auto"},
            "to" => %{"element" => "b", "anchor" => "auto"}
          }
        })

      assert doc["connectors"]["k1"]["color"] == "base-content"
    end

    test "insert_connector rejects unknown color" do
      doc = Document.new() |> insert!(rect("a")) |> insert!(rect("b", 200))

      bad = %{
        "id" => "k1",
        "from" => %{"element" => "a", "anchor" => "auto"},
        "to" => %{"element" => "b", "anchor" => "auto"},
        "color" => "rainbow"
      }

      assert {:error, :invalid_color} =
               Document.apply_op(doc, %{"type" => "insert_connector", "connector" => bad})
    end

    test "text element accepts whitelisted font_family tokens including B612" do
      for family <- ~w(sans serif mono b612 b612-mono) do
        text = %{
          "id" => "t-" <> family,
          "type" => "text",
          "x" => 0,
          "y" => 0,
          "w" => 60,
          "h" => 20,
          "label" => family,
          "style" => %{"font_family" => family}
        }

        assert {:ok, _doc} =
                 Document.apply_op(Document.new(), %{
                   "type" => "insert_element",
                   "element" => text
                 })
      end
    end

    test "text element rejects unknown font_family" do
      bad = %{
        "id" => "t-bad",
        "type" => "text",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 20,
        "style" => %{"font_family" => "comic-sans"}
      }

      assert {:error, :invalid_font_family} =
               Document.apply_op(Document.new(), %{"type" => "insert_element", "element" => bad})
    end

    test "element accepts a list of metadata links" do
      good =
        rect("a")
        |> Map.put("links", [
          %{
            "enabled" => true,
            "kind" => "external",
            "target" => "https://example.com",
            "icon" => "globe-alt"
          },
          %{
            "enabled" => true,
            "kind" => "canvas",
            "target" => "another-canvas",
            "icon" => "link"
          }
        ])

      assert {:ok, _} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => good
               })
    end

    test "element rejects a links list with an unknown icon" do
      bad =
        rect("a")
        |> Map.put("links", [%{"enabled" => true, "target" => "x", "icon" => "fire"}])

      assert {:error, :invalid_link_icon} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "element rejects an enabled link with empty target" do
      bad =
        rect("a")
        |> Map.put("links", [%{"enabled" => true, "target" => "", "icon" => "link"}])

      assert {:error, :invalid_link_target} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "shape rejects unknown label_position" do
      bad =
        rect("a")
        |> Map.put("style", %{"label_position" => "north-pole"})

      assert {:error, :invalid_label_position} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "shape rejects unknown label_size" do
      bad =
        rect("a")
        |> Map.put("style", %{"label_size" => "huge"})

      assert {:error, :invalid_label_size} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "shape rejects unknown border dash" do
      bad =
        rect("a")
        |> Map.put("style", %{"dash" => "rainbow"})

      assert {:error, :invalid_dash} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "shape rejects non-positive stroke_width" do
      bad =
        rect("a")
        |> Map.put("style", %{"stroke_width" => 0})

      assert {:error, :invalid_stroke_width} =
               Document.apply_op(Document.new(), %{
                 "type" => "insert_element",
                 "element" => bad
               })
    end

    test "text element rejects out-of-range font_size" do
      for size <- [0, 3, 257, -10] do
        bad = %{
          "id" => "t-#{size}",
          "type" => "text",
          "x" => 0,
          "y" => 0,
          "w" => 60,
          "h" => 20,
          "style" => %{"font_size" => size}
        }

        assert {:error, :invalid_font_size} =
                 Document.apply_op(Document.new(), %{
                   "type" => "insert_element",
                   "element" => bad
                 })
      end
    end
  end

  test "unknown op returns :unknown_op" do
    assert {:error, :unknown_op} =
             Document.apply_op(Document.new(), %{"type" => "explode"})
  end
end

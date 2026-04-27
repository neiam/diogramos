defmodule Diogramos.Diagrams.MermaidExportTest do
  use ExUnit.Case, async: true
  alias Diogramos.Diagrams.{Document, MermaidExport}

  defp insert!(doc, op) do
    {:ok, doc} = Document.apply_op(doc, op)
    doc
  end

  defp empty_doc, do: Document.new()

  test "renders rect/rounded/circle nodes" do
    doc =
      empty_doc()
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "a",
          "type" => "rect",
          "x" => 0,
          "y" => 0,
          "w" => 60,
          "h" => 40,
          "label" => "Rect"
        }
      })
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "b",
          "type" => "rounded",
          "x" => 0,
          "y" => 0,
          "w" => 60,
          "h" => 40,
          "label" => "Rounded"
        }
      })
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "c",
          "type" => "circle",
          "cx" => 0,
          "cy" => 0,
          "r" => 30,
          "label" => "Circle"
        }
      })

    out = MermaidExport.to_mermaid(doc)
    assert out =~ "flowchart LR"
    assert out =~ "[\"Rect\"]"
    assert out =~ "(\"Rounded\")"
    assert out =~ "((\"Circle\"))"
  end

  test "renders connector arrows including dashed and unarrowed" do
    doc =
      empty_doc()
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "a",
          "type" => "rect",
          "x" => 0,
          "y" => 0,
          "w" => 60,
          "h" => 40,
          "label" => "A"
        }
      })
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "b",
          "type" => "rect",
          "x" => 200,
          "y" => 0,
          "w" => 60,
          "h" => 40,
          "label" => "B"
        }
      })
      |> insert!(%{
        "type" => "insert_connector",
        "connector" => %{
          "id" => "k1",
          "from" => %{"element" => "a", "anchor" => "auto"},
          "to" => %{"element" => "b", "anchor" => "auto"},
          "label" => "step"
        }
      })
      |> insert!(%{
        "type" => "insert_connector",
        "connector" => %{
          "id" => "k2",
          "from" => %{"element" => "b", "anchor" => "auto"},
          "to" => %{"element" => "a", "anchor" => "auto"},
          "dash" => "dashed",
          "marker_end" => "none"
        }
      })

    out = MermaidExport.to_mermaid(doc)
    # First edge: solid + arrow + label
    assert out =~ "-->|step|"
    # Second edge: dashed + no arrow
    assert out =~ "-.-"
  end

  test "skips connectors with missing endpoints" do
    doc =
      empty_doc()
      |> insert!(%{
        "type" => "insert_element",
        "element" => %{
          "id" => "a",
          "type" => "rect",
          "x" => 0,
          "y" => 0,
          "w" => 10,
          "h" => 10
        }
      })

    # Manually corrupt the document to simulate a stale connector
    bad_doc =
      put_in(doc, ["connectors", "ghost"], %{
        "id" => "ghost",
        "from" => %{"element" => "ghost-from"},
        "to" => %{"element" => "ghost-to"},
        "marker_end" => "arrow",
        "dash" => "solid",
        "label" => ""
      })

    out = MermaidExport.to_mermaid(bad_doc)
    refute out =~ "ghost-from"
  end
end

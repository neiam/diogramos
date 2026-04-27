defmodule Diogramos.Diagrams.Document do
  @moduledoc """
  Pure functions for applying ops to a canvas document.

  The document is a plain map persisted as jsonb on `canvases.document`:

      %{
        "elements" => %{element_id => element_map},
        "order"    => [element_id, ...],   # paint order, back-to-front
        "connectors" => %{connector_id => connector_map}
      }

  Element types: "rect", "rounded", "circle", "text".
  Connector routing: "straight", "orthogonal", "curve".

  All ops are total — they validate input, apply atomically, and return
  either `{:ok, new_document}` or `{:error, reason}`. The live op pipeline
  is responsible for sequencing ops; this module is concurrency-unaware.
  """

  @element_types ~w(rect rounded circle text)
  @connector_routings ~w(straight orthogonal curve)
  @anchors ~w(auto n e s w)
  @dash_presets ~w(solid dotted dashed dash-dot)
  @end_markers ~w(none arrow filled-arrow diamond circle)

  @type id :: String.t()
  @type document :: map()
  @type op :: map()

  @spec new() :: document()
  def new do
    %{"elements" => %{}, "order" => [], "connectors" => %{}}
  end

  @doc """
  Applies an op to a document. Ops are maps with a `"type"` field.

  Supported ops:

    * `%{"type" => "insert_element", "element" => element}`
    * `%{"type" => "update_element", "id" => id, "patch" => patch}`
    * `%{"type" => "delete_element", "id" => id}`
    * `%{"type" => "insert_connector", "connector" => connector}`
    * `%{"type" => "update_connector", "id" => id, "patch" => patch}`
    * `%{"type" => "delete_connector", "id" => id}`
    * `%{"type" => "set_z_order", "order" => [id, id, ...]}`
  """
  @spec apply_op(document(), op()) :: {:ok, document()} | {:error, atom()}
  def apply_op(doc, %{"type" => "insert_element", "element" => element}) do
    with {:ok, normalized} <- validate_element(element),
         id = normalized["id"],
         false <- Map.has_key?(doc["elements"], id) do
      {:ok,
       doc
       |> put_in(["elements", id], normalized)
       |> Map.update!("order", &(&1 ++ [id]))}
    else
      true -> {:error, :duplicate_id}
      {:error, _} = err -> err
    end
  end

  def apply_op(doc, %{"type" => "update_element", "id" => id, "patch" => patch}) do
    case doc["elements"][id] do
      nil ->
        {:error, :not_found}

      element ->
        with {:ok, merged} <- merge_element(element, patch) do
          {:ok, put_in(doc, ["elements", id], merged)}
        end
    end
  end

  def apply_op(doc, %{"type" => "delete_element", "id" => id}) do
    case doc["elements"][id] do
      nil ->
        {:error, :not_found}

      _ ->
        connectors = drop_connectors_referencing(doc["connectors"], id)

        {:ok,
         doc
         |> Map.update!("elements", &Map.delete(&1, id))
         |> Map.update!("order", &Enum.reject(&1, fn x -> x == id end))
         |> Map.put("connectors", connectors)}
    end
  end

  def apply_op(doc, %{"type" => "insert_connector", "connector" => connector}) do
    with {:ok, normalized} <- validate_connector(connector, doc),
         id = normalized["id"],
         false <- Map.has_key?(doc["connectors"], id) do
      {:ok, put_in(doc, ["connectors", id], normalized)}
    else
      true -> {:error, :duplicate_id}
      {:error, _} = err -> err
    end
  end

  def apply_op(doc, %{"type" => "update_connector", "id" => id, "patch" => patch}) do
    case doc["connectors"][id] do
      nil ->
        {:error, :not_found}

      connector ->
        with {:ok, merged} <- merge_connector(connector, patch, doc) do
          {:ok, put_in(doc, ["connectors", id], merged)}
        end
    end
  end

  def apply_op(doc, %{"type" => "delete_connector", "id" => id}) do
    case doc["connectors"][id] do
      nil -> {:error, :not_found}
      _ -> {:ok, Map.update!(doc, "connectors", &Map.delete(&1, id))}
    end
  end

  def apply_op(doc, %{"type" => "set_z_order", "order" => order}) when is_list(order) do
    existing = Map.keys(doc["elements"]) |> MapSet.new()
    proposed = MapSet.new(order)

    cond do
      not MapSet.equal?(existing, proposed) -> {:error, :order_mismatch}
      length(order) != map_size(doc["elements"]) -> {:error, :order_mismatch}
      true -> {:ok, %{doc | "order" => order}}
    end
  end

  def apply_op(_doc, _), do: {:error, :unknown_op}

  ## Element validation -----------------------------------------------------

  defp validate_element(%{"id" => id, "type" => type} = element)
       when is_binary(id) and type in @element_types do
    with {:ok, e} <- do_validate_element(type, element),
         :ok <- validate_style(Map.get(e, "style", %{})),
         :ok <- validate_links(Map.get(e, "links")) do
      {:ok, with_defaults(e)}
    end
  end

  defp validate_element(_), do: {:error, :invalid_element}

  @font_families ~w(sans serif mono b612 b612-mono)
  @label_positions ~w(tl tc tr ml center mr bl bc br)
  @label_sizes ~w(sm md lg xl)

  @doc "Whitelist of shape label positions (corners / sides / center)."
  def label_positions, do: @label_positions

  @doc "Whitelist of shape label size presets."
  def label_sizes, do: @label_sizes

  defp validate_style(%{} = style) do
    fill = Map.get(style, "fill")
    stroke = Map.get(style, "stroke")
    shadow = Map.get(style, "shadow")
    font_family = Map.get(style, "font_family")
    font_size = Map.get(style, "font_size")
    font_bold = Map.get(style, "font_bold")
    font_italic = Map.get(style, "font_italic")

    dash = Map.get(style, "dash")
    stroke_width = Map.get(style, "stroke_width")

    label_position = Map.get(style, "label_position")
    label_size = Map.get(style, "label_size")
    label_color = Map.get(style, "label_color")
    label_font_family = Map.get(style, "label_font_family")
    label_bold = Map.get(style, "label_bold")
    label_italic = Map.get(style, "label_italic")

    cond do
      not is_nil(fill) and not Diogramos.Themes.valid_color?(fill) ->
        {:error, :invalid_color}

      not is_nil(stroke) and not Diogramos.Themes.valid_color?(stroke) ->
        {:error, :invalid_color}

      not is_nil(shadow) and not is_boolean(shadow) ->
        {:error, :invalid_shadow}

      not is_nil(dash) and dash not in @dash_presets ->
        {:error, :invalid_dash}

      not is_nil(stroke_width) and (not is_number(stroke_width) or stroke_width <= 0) ->
        {:error, :invalid_stroke_width}

      not is_nil(label_position) and label_position not in @label_positions ->
        {:error, :invalid_label_position}

      not is_nil(label_size) and label_size not in @label_sizes ->
        {:error, :invalid_label_size}

      not is_nil(label_color) and not Diogramos.Themes.valid_color?(label_color) ->
        {:error, :invalid_label_color}

      not is_nil(label_font_family) and label_font_family not in @font_families ->
        {:error, :invalid_label_font_family}

      not is_nil(label_bold) and not is_boolean(label_bold) ->
        {:error, :invalid_label_style}

      not is_nil(label_italic) and not is_boolean(label_italic) ->
        {:error, :invalid_label_style}

      not is_nil(font_family) and font_family not in @font_families ->
        {:error, :invalid_font_family}

      not is_nil(font_size) and (not is_number(font_size) or font_size < 4 or font_size > 256) ->
        {:error, :invalid_font_size}

      not is_nil(font_bold) and not is_boolean(font_bold) ->
        {:error, :invalid_font_style}

      not is_nil(font_italic) and not is_boolean(font_italic) ->
        {:error, :invalid_font_style}

      true ->
        :ok
    end
  end

  defp validate_style(_), do: :ok

  @doc "Whitelist of font-family tokens accepted on text elements."
  def font_families, do: @font_families

  @link_kinds ~w(external canvas)
  @link_icons ~w(link arrow-top-right-on-square document-text bookmark globe-alt information-circle)

  @doc "Whitelist of metadata-link kinds."
  def link_kinds, do: @link_kinds

  @doc "Whitelist of metadata-link icon ids."
  def link_icons, do: @link_icons

  defp validate_link(nil), do: :ok

  defp validate_link(%{} = link) do
    enabled = Map.get(link, "enabled", false)
    kind = Map.get(link, "kind", "external")
    target = Map.get(link, "target", "")
    icon = Map.get(link, "icon", "link")

    cond do
      not is_boolean(enabled) ->
        {:error, :invalid_link_enabled}

      kind not in @link_kinds ->
        {:error, :invalid_link_kind}

      not is_binary(target) ->
        {:error, :invalid_link_target}

      String.length(target) > 2048 ->
        {:error, :invalid_link_target}

      icon not in @link_icons ->
        {:error, :invalid_link_icon}

      enabled and target == "" ->
        {:error, :invalid_link_target}

      true ->
        :ok
    end
  end

  defp validate_link(_), do: {:error, :invalid_link}

  defp validate_links(nil), do: :ok

  defp validate_links(list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn link, _acc ->
      case validate_link(link) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp validate_links(_), do: {:error, :invalid_links}

  defp do_validate_element("circle", %{"cx" => cx, "cy" => cy, "r" => r} = e)
       when is_number(cx) and is_number(cy) and is_number(r) and r > 0,
       do: {:ok, e}

  defp do_validate_element(t, %{"x" => x, "y" => y, "w" => w, "h" => h} = e)
       when t in ["rect", "rounded", "text"] and
              is_number(x) and is_number(y) and is_number(w) and is_number(h) and
              w > 0 and h > 0,
       do: {:ok, e}

  defp do_validate_element(_, _), do: {:error, :invalid_element_geometry}

  defp with_defaults(element) do
    Map.merge(
      %{
        "label" => "",
        "style" => %{}
      },
      element
    )
  end

  defp merge_element(element, patch) when is_map(patch) do
    cond do
      Map.has_key?(patch, "id") and patch["id"] != element["id"] ->
        {:error, :id_immutable}

      Map.has_key?(patch, "type") and patch["type"] != element["type"] ->
        {:error, :type_immutable}

      true ->
        merged = deep_merge(element, patch)

        # Re-validate geometry + style after the patch so half-baked
        # updates (e.g. negative w, unknown color token) get rejected.
        with {:ok, e} <- do_validate_element(merged["type"], merged),
             :ok <- validate_style(Map.get(e, "style", %{})) do
          {:ok, e}
        end
    end
  end

  ## Connector validation ---------------------------------------------------

  defp validate_connector(
         %{
           "id" => id,
           "from" => %{"element" => from_id} = from_anchor,
           "to" => %{"element" => to_id} = to_anchor
         } = connector,
         doc
       )
       when is_binary(id) and is_binary(from_id) and is_binary(to_id) do
    with :ok <- ensure_element(doc, from_id),
         :ok <- ensure_element(doc, to_id),
         :ok <- valid_anchor?(from_anchor),
         :ok <- valid_anchor?(to_anchor),
         {:ok, style} <- validate_connector_style(connector) do
      {:ok,
       connector
       |> Map.merge(style)
       |> Map.put_new("label", "")}
    end
  end

  defp validate_connector(_, _), do: {:error, :invalid_connector}

  defp ensure_element(doc, id) do
    if Map.has_key?(doc["elements"], id), do: :ok, else: {:error, :missing_endpoint}
  end

  defp valid_anchor?(%{"anchor" => a}) when a in @anchors, do: :ok

  defp valid_anchor?(%{"anchor" => "point", "x" => x, "y" => y})
       when is_number(x) and is_number(y), do: :ok

  defp valid_anchor?(%{}), do: :ok
  defp valid_anchor?(_), do: {:error, :invalid_anchor}

  defp validate_connector_style(connector) do
    routing = Map.get(connector, "routing", "orthogonal")
    dash = Map.get(connector, "dash", "solid")
    marker_start = Map.get(connector, "marker_start", "none")
    marker_end = Map.get(connector, "marker_end", "arrow")
    start_gap = Map.get(connector, "start_gap", 6)
    end_gap = Map.get(connector, "end_gap", 6)
    stroke_width = Map.get(connector, "stroke_width", 2)
    color = Map.get(connector, "color", "base-content")

    cond do
      routing not in @connector_routings ->
        {:error, :invalid_routing}

      dash not in @dash_presets ->
        {:error, :invalid_dash}

      not Diogramos.Themes.valid_color?(color) ->
        {:error, :invalid_color}

      marker_start not in @end_markers ->
        {:error, :invalid_marker}

      marker_end not in @end_markers ->
        {:error, :invalid_marker}

      not is_number(start_gap) or start_gap < 0 ->
        {:error, :invalid_gap}

      not is_number(end_gap) or end_gap < 0 ->
        {:error, :invalid_gap}

      not is_number(stroke_width) or stroke_width <= 0 ->
        {:error, :invalid_stroke_width}

      true ->
        {:ok,
         %{
           "routing" => routing,
           "dash" => dash,
           "marker_start" => marker_start,
           "marker_end" => marker_end,
           "start_gap" => start_gap,
           "end_gap" => end_gap,
           "stroke_width" => stroke_width,
           "color" => color
         }}
    end
  end

  defp merge_connector(connector, patch, doc) when is_map(patch) do
    cond do
      Map.has_key?(patch, "id") and patch["id"] != connector["id"] ->
        {:error, :id_immutable}

      true ->
        merged = deep_merge(connector, patch)
        validate_connector(merged, doc)
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, lv, rv ->
      if is_map(lv) and is_map(rv), do: deep_merge(lv, rv), else: rv
    end)
  end

  defp drop_connectors_referencing(connectors, element_id) do
    Enum.reject(connectors, fn {_id, c} ->
      c["from"]["element"] == element_id or c["to"]["element"] == element_id
    end)
    |> Map.new()
  end
end

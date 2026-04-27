defmodule DiogramosWeb.CanvasLive.Edit do
  use DiogramosWeb, :live_view

  alias Diogramos.Diagrams
  alias Diogramos.Diagrams.{Authority, ConnectorGeometry, Document, MermaidExport}
  alias DiogramosWeb.CanvasPresence

  @tools ~w(select text rect rounded circle connector)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    scope = socket.assigns.current_scope

    case Diagrams.get_canvas_by_slug(scope, slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Canvas not found.")
         |> push_navigate(to: ~p"/canvases")}

      canvas ->
        role = Diagrams.effective_role(scope, canvas)

        {document, version} =
          case Authority.snapshot(canvas.id) do
            {:ok, %{document: d, version: v}} -> {d, v}
            _ -> {ensure_document_shape(canvas.document), canvas.version}
          end

        topic = Authority.topic(canvas.id)
        identity = presence_identity(scope)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Diogramos.PubSub, topic)
          CanvasPresence.track(self(), topic, identity)
        end

        actor_ref = "lv-#{System.unique_integer([:positive])}"

        {:ok,
         socket
         |> assign(:page_title, canvas.title)
         |> assign(:canvas, %{canvas | document: document, version: version})
         |> assign(:role, role)
         |> assign(:read_only, role == "viewer")
         |> assign(:document, document)
         |> assign(:version, version)
         |> assign(:tool, "select")
         |> assign(:selection, [])
         |> assign(:selection_clipboard, nil)
         |> assign(:actor_ref, actor_ref)
         |> assign(:show_mermaid, false)
         |> assign(:mermaid_source, "")
         |> assign(:topic, topic)
         |> assign(:presence_key, identity.key)
         |> assign(:peers, [])
         |> assign(:locked_elements, MapSet.new())
         |> assign(:style_clipboard, nil)
         |> assign(:snap_grid, false)
         |> assign(:grid_size, 20)
         |> assign(:show_embed_cursors, true)}
    end
  end

  defp presence_identity(%{user: %{id: id, email: email, display_name: display_name}}) do
    %{
      key: "user-#{id}",
      name: display_name || (email && hd(String.split(email, "@"))) || "Guest #{id}"
    }
  end

  defp presence_identity(_) do
    %{key: "anon-#{System.unique_integer([:positive])}", name: "Guest"}
  end

  @impl true
  def handle_info({:canvas_op, %{op: op, version: version, actor_ref: ref}}, socket) do
    cond do
      ref == socket.assigns.actor_ref ->
        {:noreply, socket}

      version <= socket.assigns.version ->
        {:noreply, socket}

      true ->
        case Document.apply_op(socket.assigns.document, op) do
          {:ok, doc} -> {:noreply, assign(socket, document: doc, version: version)}
          {:error, _} -> {:noreply, socket}
        end
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, refresh_peers(socket)}
  end

  @impl true
  def handle_event("select_tool", %{"tool" => tool}, socket) when tool in @tools do
    {:noreply, assign(socket, tool: tool, selection: [])}
  end

  def handle_event("select_element", params, socket) do
    {:noreply, do_select(socket, {:element, params["id"]}, params["multi"] == true)}
  end

  def handle_event("select_connector", params, socket) do
    {:noreply, do_select(socket, {:connector, params["id"]}, params["multi"] == true)}
  end

  def handle_event("select_set", params, socket) do
    elements = for id <- params["elements"] || [], is_binary(id), do: {:element, id}
    connectors = for id <- params["connectors"] || [], is_binary(id), do: {:connector, id}
    {:noreply, assign(socket, :selection, elements ++ connectors)}
  end

  def handle_event("clear_selection", _, socket) do
    {:noreply, assign(socket, :selection, [])}
  end

  def handle_event("apply_op", _params, %{assigns: %{read_only: true}} = socket) do
    {:noreply, put_flash(socket, :error, "You only have view access to this canvas.")}
  end

  def handle_event("apply_op", %{"op" => op}, socket) do
    apply_op_and_persist(socket, apply_clipboard_defaults(op, socket.assigns.style_clipboard))
  end

  def handle_event("update_selected", %{"props" => props}, socket) do
    case selection_focus(socket.assigns.selection) do
      {:element, id} ->
        patch = coerce_element_patch(props, socket.assigns.document["elements"][id])
        apply_op_and_persist(socket, %{"type" => "update_element", "id" => id, "patch" => patch})

      {:connector, id} ->
        patch = coerce_connector_patch(props)

        apply_op_and_persist(socket, %{"type" => "update_connector", "id" => id, "patch" => patch})

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_mermaid", _, socket) do
    source = MermaidExport.to_mermaid(socket.assigns.document)
    {:noreply, assign(socket, show_mermaid: true, mermaid_source: source)}
  end

  def handle_event("close_mermaid", _, socket) do
    {:noreply, assign(socket, :show_mermaid, false)}
  end

  def handle_event("toggle_grid", _, socket) do
    socket = update(socket, :snap_grid, &(!&1))
    {:noreply, push_event(socket, "grid_changed", %{on: socket.assigns.snap_grid})}
  end

  def handle_event("toggle_embed_cursors", _, socket) do
    {:noreply, socket |> update(:show_embed_cursors, &(!&1)) |> refresh_peers()}
  end

  def handle_event("set_grid", %{"on" => on}, socket) when is_boolean(on) do
    {:noreply, assign(socket, :snap_grid, on)}
  end

  def handle_event("z_order", %{"action" => action}, socket)
      when action in ~w(to_back backward forward to_front) do
    case selection_focus(socket.assigns.selection) do
      {:element, id} ->
        new_order = reorder(socket.assigns.document["order"], id, action)

        if new_order == socket.assigns.document["order"] do
          {:noreply, socket}
        else
          apply_op_and_persist(socket, %{"type" => "set_z_order", "order" => new_order})
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cursor", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    CanvasPresence.update(self(), socket.assigns.topic, socket.assigns.presence_key, fn meta ->
      Map.put(meta, :cursor, %{x: x, y: y})
    end)

    {:noreply, socket}
  end

  def handle_event("cursor", _, socket), do: {:noreply, socket}

  def handle_event("set_lock", %{"id" => id}, socket) when is_binary(id) do
    CanvasPresence.update(self(), socket.assigns.topic, socket.assigns.presence_key, fn meta ->
      Map.put(meta, :lock, id)
    end)

    {:noreply, socket}
  end

  def handle_event("clear_lock", _, socket) do
    CanvasPresence.update(self(), socket.assigns.topic, socket.assigns.presence_key, fn meta ->
      Map.put(meta, :lock, nil)
    end)

    {:noreply, socket}
  end

  def handle_event("copy_style", _, socket) do
    clipboard =
      case selection_focus(socket.assigns.selection) do
        {:element, id} ->
          case socket.assigns.document["elements"][id] do
            nil -> nil
            element -> {:element, Map.get(element, "style", %{})}
          end

        {:connector, id} ->
          case socket.assigns.document["connectors"][id] do
            nil ->
              nil

            connector ->
              {:connector,
               Map.take(
                 connector,
                 ~w(routing dash marker_start marker_end start_gap end_gap stroke_width color)
               )}
          end

        _ ->
          nil
      end

    {:noreply, assign(socket, :style_clipboard, clipboard)}
  end

  def handle_event("paste_style", _, socket) do
    case {selection_focus(socket.assigns.selection), socket.assigns.style_clipboard} do
      {{:element, id}, {:element, style}} when map_size(style) > 0 ->
        apply_op_and_persist(socket, %{
          "type" => "update_element",
          "id" => id,
          "patch" => %{"style" => style}
        })

      {{:connector, id}, {:connector, style}} when map_size(style) > 0 ->
        apply_op_and_persist(socket, %{
          "type" => "update_connector",
          "id" => id,
          "patch" => style
        })

      _ ->
        {:noreply, put_flash(socket, :info, "Nothing matching to paste.")}
    end
  end

  def handle_event("copy_selection", _, socket) do
    el_ids = selection_element_ids(socket.assigns.selection)
    con_ids = selection_connector_ids(socket.assigns.selection)
    document = socket.assigns.document

    elements = el_ids |> Enum.map(&document["elements"][&1]) |> Enum.reject(&is_nil/1)
    el_set = MapSet.new(el_ids)

    connectors =
      con_ids
      |> Enum.map(&document["connectors"][&1])
      |> Enum.reject(&is_nil/1)
      # Also include any connector both of whose endpoints were selected,
      # even if the lasso didn't hit the connector itself.
      |> Kernel.++(
        Enum.filter(Map.values(document["connectors"]), fn c ->
          c["from"]["element"] in el_set and c["to"]["element"] in el_set and
            c["id"] not in con_ids
        end)
      )
      |> Enum.uniq_by(& &1["id"])

    if elements == [] and connectors == [] do
      {:noreply, put_flash(socket, :info, "Nothing selected to copy.")}
    else
      {:noreply,
       assign(socket, :selection_clipboard, %{elements: elements, connectors: connectors})}
    end
  end

  def handle_event("paste_selection", _, %{assigns: %{read_only: true}} = socket) do
    {:noreply, put_flash(socket, :error, "You only have view access to this canvas.")}
  end

  def handle_event("paste_selection", _, socket) do
    case socket.assigns.selection_clipboard do
      nil ->
        {:noreply, put_flash(socket, :info, "Selection clipboard is empty.")}

      %{elements: [], connectors: []} ->
        {:noreply, put_flash(socket, :info, "Selection clipboard is empty.")}

      %{elements: elements, connectors: connectors} ->
        paste_offset = 24
        id_map = Map.new(elements, fn e -> {e["id"], Diogramos.ULID.generate()} end)

        new_elements = Enum.map(elements, &offset_and_remint(&1, id_map, paste_offset))
        new_connectors = Enum.map(connectors, &remap_connector(&1, id_map))

        socket =
          new_elements
          |> Enum.reduce(socket, fn element, socket ->
            {_, s} =
              apply_op_and_persist(socket, %{
                "type" => "insert_element",
                "element" => element
              })

            s
          end)

        socket =
          new_connectors
          |> Enum.reduce(socket, fn connector, socket ->
            {_, s} =
              apply_op_and_persist(socket, %{
                "type" => "insert_connector",
                "connector" => connector
              })

            s
          end)

        # Re-select the freshly pasted shapes so the user can keep moving them.
        new_selection =
          Enum.map(new_elements, &{:element, &1["id"]}) ++
            Enum.map(new_connectors, &{:connector, &1["id"]})

        {:noreply, assign(socket, :selection, new_selection)}
    end
  end

  def handle_event("toggle_embed", _, socket) do
    canvas = socket.assigns.canvas

    result =
      if canvas.embed_token do
        Diagrams.set_canvas_embed_token(socket.assigns.current_scope, canvas, nil)
      else
        Diagrams.generate_canvas_embed_token(socket.assigns.current_scope, canvas)
      end

    case result do
      {:ok, updated} ->
        {:noreply, assign(socket, :canvas, updated)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only owners can manage the embed token.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update embed.")}
    end
  end

  def handle_event("add_link", %{"element_id" => id}, socket) do
    case socket.assigns.document["elements"][id] do
      nil ->
        {:noreply, socket}

      element ->
        existing = element["links"] || []

        new_link = %{
          "enabled" => true,
          "kind" => "external",
          "target" => "",
          "icon" => "link"
        }

        apply_op_and_persist(socket, %{
          "type" => "update_element",
          "id" => id,
          "patch" => %{"links" => existing ++ [new_link]}
        })
    end
  end

  def handle_event("remove_link", %{"element_id" => id, "index" => idx}, socket) do
    case socket.assigns.document["elements"][id] do
      nil ->
        {:noreply, socket}

      element ->
        existing = element["links"] || []
        idx = String.to_integer(idx)
        updated = List.delete_at(existing, idx)

        apply_op_and_persist(socket, %{
          "type" => "update_element",
          "id" => id,
          "patch" => %{"links" => updated}
        })
    end
  end

  def handle_event("delete_selected", _, socket) do
    selection = socket.assigns.selection

    if selection == [] do
      {:noreply, socket}
    else
      socket = assign(socket, :selection, [])

      socket =
        Enum.reduce(selection, socket, fn
          {:element, id}, socket ->
            {_, s} = apply_op_and_persist(socket, %{"type" => "delete_element", "id" => id})
            s

          {:connector, id}, socket ->
            {_, s} = apply_op_and_persist(socket, %{"type" => "delete_connector", "id" => id})
            s
        end)

      {:noreply, socket}
    end
  end

  defp apply_op_and_persist(%{assigns: %{read_only: true}} = socket, _op) do
    {:noreply, put_flash(socket, :error, "You only have view access to this canvas.")}
  end

  defp apply_op_and_persist(socket, op) do
    case Authority.apply_op(
           socket.assigns.canvas.id,
           socket.assigns.current_scope,
           op,
           socket.assigns.actor_ref
         ) do
      {:ok, %{document: doc, version: version}} ->
        {:noreply, assign(socket, document: doc, version: version)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You don't have permission to edit this canvas.")}

      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, "Op rejected: #{reason}")}
    end
  end

  defp apply_clipboard_defaults(
         %{"type" => "insert_element", "element" => element} = op,
         {:element, %{} = style}
       )
       when map_size(style) > 0 do
    existing = Map.get(element, "style", %{})
    %{op | "element" => Map.put(element, "style", Map.merge(style, existing))}
  end

  defp apply_clipboard_defaults(
         %{"type" => "insert_connector", "connector" => connector} = op,
         {:connector, %{} = style}
       )
       when map_size(style) > 0 do
    %{op | "connector" => Map.merge(connector, style)}
  end

  defp apply_clipboard_defaults(op, _), do: op

  defp do_select(socket, item, true) do
    selection = socket.assigns.selection

    selection =
      if item in selection,
        do: List.delete(selection, item),
        else: selection ++ [item]

    assign(socket, :selection, selection)
  end

  defp do_select(socket, item, _multi), do: assign(socket, :selection, [item])

  defp reorder(order, id, action) do
    case Enum.find_index(order, &(&1 == id)) do
      nil -> order
      idx -> do_reorder(order, idx, action)
    end
  end

  defp do_reorder(order, idx, "to_back") do
    {value, rest} = List.pop_at(order, idx)
    [value | rest]
  end

  defp do_reorder(order, idx, "to_front") do
    {value, rest} = List.pop_at(order, idx)
    rest ++ [value]
  end

  defp do_reorder(order, idx, "backward") when idx > 0 do
    a = Enum.at(order, idx)
    b = Enum.at(order, idx - 1)
    order |> List.replace_at(idx, b) |> List.replace_at(idx - 1, a)
  end

  defp do_reorder(order, idx, "forward") when idx < length(order) - 1 do
    a = Enum.at(order, idx)
    b = Enum.at(order, idx + 1)
    order |> List.replace_at(idx, b) |> List.replace_at(idx + 1, a)
  end

  defp do_reorder(order, _, _), do: order

  defp refresh_peers(socket) do
    exclude = if socket.assigns.show_embed_cursors, do: [], else: ["embed"]

    peers =
      CanvasPresence.list_peers(socket.assigns.topic, socket.assigns.presence_key,
        exclude_sources: exclude
      )

    locked = CanvasPresence.locked_elements(socket.assigns.topic, socket.assigns.presence_key)
    assign(socket, peers: peers, locked_elements: locked)
  end

  ## Form coercion ----------------------------------------------------------

  @element_numeric_keys ~w(x y w h cx cy r)
  @connector_numeric_keys ~w(start_gap end_gap stroke_width)
  @style_color_keys ~w(fill stroke label_color)
  @style_select_keys ~w(font_family dash label_position label_size label_font_family)
  @style_number_keys ~w(font_size stroke_width)
  @style_bool_keys ~w(shadow font_bold font_italic label_bold label_italic)

  defp coerce_element_patch(props, _existing) when is_map(props) do
    base =
      props
      |> Map.take(["label" | @element_numeric_keys])
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        cond do
          k == "label" -> Map.put(acc, k, v || "")
          v in [nil, ""] -> acc
          true -> Map.put(acc, k, parse_number(v))
        end
      end)

    style =
      %{}
      |> merge_string_styles(props, @style_color_keys ++ @style_select_keys)
      |> merge_number_styles(props, @style_number_keys)
      |> merge_bool_styles(props, @style_bool_keys)

    base = if map_size(style) > 0, do: Map.put(base, "style", style), else: base

    case Map.get(props, "links") do
      %{} = links_params ->
        Map.put(base, "links", coerce_links_patch(links_params))

      [_ | _] = list when is_list(list) ->
        Map.put(base, "links", Enum.map(list, &coerce_link_patch/1))

      _ ->
        base
    end
  end

  defp coerce_links_patch(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> integer_or_zero(k) end)
    |> Enum.map(fn {_, link_params} -> coerce_link_patch(link_params) end)
  end

  defp integer_or_zero(k) when is_binary(k) do
    case Integer.parse(k) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp integer_or_zero(k) when is_integer(k), do: k
  defp integer_or_zero(_), do: 0

  defp coerce_link_patch(link_params) when is_map(link_params) do
    Map.take(link_params, ~w(enabled kind target icon))
    |> Enum.reduce(%{}, fn
      {"enabled", v}, acc -> Map.put(acc, "enabled", parse_bool(v))
      {k, v}, acc -> Map.put(acc, k, v)
    end)
    |> Map.put_new("enabled", false)
    |> Map.put_new("kind", "external")
    |> Map.put_new("target", "")
    |> Map.put_new("icon", "link")
  end

  defp merge_string_styles(acc, props, keys) do
    Enum.reduce(keys, acc, fn key, acc ->
      case Map.get(props, key) do
        v when v in [nil, ""] -> acc
        v -> Map.put(acc, key, v)
      end
    end)
  end

  defp merge_number_styles(acc, props, keys) do
    Enum.reduce(keys, acc, fn key, acc ->
      case Map.get(props, key) do
        v when v in [nil, ""] -> acc
        v -> Map.put(acc, key, parse_number(v))
      end
    end)
  end

  defp merge_bool_styles(acc, props, keys) do
    Enum.reduce(keys, acc, fn key, acc ->
      case Map.fetch(props, key) do
        :error -> acc
        {:ok, v} -> Map.put(acc, key, parse_bool(v))
      end
    end)
  end

  defp parse_bool(true), do: true
  defp parse_bool("true"), do: true
  defp parse_bool("on"), do: true
  defp parse_bool(_), do: false

  defp coerce_connector_patch(props) when is_map(props) do
    base = Map.take(props, ["label", "routing", "dash", "marker_start", "marker_end", "color"])

    numeric =
      props
      |> Map.take(@connector_numeric_keys)
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
      |> Map.new(fn {k, v} -> {k, parse_number(v)} end)

    Map.merge(base, numeric)
  end

  defp parse_number(n) when is_number(n), do: n

  defp parse_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> if f == trunc(f), do: trunc(f), else: f
      _ -> 0
    end
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp ensure_document_shape(nil), do: Document.new()

  defp ensure_document_shape(%{"elements" => _, "order" => _, "connectors" => _} = doc), do: doc

  defp ensure_document_shape(other) when is_map(other) do
    %{
      "elements" => other["elements"] || %{},
      "order" => other["order"] || [],
      "connectors" => other["connectors"] || %{}
    }
  end

  defp connector_render_data(connectors, document) do
    connectors
    |> Enum.map(fn {id, connector} ->
      {id, connector, ConnectorGeometry.render(connector, document)}
    end)
    |> Enum.reject(fn {_id, _c, rendered} -> is_nil(rendered) end)
  end

  defp marker_id("none"), do: ""
  defp marker_id(name), do: "url(#dx-marker-#{name})"

  defp element_data_attrs(%{"type" => "circle"} = e),
    do: %{"data-cx" => e["cx"], "data-cy" => e["cy"], "data-r" => e["r"]}

  defp element_data_attrs(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: %{"data-x" => x, "data-y" => y, "data-w" => w, "data-h" => h}

  defp selection_focus([{:element, id}]), do: {:element, id}
  defp selection_focus([{:connector, id}]), do: {:connector, id}
  defp selection_focus(_), do: nil

  defp selection_element_ids(selection),
    do: for({:element, id} <- selection, do: id)

  defp selection_connector_ids(selection),
    do: for({:connector, id} <- selection, do: id)

  defp selection_includes_element?(selection, id), do: {:element, id} in selection
  defp selection_includes_connector?(selection, id), do: {:connector, id} in selection

  # Compatibility helpers used in the SVG render loop and the resize handle.
  defp selected_element_id(selection) do
    case selection_focus(selection) do
      {:element, id} -> id
      _ -> nil
    end
  end

  defp selected_element(%{"elements" => elements}, selection) do
    case selection_focus(selection) do
      {:element, id} -> elements[id]
      _ -> nil
    end
  end

  defp selected_element(_, _), do: nil

  defp selected_connector(%{"connectors" => connectors}, selection) do
    case selection_focus(selection) do
      {:connector, id} -> connectors[id]
      _ -> nil
    end
  end

  defp selected_connector(_, _), do: nil

  defp offset_and_remint(element, id_map, offset) do
    new_id = Map.fetch!(id_map, element["id"])

    element
    |> Map.put("id", new_id)
    |> shift_geometry(offset)
  end

  defp shift_geometry(%{"type" => "circle"} = e, offset),
    do: %{e | "cx" => e["cx"] + offset, "cy" => e["cy"] + offset}

  defp shift_geometry(e, offset),
    do: %{e | "x" => e["x"] + offset, "y" => e["y"] + offset}

  defp remap_connector(connector, id_map) do
    new_id = Diogramos.ULID.generate()
    from_id = id_map[connector["from"]["element"]] || connector["from"]["element"]
    to_id = id_map[connector["to"]["element"]] || connector["to"]["element"]

    connector
    |> Map.put("id", new_id)
    |> put_in(["from", "element"], from_id)
    |> put_in(["to", "element"], to_id)
  end

  ## ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :rendered_connectors,
        connector_render_data(assigns.document["connectors"], assigns.document)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div
        id="canvas-edit"
        data-theme={@canvas.theme}
        data-canvas-id={@canvas.id}
        data-read-only={to_string(@read_only)}
        class="grid grid-cols-[4rem_1fr_18rem] grid-rows-[3rem_1fr] h-[calc(100vh-4rem)] gap-0 w-full"
      >
        <header class="col-span-3 flex items-center justify-between border-b border-base-300 px-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/canvases"} class="btn btn-ghost btn-xs">
              <.icon name="hero-arrow-left-micro" class="size-4" />
            </.link>
            <span class="font-semibold truncate">{@canvas.title}</span>
            <span class="text-xs font-mono text-accent">{@canvas.slug}</span>
            <%= if @read_only do %>
              <span class="badge badge-warning badge-sm">view only</span>
            <% end %>
          </div>
          <div class="flex items-center gap-2 text-xs">
            <span class="opacity-70">role: {@role || "—"}</span>
            <span class="opacity-70">v{@version}</span>
            <button
              type="button"
              id="btn-toggle-grid"
              phx-click="toggle_grid"
              class={["btn btn-ghost btn-xs", @snap_grid && "text-accent"]}
              title="Snap to grid"
            >
              <.icon name="hero-squares-2x2-micro" class="size-4" />
              {if @snap_grid, do: "Grid on", else: "Grid"}
            </button>
            <button
              type="button"
              id="btn-toggle-embed-cursors"
              phx-click="toggle_embed_cursors"
              class={["btn btn-ghost btn-xs", @show_embed_cursors && "text-accent"]}
              title={
                if @show_embed_cursors,
                  do: "Hide cursors of embed viewers",
                  else: "Show cursors of embed viewers"
              }
            >
              <.icon
                name={if @show_embed_cursors, do: "hero-eye-micro", else: "hero-eye-slash-micro"}
                class="size-4"
              /> Viewers
            </button>
            <a
              id="btn-export-json"
              href={~p"/c/#{@canvas.slug}/export.json"}
              download={"#{@canvas.slug}.json"}
              class="btn btn-ghost btn-xs"
              title="Download canvas as JSON"
            >
              <.icon name="hero-arrow-down-tray-micro" class="size-4" /> JSON
            </a>
            <button
              type="button"
              id="btn-export-mermaid"
              phx-click="show_mermaid"
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-arrow-down-tray-micro" class="size-4" /> Mermaid
            </button>
            <%= if @role == "owner" do %>
              <%= if @canvas.embed_token do %>
                <div class="flex items-center gap-1">
                  <a
                    id="embed-link"
                    href={"/embed/" <> @canvas.embed_token}
                    target="_blank"
                    rel="noopener"
                    class="btn btn-ghost btn-xs text-accent gap-1 font-mono"
                    title="Open embed in a new tab"
                  >
                    <.icon name="hero-link-micro" class="size-4" />
                    /embed/{String.slice(@canvas.embed_token, 0, 6)}…
                  </a>
                  <button
                    type="button"
                    id="btn-toggle-embed"
                    phx-click="toggle_embed"
                    class="btn btn-ghost btn-xs"
                    title="Disable embed"
                  >
                    <.icon name="hero-x-mark-micro" class="size-4" />
                  </button>
                </div>
              <% else %>
                <button
                  type="button"
                  id="btn-toggle-embed"
                  phx-click="toggle_embed"
                  class="btn btn-ghost btn-xs"
                  title="Generate embed link"
                >
                  <.icon name="hero-link-micro" class="size-4" /> Embed
                </button>
              <% end %>
            <% end %>
          </div>
        </header>

        <nav
          class="flex flex-col gap-2 p-2 border-r border-base-300 bg-base-200"
          aria-label="Tools"
        >
          <div
            :for={tool <- ~w(select text rect rounded circle connector)}
            class="tooltip tooltip-right"
            data-tip={tool_label(tool) <> " · " <> tool_shortcut(tool)}
          >
            <button
              type="button"
              id={"tool-#{tool}"}
              class={[
                "btn btn-ghost btn-square btn-md w-full",
                @tool == tool && "btn-active"
              ]}
              phx-click="select_tool"
              phx-value-tool={tool}
              disabled={@read_only}
              aria-label={tool_label(tool)}
            >
              <.icon name={tool_icon(tool)} class="size-6" />
            </button>
          </div>
          <div class="tooltip tooltip-right mt-auto" data-tip="Fit camera to canvas">
            <button
              type="button"
              id="tool-fit-camera"
              phx-click={JS.dispatch("phx:fit-canvas", to: "#canvas-svg")}
              class="btn btn-ghost btn-square btn-md w-full"
              aria-label="Fit camera to canvas"
            >
              <.icon name="hero-arrows-pointing-in" class="size-6" />
            </button>
          </div>
        </nav>

        <main class="relative overflow-hidden bg-base-100">
          <svg
            id="canvas-svg"
            phx-hook=".CanvasViewport"
            data-tool={@tool}
            data-canvas-id={@canvas.id}
            data-selected-id={selected_element_id(@selection) || ""}
            data-has-selection={to_string(@selection != [])}
            data-read-only={to_string(@read_only)}
            data-locked-ids={Enum.join(MapSet.to_list(@locked_elements), ",")}
            data-snap-grid={to_string(@snap_grid)}
            data-grid-size={@grid_size}
            class="absolute inset-0 w-full h-full select-none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <defs>
              <symbol id="dx-link-icon-link" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244"
                />
              </symbol>
              <symbol id="dx-link-icon-arrow-top-right-on-square" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
                />
              </symbol>
              <symbol id="dx-link-icon-document-text" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"
                />
              </symbol>
              <symbol id="dx-link-icon-bookmark" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M17.593 3.322c1.1.128 1.907 1.077 1.907 2.185V21L12 17.25 4.5 21V5.507c0-1.108.806-2.057 1.907-2.185a48.507 48.507 0 0 1 11.186 0Z"
                />
              </symbol>
              <symbol id="dx-link-icon-globe-alt" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M12 21a9.004 9.004 0 0 0 8.716-6.747M12 21a9.004 9.004 0 0 1-8.716-6.747M12 21c2.485 0 4.5-4.03 4.5-9S14.485 3 12 3m0 18c-2.485 0-4.5-4.03-4.5-9S9.515 3 12 3m0 0a8.997 8.997 0 0 1 7.843 4.582M12 3a8.997 8.997 0 0 0-7.843 4.582m15.686 0A11.953 11.953 0 0 1 12 10.5c-2.998 0-5.74-1.1-7.843-2.918m15.686 0A8.959 8.959 0 0 1 21 12c0 .778-.099 1.533-.284 2.253m0 0A17.919 17.919 0 0 1 12 16.5c-3.162 0-6.133-.815-8.716-2.247m0 0A9.015 9.015 0 0 1 3 12c0-1.605.42-3.113 1.157-4.418"
                />
              </symbol>
              <symbol id="dx-link-icon-information-circle" viewBox="0 0 24 24">
                <path
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M11.25 11.25l.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z"
                />
              </symbol>
              <pattern
                id="canvas-grid-pattern"
                x="0"
                y="0"
                width={@grid_size}
                height={@grid_size}
                patternUnits="userSpaceOnUse"
              >
                <circle cx="0.5" cy="0.5" r="0.9" class="fill-base-content opacity-30" />
              </pattern>
              <marker
                id="dx-marker-arrow"
                viewBox="0 0 10 10"
                refX="10"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10" fill="none" stroke="currentColor" stroke-width="1.5" />
              </marker>
              <marker
                id="dx-marker-filled-arrow"
                viewBox="0 0 10 10"
                refX="10"
                refY="5"
                markerWidth="8"
                markerHeight="8"
                orient="auto-start-reverse"
              >
                <path d="M 0 0 L 10 5 L 0 10 Z" fill="currentColor" />
              </marker>
              <marker
                id="dx-marker-diamond"
                viewBox="0 0 10 10"
                refX="10"
                refY="5"
                markerWidth="10"
                markerHeight="10"
                orient="auto-start-reverse"
              >
                <path d="M 0 5 L 5 0 L 10 5 L 5 10 Z" fill="currentColor" />
              </marker>
              <marker
                id="dx-marker-circle"
                viewBox="0 0 10 10"
                refX="10"
                refY="5"
                markerWidth="6"
                markerHeight="6"
                orient="auto"
              >
                <circle cx="5" cy="5" r="3" fill="currentColor" />
              </marker>
            </defs>

            <g id="viewport" class="text-base-content">
              <%= if @snap_grid do %>
                <rect
                  x="-10000"
                  y="-10000"
                  width="20000"
                  height="20000"
                  fill="url(#canvas-grid-pattern)"
                  class="pointer-events-none"
                />
              <% end %>
              <g
                :for={id <- @document["order"]}
                id={"el-" <> id}
                data-element-id={id}
                data-element-type={@document["elements"][id]["type"]}
                {element_data_attrs(@document["elements"][id])}
                class={[
                  "cursor-move",
                  selection_includes_element?(@selection, id) && "outline outline-2 outline-accent",
                  MapSet.member?(@locked_elements, id) && "opacity-40 pointer-events-none"
                ]}
              >
                <.element_node element={@document["elements"][id]} />
                <%= if @tool == "select" and selected_element_id(@selection) == id and not @read_only do %>
                  <.resize_handle element={@document["elements"][id]} element_id={id} />
                <% end %>
              </g>

              <g
                :for={{cid, connector, render} <- @rendered_connectors}
                id={"con-" <> cid}
                data-connector-id={cid}
                class={[
                  "text-base-content cursor-pointer",
                  selection_includes_connector?(@selection, cid) && "text-accent"
                ]}
              >
                <path
                  d={render.d}
                  fill="none"
                  stroke="transparent"
                  stroke-width="14"
                  class="pointer-events-auto"
                />
                <path
                  d={render.d}
                  fill="none"
                  style={"stroke: #{token_var(connector["color"] || "base-content")}; color: #{token_var(connector["color"] || "base-content")};"}
                  stroke-width={render.stroke_width}
                  stroke-dasharray={render.dash_array}
                  marker-start={marker_id(render.marker_start)}
                  marker-end={marker_id(render.marker_end)}
                  class="pointer-events-none"
                />
                <%= if connector["label"] != "" do %>
                  <text class="text-xs fill-base-content opacity-80 pointer-events-none">
                    {connector["label"]}
                  </text>
                <% end %>
              </g>

              <g id="canvas-preview" class="pointer-events-none text-accent" />

              <g id="canvas-cursors" class="pointer-events-none">
                <g
                  :for={peer <- @peers}
                  :if={peer.cursor}
                  id={"cur-" <> peer.key}
                  transform={"translate(#{peer.cursor.x} #{peer.cursor.y})"}
                  style={"color: #{peer.color}"}
                >
                  <path
                    d="M 0 0 L 0 14 L 4 11 L 7 17 L 9 16 L 6 10 L 11 10 Z"
                    fill="currentColor"
                    stroke="black"
                    stroke-width="0.5"
                  />
                  <text
                    x="14"
                    y="14"
                    class="text-xs fill-current"
                    style="paint-order: stroke; stroke: black; stroke-width: 2px;"
                  >
                    {peer.name}
                  </text>
                </g>
              </g>
            </g>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".CanvasViewport">
              const SVG_NS = "http://www.w3.org/2000/svg"
              const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

              function ulid() {
                const ts = BigInt(Date.now())
                const rand = new Uint8Array(10)
                crypto.getRandomValues(rand)
                let bi = ts << 80n
                for (let i = 0; i < 10; i++) {
                  bi |= BigInt(rand[i]) << BigInt((9 - i) * 8)
                }
                bi &= (1n << 130n) - 1n
                let out = ""
                for (let i = 25; i >= 0; i--) {
                  out += ALPHABET[Number((bi >> BigInt(i * 5)) & 31n)]
                }
                return out
              }

              const DRAG_THRESHOLD = 3 // px
              const CURSOR_THROTTLE_MS = 33 // ~30 Hz

              export default {
                mounted() {
                  this.scale = 1
                  this.tx = 0
                  this.ty = 0
                  this.viewport = this.el.querySelector("#viewport")
                  this.preview = this.el.querySelector("#canvas-preview")
                  this.lastCursorAt = 0
                  this.applyTransform()

                  // Per-canvas grid preference, stored in localStorage.
                  this.gridStorageKey = `dx-grid:${this.el.dataset.canvasId || "default"}`
                  this.handleEvent("grid_changed", ({on}) => {
                    try { localStorage.setItem(this.gridStorageKey, on ? "true" : "false") } catch (_) {}
                  })
                  let stored = null
                  try { stored = localStorage.getItem(this.gridStorageKey) } catch (_) {}
                  if (stored !== null) {
                    const want = stored === "true"
                    if ((this.el.dataset.snapGrid === "true") !== want) {
                      this.pushEvent("set_grid", { on: want })
                    }
                  }

                  this.onWheelBound = (e) => this.onWheel(e)
                  this.onPointerDownBound = (e) => this.onPointerDown(e)
                  this.onMove = (e) => this.onPointerMove(e)
                  this.onUp = (e) => this.onPointerUp(e)
                  this.onSvgMove = (e) => this.onSvgPointerMove(e)
                  this.onKey = (e) => this.onKeyDown(e)

                  this.onFitCanvas = () => this.fitCamera()

                  this.el.addEventListener("wheel", this.onWheelBound, { passive: false })
                  this.el.addEventListener("pointerdown", this.onPointerDownBound)
                  this.el.addEventListener("pointermove", this.onSvgMove)
                  this.el.addEventListener("phx:fit-canvas", this.onFitCanvas)
                  window.addEventListener("pointermove", this.onMove)
                  window.addEventListener("pointerup", this.onUp)
                  window.addEventListener("keydown", this.onKey)
                },
                destroyed() {
                  this.el.removeEventListener("wheel", this.onWheelBound)
                  this.el.removeEventListener("pointerdown", this.onPointerDownBound)
                  this.el.removeEventListener("pointermove", this.onSvgMove)
                  this.el.removeEventListener("phx:fit-canvas", this.onFitCanvas)
                  window.removeEventListener("pointermove", this.onMove)
                  window.removeEventListener("pointerup", this.onUp)
                  window.removeEventListener("keydown", this.onKey)
                },
                fitCamera() {
                  const elements = this.viewport.querySelectorAll("[data-element-id]")
                  if (elements.length === 0) {
                    this.tx = 0; this.ty = 0; this.scale = 1
                    this.applyTransform()
                    return
                  }
                  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
                  elements.forEach(g => {
                    let bx, by, bw, bh
                    if (g.dataset.elementType === "circle") {
                      const cx = parseFloat(g.dataset.cx)
                      const cy = parseFloat(g.dataset.cy)
                      const r = parseFloat(g.dataset.r)
                      bx = cx - r; by = cy - r; bw = 2 * r; bh = 2 * r
                    } else {
                      bx = parseFloat(g.dataset.x); by = parseFloat(g.dataset.y)
                      bw = parseFloat(g.dataset.w); bh = parseFloat(g.dataset.h)
                    }
                    if (!isFinite(bx) || !isFinite(by) || !isFinite(bw) || !isFinite(bh)) return
                    minX = Math.min(minX, bx)
                    minY = Math.min(minY, by)
                    maxX = Math.max(maxX, bx + bw)
                    maxY = Math.max(maxY, by + bh)
                  })
                  if (!isFinite(minX) || !isFinite(maxX)) return
                  const bw = maxX - minX
                  const bh = maxY - minY
                  if (bw <= 0 || bh <= 0) return
                  const rect = this.el.getBoundingClientRect()
                  const margin = 32
                  const sx = (rect.width - margin * 2) / bw
                  const sy = (rect.height - margin * 2) / bh
                  this.scale = Math.max(0.05, Math.min(2, Math.min(sx, sy)))
                  this.tx = -minX * this.scale + (rect.width - bw * this.scale) / 2
                  this.ty = -minY * this.scale + (rect.height - bh * this.scale) / 2
                  this.applyTransform()
                },
                onKeyDown(e) {
                  // Ignore shortcuts while typing in any input/textarea.
                  const t = e.target
                  const tag = t && t.tagName
                  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (t && t.isContentEditable)) return

                  if (e.key === "Escape") {
                    this.pushEvent("select_tool", { tool: "select" })
                    return
                  }

                  if (e.key === "Delete" || e.key === "Backspace") {
                    if (this.el.dataset.hasSelection === "true" && this.el.dataset.readOnly !== "true") {
                      e.preventDefault()
                      this.pushEvent("delete_selected", {})
                    }
                    return
                  }

                  if (e.key === "PageUp" || e.key === "PageDown") {
                    e.preventDefault()
                    const action = e.key === "PageUp"
                      ? (e.shiftKey ? "to_front" : "forward")
                      : (e.shiftKey ? "to_back" : "backward")
                    this.pushEvent("z_order", { action })
                    return
                  }

                  if (!(e.ctrlKey || e.metaKey)) return
                  if (e.altKey) return

                  if (!e.shiftKey) {
                    if (e.key === "c" || e.key === "C") {
                      if (this.el.dataset.hasSelection === "true") {
                        e.preventDefault()
                        this.pushEvent("copy_selection", {})
                      }
                      return
                    }
                    if (e.key === "v" || e.key === "V") {
                      if (this.el.dataset.readOnly !== "true") {
                        e.preventDefault()
                        this.pushEvent("paste_selection", {})
                      }
                      return
                    }
                  }

                  if (e.shiftKey) return

                  const map = { "0": "select", "1": "text", "2": "rect", "3": "rounded", "4": "circle", "5": "connector" }
                  const tool = map[e.key]
                  if (!tool) return
                  e.preventDefault()
                  this.pushEvent("select_tool", { tool })
                },
                onSvgPointerMove(e) {
                  const now = performance.now()
                  if (now - this.lastCursorAt < CURSOR_THROTTLE_MS) return
                  this.lastCursorAt = now
                  const pt = this.worldPoint(e)
                  this.pushEvent("cursor", { x: pt.x, y: pt.y })
                },
                applyTransform() {
                  this.viewport.setAttribute(
                    "transform",
                    `translate(${this.tx} ${this.ty}) scale(${this.scale})`
                  )
                },
                worldPoint(e) {
                  const rect = this.el.getBoundingClientRect()
                  return {
                    x: (e.clientX - rect.left - this.tx) / this.scale,
                    y: (e.clientY - rect.top - this.ty) / this.scale
                  }
                },
                tool() { return this.el.dataset.tool || "select" },
                readOnly() { return this.el.dataset.readOnly === "true" },
                snapEnabled() { return this.el.dataset.snapGrid === "true" },
                gridSize() { return parseFloat(this.el.dataset.gridSize) || 20 },
                snap(v) {
                  if (!this.snapEnabled()) return v
                  const g = this.gridSize()
                  return Math.round(v / g) * g
                },
                snapPoint(p) {
                  return { x: this.snap(p.x), y: this.snap(p.y) }
                },
                onWheel(e) {
                  e.preventDefault()
                  const factor = e.deltaY < 0 ? 1.1 : 1 / 1.1
                  const rect = this.el.getBoundingClientRect()
                  const cx = e.clientX - rect.left
                  const cy = e.clientY - rect.top
                  const wx = (cx - this.tx) / this.scale
                  const wy = (cy - this.ty) / this.scale
                  this.scale = Math.max(0.1, Math.min(8, this.scale * factor))
                  this.tx = cx - wx * this.scale
                  this.ty = cy - wy * this.scale
                  this.applyTransform()
                },
                findElementGroup(target) {
                  let node = target
                  while (node && node !== this.el) {
                    if (node.dataset && node.dataset.elementId) return node
                    node = node.parentNode
                  }
                  return null
                },
                findResizeHandle(target) {
                  let node = target
                  while (node && node !== this.el) {
                    if (node.dataset && node.dataset.resizeHandle) return node
                    node = node.parentNode
                  }
                  return null
                },
                findConnectorGroup(target) {
                  let node = target
                  while (node && node !== this.el) {
                    if (node.dataset && node.dataset.connectorId) return node
                    node = node.parentNode
                  }
                  return null
                },
                elementCenter(group) {
                  if (group.dataset.elementType === "circle") {
                    return { x: parseFloat(group.dataset.cx), y: parseFloat(group.dataset.cy) }
                  }
                  return {
                    x: parseFloat(group.dataset.x) + parseFloat(group.dataset.w) / 2,
                    y: parseFloat(group.dataset.y) + parseFloat(group.dataset.h) / 2
                  }
                },
                onPointerDown(e) {
                  if (e.button !== 0 && e.button !== 1) return

                  // Middle-click or space-modified → pan
                  if (e.button === 1 || e.shiftKey) {
                    this.action = { kind: "pan", lastX: e.clientX, lastY: e.clientY }
                    return
                  }

                  const tool = this.tool()
                  const group = this.findElementGroup(e.target)

                  if (tool === "select") {
                    const handle = this.findResizeHandle(e.target)
                    if (handle && group) {
                      this.action = {
                        kind: "resize",
                        group,
                        elementId: group.dataset.elementId,
                        type: group.dataset.elementType,
                        startWorld: this.worldPoint(e),
                        startClient: { x: e.clientX, y: e.clientY }
                      }
                      return
                    }

                    if (group) {
                      this.pushEvent("select_element", {
                        id: group.dataset.elementId,
                        multi: e.ctrlKey || e.metaKey
                      })
                      this.pushEvent("set_lock", { id: group.dataset.elementId })
                      this.action = {
                        kind: "move",
                        group,
                        elementId: group.dataset.elementId,
                        type: group.dataset.elementType,
                        startWorld: this.worldPoint(e),
                        startClient: { x: e.clientX, y: e.clientY },
                        moved: false
                      }
                      return
                    }

                    const conGroup = this.findConnectorGroup(e.target)
                    if (conGroup) {
                      this.pushEvent("select_connector", {
                        id: conGroup.dataset.connectorId,
                        multi: e.ctrlKey || e.metaKey
                      })
                      return
                    }

                    // Empty area drag → lasso. Empty click without movement → clear selection.
                    const start = this.worldPoint(e)
                    this.action = {
                      kind: "lasso",
                      start,
                      current: start,
                      startClient: { x: e.clientX, y: e.clientY }
                    }
                    this.renderLassoPreview()
                    return
                  }

                  if (this.readOnly()) return

                  if (tool === "connector") {
                    if (!group) return
                    const center = this.elementCenter(group)
                    this.action = {
                      kind: "connect",
                      fromId: group.dataset.elementId,
                      fromCenter: center,
                      current: this.worldPoint(e)
                    }
                    this.renderConnectorPreview()
                    return
                  }

                  // Drawing tools
                  if (["rect", "rounded", "circle", "text"].includes(tool)) {
                    const start = this.worldPoint(e)
                    this.action = { kind: "draw", tool, start, current: start }
                    this.renderPreview()
                  }
                },
                onPointerMove(e) {
                  if (!this.action) return
                  const a = this.action

                  if (a.kind === "pan") {
                    this.tx += e.clientX - a.lastX
                    this.ty += e.clientY - a.lastY
                    a.lastX = e.clientX
                    a.lastY = e.clientY
                    this.applyTransform()
                    return
                  }

                  if (a.kind === "draw") {
                    a.current = this.worldPoint(e)
                    this.renderPreview()
                    return
                  }

                  if (a.kind === "connect") {
                    a.current = this.worldPoint(e)
                    this.renderConnectorPreview()
                    return
                  }

                  if (a.kind === "lasso") {
                    a.current = this.worldPoint(e)
                    this.renderLassoPreview()
                    return
                  }

                  if (a.kind === "move") {
                    const dx = e.clientX - a.startClient.x
                    const dy = e.clientY - a.startClient.y
                    if (!a.moved && Math.hypot(dx, dy) > DRAG_THRESHOLD) {
                      a.moved = true
                    }
                    if (a.moved) {
                      a.group.setAttribute(
                        "transform",
                        `translate(${dx / this.scale} ${dy / this.scale})`
                      )
                    }
                    return
                  }

                  if (a.kind === "resize") {
                    // Live preview: stretch the group via SVG transform from
                    // the top-left (or center for circles), then reset on drop.
                    const ds = this.el.dataset
                    const w0 = parseFloat(a.group.dataset.w)
                    const h0 = parseFloat(a.group.dataset.h)
                    const dx = (e.clientX - a.startClient.x) / this.scale
                    const dy = (e.clientY - a.startClient.y) / this.scale
                    if (a.type === "circle") {
                      const r0 = parseFloat(a.group.dataset.r)
                      const newR = Math.max(4, r0 + Math.max(dx, dy))
                      const sf = newR / r0
                      const cx = parseFloat(a.group.dataset.cx)
                      const cy = parseFloat(a.group.dataset.cy)
                      a.group.setAttribute(
                        "transform",
                        `translate(${cx} ${cy}) scale(${sf}) translate(${-cx} ${-cy})`
                      )
                    } else {
                      const newW = Math.max(8, w0 + dx)
                      const newH = Math.max(8, h0 + dy)
                      const sx = newW / w0
                      const sy = newH / h0
                      const x0 = parseFloat(a.group.dataset.x)
                      const y0 = parseFloat(a.group.dataset.y)
                      a.group.setAttribute(
                        "transform",
                        `translate(${x0} ${y0}) scale(${sx} ${sy}) translate(${-x0} ${-y0})`
                      )
                    }
                  }
                },
                onPointerUp(e) {
                  const a = this.action
                  this.action = null
                  if (!a) return

                  if (a.kind === "pan") return

                  if (a.kind === "lasso") {
                    this.preview.replaceChildren()
                    const dx = e.clientX - a.startClient.x
                    const dy = e.clientY - a.startClient.y
                    if (Math.hypot(dx, dy) < DRAG_THRESHOLD) {
                      this.pushEvent("clear_selection", {})
                      return
                    }
                    this.commitLasso(a)
                    return
                  }

                  if (a.kind === "draw") {
                    this.preview.replaceChildren()
                    this.commitDraw(a)
                    return
                  }

                  if (a.kind === "connect") {
                    this.preview.replaceChildren()
                    const targetGroup = this.findElementGroup(e.target)
                    if (targetGroup && targetGroup.dataset.elementId !== a.fromId) {
                      const id = ulid()
                      this.pushEvent("apply_op", {
                        op: {
                          type: "insert_connector",
                          connector: {
                            id,
                            from: { element: a.fromId, anchor: "auto", _other: targetGroup.dataset.elementId },
                            to: { element: targetGroup.dataset.elementId, anchor: "auto", _other: a.fromId },
                            routing: "orthogonal",
                            dash: "solid",
                            marker_start: "none",
                            marker_end: "arrow",
                            start_gap: 6,
                            end_gap: 6,
                            stroke_width: 2
                          }
                        }
                      })
                    }
                    return
                  }

                  if (a.kind === "resize") {
                    a.group.removeAttribute("transform")
                    const dx = (e.clientX - a.startClient.x) / this.scale
                    const dy = (e.clientY - a.startClient.y) / this.scale
                    let patch
                    if (a.type === "circle") {
                      const r0 = parseFloat(a.group.dataset.r)
                      const newR = Math.max(4, this.snap(r0 + Math.max(dx, dy)))
                      patch = { r: newR }
                    } else {
                      const w0 = parseFloat(a.group.dataset.w)
                      const h0 = parseFloat(a.group.dataset.h)
                      patch = {
                        w: Math.max(8, this.snap(w0 + dx)),
                        h: Math.max(8, this.snap(h0 + dy))
                      }
                    }
                    this.pushEvent("apply_op", {
                      op: { type: "update_element", id: a.elementId, patch }
                    })
                    return
                  }

                  if (a.kind === "move") {
                    this.pushEvent("clear_lock", {})
                    if (!a.moved) {
                      this.pushEvent("select_element", { id: a.elementId })
                      return
                    }
                    a.group.removeAttribute("transform")
                    const dx = e.clientX - a.startClient.x
                    const dy = e.clientY - a.startClient.y
                    const wx = dx / this.scale
                    const wy = dy / this.scale
                    let patch
                    if (a.type === "circle") {
                      patch = {
                        cx: this.snap(parseFloat(a.group.dataset.cx) + wx),
                        cy: this.snap(parseFloat(a.group.dataset.cy) + wy)
                      }
                    } else {
                      patch = {
                        x: this.snap(parseFloat(a.group.dataset.x) + wx),
                        y: this.snap(parseFloat(a.group.dataset.y) + wy)
                      }
                    }
                    this.pushEvent("apply_op", {
                      op: { type: "update_element", id: a.elementId, patch }
                    })
                  }
                },
                renderPreview() {
                  const a = this.action
                  if (!a || a.kind !== "draw") return
                  this.preview.replaceChildren()
                  const el = this.shapePreviewElement(a)
                  if (el) this.preview.appendChild(el)
                },
                renderLassoPreview() {
                  const a = this.action
                  if (!a || a.kind !== "lasso") return
                  this.preview.replaceChildren()
                  const x1 = Math.min(a.start.x, a.current.x)
                  const y1 = Math.min(a.start.y, a.current.y)
                  const w = Math.abs(a.current.x - a.start.x)
                  const h = Math.abs(a.current.y - a.start.y)
                  if (w < 1 && h < 1) return
                  const rect = document.createElementNS(SVG_NS, "rect")
                  rect.setAttribute("x", x1); rect.setAttribute("y", y1)
                  rect.setAttribute("width", w); rect.setAttribute("height", h)
                  rect.setAttribute("fill", "currentColor")
                  rect.setAttribute("fill-opacity", "0.08")
                  rect.setAttribute("stroke", "currentColor")
                  rect.setAttribute("stroke-dasharray", "4 3")
                  this.preview.appendChild(rect)
                },
                commitLasso(a) {
                  const x1 = Math.min(a.start.x, a.current.x)
                  const y1 = Math.min(a.start.y, a.current.y)
                  const x2 = Math.max(a.start.x, a.current.x)
                  const y2 = Math.max(a.start.y, a.current.y)

                  const elementIds = []
                  this.viewport.querySelectorAll("[data-element-id]").forEach(g => {
                    const id = g.dataset.elementId
                    if (!id) return
                    let bx, by, bw, bh
                    if (g.dataset.elementType === "circle") {
                      const cx = parseFloat(g.dataset.cx)
                      const cy = parseFloat(g.dataset.cy)
                      const r = parseFloat(g.dataset.r)
                      bx = cx - r; by = cy - r; bw = 2 * r; bh = 2 * r
                    } else {
                      bx = parseFloat(g.dataset.x); by = parseFloat(g.dataset.y)
                      bw = parseFloat(g.dataset.w); bh = parseFloat(g.dataset.h)
                    }
                    if (bx < x2 && bx + bw > x1 && by < y2 && by + bh > y1) {
                      elementIds.push(id)
                    }
                  })

                  // Auto-include connectors whose endpoints are both inside the
                  // lasso so copy/paste gets the wires too.
                  const elSet = new Set(elementIds)
                  const connectorIds = []
                  this.viewport.querySelectorAll("[data-connector-id]").forEach(g => {
                    const id = g.dataset.connectorId
                    const path = g.querySelector("path")
                    if (path) {
                      try {
                        const bb = path.getBBox()
                        if (bb.x < x2 && bb.x + bb.width > x1 && bb.y < y2 && bb.y + bb.height > y1) {
                          connectorIds.push(id)
                        }
                      } catch (_) {}
                    }
                  })

                  this.pushEvent("select_set", { elements: elementIds, connectors: connectorIds })
                },
                renderConnectorPreview() {
                  const a = this.action
                  if (!a || a.kind !== "connect") return
                  this.preview.replaceChildren()
                  const line = document.createElementNS(SVG_NS, "line")
                  line.setAttribute("x1", a.fromCenter.x)
                  line.setAttribute("y1", a.fromCenter.y)
                  line.setAttribute("x2", a.current.x)
                  line.setAttribute("y2", a.current.y)
                  line.setAttribute("stroke", "currentColor")
                  line.setAttribute("stroke-dasharray", "4 3")
                  this.preview.appendChild(line)
                },
                shapePreviewElement(a) {
                  const x1 = Math.min(a.start.x, a.current.x)
                  const y1 = Math.min(a.start.y, a.current.y)
                  const w = Math.abs(a.current.x - a.start.x)
                  const h = Math.abs(a.current.y - a.start.y)
                  if (w < 1 && h < 1) return null

                  if (a.tool === "circle") {
                    const cx = (a.start.x + a.current.x) / 2
                    const cy = (a.start.y + a.current.y) / 2
                    const r = Math.max(w, h) / 2
                    const c = document.createElementNS(SVG_NS, "circle")
                    c.setAttribute("cx", cx); c.setAttribute("cy", cy); c.setAttribute("r", r)
                    c.setAttribute("fill", "none")
                    c.setAttribute("stroke", "currentColor")
                    c.setAttribute("stroke-dasharray", "4 3")
                    return c
                  }

                  const rect = document.createElementNS(SVG_NS, "rect")
                  rect.setAttribute("x", x1); rect.setAttribute("y", y1)
                  rect.setAttribute("width", w); rect.setAttribute("height", h)
                  if (a.tool === "rounded") { rect.setAttribute("rx", 8); rect.setAttribute("ry", 8) }
                  rect.setAttribute("fill", "none")
                  rect.setAttribute("stroke", "currentColor")
                  rect.setAttribute("stroke-dasharray", "4 3")
                  return rect
                },
                commitDraw(a) {
                  const start = this.snapPoint(a.start)
                  const current = this.snapPoint(a.current)
                  const x1 = Math.min(start.x, current.x)
                  const y1 = Math.min(start.y, current.y)
                  const w = Math.max(Math.abs(current.x - start.x), 8)
                  const h = Math.max(Math.abs(current.y - start.y), 8)
                  const id = ulid()
                  let element

                  if (a.tool === "circle") {
                    element = {
                      id, type: "circle",
                      cx: (start.x + current.x) / 2,
                      cy: (start.y + current.y) / 2,
                      r: Math.max(w, h) / 2,
                      label: ""
                    }
                  } else {
                    element = { id, type: a.tool, x: x1, y: y1, w, h, label: a.tool === "text" ? "Text" : "" }
                  }

                  this.pushEvent("apply_op", {
                    op: { type: "insert_element", element }
                  })
                }
              }
            </script>
          </svg>
        </main>

        <%= if @show_mermaid do %>
          <div
            class="modal modal-open"
            id="mermaid-export-modal"
            phx-window-keydown="close_mermaid"
            phx-key="escape"
          >
            <div class="modal-box max-w-3xl">
              <h3 class="font-bold text-lg mb-2">Mermaid export</h3>
              <p class="text-sm opacity-70 mb-3">
                Paste this into any Mermaid renderer (mermaid.live, GitHub markdown, etc.).
              </p>
              <pre
                phx-no-curly-interpolation
                class="bg-base-300 p-3 rounded-box text-sm overflow-auto whitespace-pre"
              ><code id="mermaid-source"><%= @mermaid_source %></code></pre>
              <div class="modal-action">
                <button type="button" phx-click="close_mermaid" class="btn btn-ghost">Close</button>
              </div>
            </div>
          </div>
        <% end %>

        <aside
          id="property-panel"
          class="border-l border-base-300 bg-base-200 p-3 overflow-y-auto"
        >
          <div class="flex items-center justify-between mb-2 gap-2">
            <h2 class="font-mono text-xs uppercase tracking-wide text-accent">Properties</h2>
            <div class="flex items-center gap-1">
              <%= if selection_focus(@selection) do %>
                <button
                  type="button"
                  id="btn-copy-style"
                  phx-click="copy_style"
                  class="btn btn-ghost btn-xs"
                  title="Copy style"
                >
                  <.icon name="hero-clipboard-micro" class="size-4" />
                </button>
                <button
                  type="button"
                  id="btn-paste-style"
                  phx-click="paste_style"
                  class="btn btn-ghost btn-xs"
                  disabled={
                    @read_only or
                      !style_clipboard_compatible?(@style_clipboard, selection_focus(@selection))
                  }
                  title="Paste style"
                >
                  <.icon name="hero-clipboard-document-check-micro" class="size-4" />
                </button>
              <% end %>
              <%= if @selection != [] do %>
                <button
                  type="button"
                  id="btn-copy-selection"
                  phx-click="copy_selection"
                  class="btn btn-ghost btn-xs"
                  title="Copy selection (Ctrl-C)"
                >
                  <.icon name="hero-document-duplicate-micro" class="size-4" />
                </button>
              <% end %>
              <button
                type="button"
                id="btn-paste-selection"
                phx-click="paste_selection"
                class="btn btn-ghost btn-xs"
                disabled={@read_only or @selection_clipboard == nil}
                title="Paste selection (Ctrl-V)"
              >
                <.icon name="hero-clipboard-document-list-micro" class="size-4" />
              </button>
            </div>
          </div>

          <.style_clipboard_preview clipboard={@style_clipboard} />
          <.property_panel
            selection={@selection}
            element={selected_element(@document, @selection)}
            connector={selected_connector(@document, @selection)}
            read_only={@read_only}
          />
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :element, :map, required: true

  defp shape_label(%{element: element} = assigns) do
    if (element["label"] || "") == "" do
      ~H""
    else
      assigns =
        assigns
        |> assign(:geom, label_geom(element))
        |> assign(:text_style, shape_label_style(element))

      ~H"""
      <text
        x={@geom.x}
        y={@geom.y}
        text-anchor={@geom.text_anchor}
        dominant-baseline={@geom.baseline}
        style={@text_style}
      >{@element["label"]}</text>
      """
    end
  end

  @doc false
  def shape_label_style(element) do
    color = get_in(element, ["style", "label_color"]) || "base-content"
    family = font_family_css(get_in(element, ["style", "label_font_family"]) || "sans")
    size = label_size_px(get_in(element, ["style", "label_size"]) || "md")
    weight = if get_in(element, ["style", "label_bold"]) == true, do: "700", else: "400"
    style_part = if get_in(element, ["style", "label_italic"]) == true, do: "italic", else: "normal"

    "fill: #{token_var(color)}; font-family: #{family}; font-size: #{size}px; font-weight: #{weight}; font-style: #{style_part};"
  end

  attr :element, :map, required: true

  defp link_overlay(%{element: element} = assigns) do
    enabled = enabled_links(element)

    if enabled == [] do
      ~H""
    else
      assigns = assign(assigns, :placements, link_placements(element, enabled))

      ~H"""
      <%= for %{link: link, x: x, y: y, size: size, href: href, icon: icon} <- @placements do %>
        <a
          href={href}
          target={if link["kind"] == "external", do: "_blank", else: nil}
          rel={if link["kind"] == "external", do: "noopener noreferrer", else: nil}
          class="text-accent"
        >
          <rect
            x={x - 1}
            y={y - 1}
            width={size + 2}
            height={size + 2}
            rx="3"
            ry="3"
            class="fill-base-100 stroke-accent"
            stroke-width="1"
          />
          <use href={"#" <> icon} x={x} y={y} width={size} height={size} />
        </a>
      <% end %>
      """
    end
  end

  @doc false
  def enabled_links(%{"links" => links}) when is_list(links),
    do: Enum.filter(links, &(&1["enabled"] == true))

  def enabled_links(_), do: []

  @doc """
  Returns one placement per enabled link, stacked horizontally from the
  bottom-right corner of the element's bbox toward the left so the
  "primary" (first) link is closest to the corner.
  """
  def link_placements(element, enabled_links) do
    {origin_x, origin_y, size} = link_overlay_geometry(element)
    gap = 2

    enabled_links
    |> Enum.with_index()
    |> Enum.map(fn {link, i} ->
      %{
        link: link,
        href: link_href(link),
        icon: link_icon_id(link["icon"]),
        x: origin_x - i * (size + gap),
        y: origin_y,
        size: size
      }
    end)
  end

  @doc false
  def link_overlay_geometry(%{"type" => "circle"} = e) do
    smallest = 2 * (e["r"] || 0)
    size = max(8, smallest * 0.08)
    bbox_x = (e["cx"] || 0) - (e["r"] || 0)
    bbox_y = (e["cy"] || 0) - (e["r"] || 0)
    pad = 2
    {bbox_x + smallest - size - pad, bbox_y + smallest - size - pad, size}
  end

  def link_overlay_geometry(%{"w" => w, "h" => h, "x" => x, "y" => y}) do
    smallest = min(w, h)
    size = max(8, smallest * 0.08)
    pad = 2
    {x + w - size - pad, y + h - size - pad, size}
  end

  def link_overlay_geometry(_), do: {0, 0, 0}

  @doc false
  def link_icon_id(name), do: "dx-link-icon-#{name || "link"}"

  @doc false
  def link_href(%{"kind" => "canvas", "target" => slug}) when is_binary(slug) and slug != "",
    do: "/c-embed/#{slug}"

  def link_href(%{"target" => target}) when is_binary(target), do: target
  def link_href(_), do: "#"

  attr :element, :map, required: true
  attr :element_id, :string, required: true

  defp resize_handle(%{element: %{"type" => "circle"} = el} = assigns) do
    handle_size = 10
    cx = el["cx"] + el["r"]
    cy = el["cy"] + el["r"]
    assigns = assign(assigns, x: cx - handle_size / 2, y: cy - handle_size / 2, size: handle_size)

    ~H"""
    <rect
      x={@x}
      y={@y}
      width={@size}
      height={@size}
      class="fill-accent stroke-base-100 cursor-nwse-resize"
      stroke-width="1"
      data-resize-handle={@element_id}
      pointer-events="all"
    />
    """
  end

  defp resize_handle(%{element: el} = assigns) do
    handle_size = 10

    assigns =
      assign(assigns,
        x: el["x"] + el["w"] - handle_size / 2,
        y: el["y"] + el["h"] - handle_size / 2,
        size: handle_size
      )

    ~H"""
    <rect
      x={@x}
      y={@y}
      width={@size}
      height={@size}
      class="fill-accent stroke-base-100 cursor-nwse-resize"
      stroke-width="1"
      data-resize-handle={@element_id}
      pointer-events="all"
    />
    """
  end

  attr :element, :map, required: true

  defp element_node(%{element: %{"type" => "rect"}} = assigns) do
    ~H"""
    <%= if shadow?(@element) do %>
      <rect
        x={@element["x"] + shadow_offset()}
        y={@element["y"] + shadow_offset()}
        width={@element["w"]}
        height={@element["h"]}
        style={shadow_style(@element)}
      />
    <% end %>
    <rect
      x={@element["x"]}
      y={@element["y"]}
      width={@element["w"]}
      height={@element["h"]}
      style={shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.shape_label element={@element} />
    <.link_overlay element={@element} />
    """
  end

  defp element_node(%{element: %{"type" => "rounded"}} = assigns) do
    ~H"""
    <%= if shadow?(@element) do %>
      <rect
        x={@element["x"] + shadow_offset()}
        y={@element["y"] + shadow_offset()}
        width={@element["w"]}
        height={@element["h"]}
        rx="8"
        ry="8"
        style={shadow_style(@element)}
      />
    <% end %>
    <rect
      x={@element["x"]}
      y={@element["y"]}
      width={@element["w"]}
      height={@element["h"]}
      rx="8"
      ry="8"
      style={shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.shape_label element={@element} />
    <.link_overlay element={@element} />
    """
  end

  defp element_node(%{element: %{"type" => "circle"}} = assigns) do
    ~H"""
    <%= if shadow?(@element) do %>
      <circle
        cx={@element["cx"] + shadow_offset()}
        cy={@element["cy"] + shadow_offset()}
        r={@element["r"]}
        style={shadow_style(@element)}
      />
    <% end %>
    <circle
      cx={@element["cx"]}
      cy={@element["cy"]}
      r={@element["r"]}
      style={shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.shape_label element={@element} />
    <.link_overlay element={@element} />
    """
  end

  defp element_node(%{element: %{"type" => "text"}} = assigns) do
    ~H"""
    <text
      x={@element["x"]}
      y={@element["y"] + text_baseline(@element)}
      style={text_element_style(@element)}
      pointer-events="visiblePainted"
    >
      {@element["label"]}
    </text>
    <.link_overlay element={@element} />
    """
  end

  @doc false
  def text_element_style(element) do
    fill = get_in(element, ["style", "fill"]) || "base-content"
    family = font_family_css(get_in(element, ["style", "font_family"]) || "sans")
    size = get_in(element, ["style", "font_size"]) || 14
    weight = if get_in(element, ["style", "font_bold"]) == true, do: "700", else: "400"
    style = if get_in(element, ["style", "font_italic"]) == true, do: "italic", else: "normal"

    "fill: #{token_var(fill)}; font-family: #{family}; font-size: #{size}px; font-weight: #{weight}; font-style: #{style};"
  end

  @doc false
  def font_family_css("serif"), do: "ui-serif, Georgia, serif"
  def font_family_css("mono"), do: "ui-monospace, SFMono-Regular, Menlo, monospace"
  def font_family_css("b612"), do: "'B612', system-ui, sans-serif"

  def font_family_css("b612-mono"),
    do: "'B612 Mono', ui-monospace, SFMono-Regular, Menlo, monospace"

  def font_family_css(_), do: "ui-sans-serif, system-ui, sans-serif"

  @doc false
  def text_baseline(element) do
    size = get_in(element, ["style", "font_size"]) || 14
    # Approximate ascender height so the top of the glyph aligns to y.
    round(size * 0.85)
  end

  @doc """
  Computes label placement attrs for a shape (rect/rounded/circle).
  Returns `%{x, y, text_anchor, baseline, font_size}` driven by
  `style.label_position` and `style.label_size`.
  """
  def label_geom(element) do
    {x, y, w, h} = bbox_of(element)
    pos = get_in(element, ["style", "label_position"]) || default_label_position(element)
    size = label_size_px(get_in(element, ["style", "label_size"]) || "md")
    pad = 8

    {ax, anchor} =
      case pos do
        p when p in ["tl", "ml", "bl"] -> {x + pad, "start"}
        p when p in ["tc", "center", "bc"] -> {x + w / 2, "middle"}
        p when p in ["tr", "mr", "br"] -> {x + w - pad, "end"}
        _ -> {x + w / 2, "middle"}
      end

    {ay, baseline} =
      case pos do
        p when p in ["tl", "tc", "tr"] -> {y + pad, "hanging"}
        p when p in ["ml", "center", "mr"] -> {y + h / 2, "middle"}
        p when p in ["bl", "bc", "br"] -> {y + h - pad, "auto"}
        _ -> {y + h / 2, "middle"}
      end

    %{x: ax, y: ay, text_anchor: anchor, baseline: baseline, font_size: size}
  end

  defp bbox_of(%{"type" => "circle", "cx" => cx, "cy" => cy, "r" => r}),
    do: {cx - r, cy - r, 2 * r, 2 * r}

  defp bbox_of(%{"x" => x, "y" => y, "w" => w, "h" => h}), do: {x, y, w, h}

  defp default_label_position(%{"type" => "circle"}), do: "center"
  defp default_label_position(_), do: "tl"

  defp label_size_px("sm"), do: 11
  defp label_size_px("md"), do: 14
  defp label_size_px("lg"), do: 18
  defp label_size_px("xl"), do: 24
  defp label_size_px(_), do: 14

  @doc false
  def shape_style(element) do
    fill = get_in(element, ["style", "fill"]) || "base-200"
    stroke = get_in(element, ["style", "stroke"]) || "base-content"
    width = get_in(element, ["style", "stroke_width"]) || 1.5
    dash = shape_dash_array(get_in(element, ["style", "dash"]) || "solid")

    base = "fill: #{token_var(fill)}; stroke: #{token_var(stroke)}; stroke-width: #{width};"
    if dash, do: base <> " stroke-dasharray: #{dash};", else: base
  end

  defp shape_dash_array("solid"), do: nil
  defp shape_dash_array("dotted"), do: "2 4"
  defp shape_dash_array("dashed"), do: "8 6"
  defp shape_dash_array("dash-dot"), do: "8 4 2 4"
  defp shape_dash_array(_), do: nil

  @doc false
  def shadow_style(element) do
    color =
      get_in(element, ["style", "fill"]) || get_in(element, ["style", "stroke"]) || "base-content"

    "fill: #{token_var(color)}; stroke: #{token_var(color)}; stroke-width: 1; opacity: 0.55;"
  end

  @doc false
  def shadow?(element), do: get_in(element, ["style", "shadow"]) == true

  @doc false
  def shadow_offset, do: 12

  @doc false
  def token_var("transparent"), do: "transparent"
  def token_var(token), do: "var(--color-#{token})"

  defp tool_icon("select"), do: "hero-cursor-arrow-rays"
  defp tool_icon("text"), do: "hero-language"
  defp tool_icon("rect"), do: "hero-square-2-stack"
  defp tool_icon("rounded"), do: "hero-stop"
  defp tool_icon("circle"), do: "hero-circle-stack"
  defp tool_icon("connector"), do: "hero-arrow-long-right"

  defp tool_label("select"), do: "Select / move"
  defp tool_label("text"), do: "Text"
  defp tool_label("rect"), do: "Rectangle"
  defp tool_label("rounded"), do: "Rounded rectangle"
  defp tool_label("circle"), do: "Circle"
  defp tool_label("connector"), do: "Connector"

  defp tool_shortcut("select"), do: "Esc / Ctrl-0"
  defp tool_shortcut("text"), do: "Ctrl-1"
  defp tool_shortcut("rect"), do: "Ctrl-2"
  defp tool_shortcut("rounded"), do: "Ctrl-3"
  defp tool_shortcut("circle"), do: "Ctrl-4"
  defp tool_shortcut("connector"), do: "Ctrl-5"

  ## ── Property panel ───────────────────────────────────────────────────────

  attr :selection, :any, required: true
  attr :element, :map, default: nil
  attr :connector, :map, default: nil
  attr :read_only, :boolean, default: false

  defp property_panel(%{selection: []} = assigns) do
    ~H"""
    <p class="text-sm opacity-70">
      Click an element to edit it. Drag from empty canvas in select mode to lasso a group.
    </p>
    """
  end

  defp property_panel(%{selection: selection} = assigns)
       when length(selection) > 1 do
    assigns =
      assigns
      |> assign(:n_elements, length(selection_element_ids(selection)))
      |> assign(:n_connectors, length(selection_connector_ids(selection)))

    ~H"""
    <div id="multi-selection-panel" class="flex flex-col gap-2">
      <p class="text-sm">
        Selected: <span class="font-mono">{@n_elements}</span>
        elements, <span class="font-mono">{@n_connectors}</span>
        connectors.
      </p>
      <button
        type="button"
        phx-click="delete_selected"
        class="btn btn-error btn-sm"
        disabled={@read_only}
      >
        <.icon name="hero-trash-micro" class="size-4" /> Delete all
      </button>
    </div>
    """
  end

  defp property_panel(%{selection: [{:element, _id}], element: nil} = assigns) do
    ~H"""
    <p class="text-sm opacity-70">Selected element no longer exists.</p>
    """
  end

  defp property_panel(%{selection: [{:element, id}], element: element} = assigns) do
    assigns =
      assign(assigns, :id, id) |> assign(:form, to_form(element_form_params(element), as: :props))

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <span class="font-mono text-xs">{@element["type"]}</span>
      <button
        type="button"
        phx-click="delete_selected"
        class="btn btn-ghost btn-xs text-error"
        disabled={@read_only}
      >
        <.icon name="hero-trash-micro" class="size-4" />
      </button>
    </div>
    <div class="flex items-center justify-between mb-2 text-xs">
      <span class="opacity-60">Order</span>
      <div class="join">
        <div class="tooltip tooltip-bottom" data-tip="Send to back">
          <button
            type="button"
            phx-click="z_order"
            phx-value-action="to_back"
            class="btn btn-ghost btn-xs join-item"
            disabled={@read_only}
            aria-label="Send to back"
          >
            <.icon name="hero-bars-arrow-down-micro" class="size-4" />
          </button>
        </div>
        <div class="tooltip tooltip-bottom" data-tip="Send backward">
          <button
            type="button"
            phx-click="z_order"
            phx-value-action="backward"
            class="btn btn-ghost btn-xs join-item"
            disabled={@read_only}
            aria-label="Send backward"
          >
            <.icon name="hero-arrow-down-micro" class="size-4" />
          </button>
        </div>
        <div class="tooltip tooltip-bottom" data-tip="Bring forward">
          <button
            type="button"
            phx-click="z_order"
            phx-value-action="forward"
            class="btn btn-ghost btn-xs join-item"
            disabled={@read_only}
            aria-label="Bring forward"
          >
            <.icon name="hero-arrow-up-micro" class="size-4" />
          </button>
        </div>
        <div class="tooltip tooltip-bottom" data-tip="Bring to front">
          <button
            type="button"
            phx-click="z_order"
            phx-value-action="to_front"
            class="btn btn-ghost btn-xs join-item"
            disabled={@read_only}
            aria-label="Bring to front"
          >
            <.icon name="hero-bars-arrow-up-micro" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    <.form
      for={@form}
      id={"el-form-" <> @id}
      phx-change="update_selected"
      phx-submit="update_selected"
      class="flex flex-col gap-2"
    >
      <.input field={@form[:label]} type="text" label="Label" disabled={@read_only} />
      <%= if @element["type"] == "circle" do %>
        <div class="grid grid-cols-3 gap-2">
          <.input field={@form[:cx]} type="number" label="cx" step="0.1" disabled={@read_only} />
          <.input field={@form[:cy]} type="number" label="cy" step="0.1" disabled={@read_only} />
          <.input field={@form[:r]} type="number" label="r" step="0.1" disabled={@read_only} />
        </div>
      <% else %>
        <div class="grid grid-cols-2 gap-2">
          <.input field={@form[:x]} type="number" label="x" step="0.1" disabled={@read_only} />
          <.input field={@form[:y]} type="number" label="y" step="0.1" disabled={@read_only} />
          <.input field={@form[:w]} type="number" label="w" step="0.1" disabled={@read_only} />
          <.input field={@form[:h]} type="number" label="h" step="0.1" disabled={@read_only} />
        </div>
      <% end %>
      <%= if @element["type"] != "text" do %>
        <div class="grid grid-cols-2 gap-2">
          <.input
            field={@form[:fill]}
            type="select"
            label="Background"
            options={Diogramos.Themes.color_tokens()}
            disabled={@read_only}
          />
          <.input
            field={@form[:stroke]}
            type="select"
            label="Border"
            options={Diogramos.Themes.color_tokens()}
            disabled={@read_only}
          />
        </div>
        <div class="grid grid-cols-2 gap-2">
          <.input
            field={@form[:dash]}
            type="select"
            label="Border style"
            options={["solid", "dotted", "dashed", "dash-dot"]}
            disabled={@read_only}
          />
          <.input
            field={@form[:stroke_width]}
            type="number"
            label="Border width"
            step="0.5"
            min="0.5"
            disabled={@read_only}
          />
        </div>
        <.input field={@form[:shadow]} type="checkbox" label="Shadow" disabled={@read_only} />
        <div class="grid grid-cols-2 gap-2">
          <.input
            field={@form[:label_position]}
            type="select"
            label="Label position"
            options={[
              {"Top left", "tl"},
              {"Top center", "tc"},
              {"Top right", "tr"},
              {"Middle left", "ml"},
              {"Center", "center"},
              {"Middle right", "mr"},
              {"Bottom left", "bl"},
              {"Bottom center", "bc"},
              {"Bottom right", "br"}
            ]}
            disabled={@read_only}
          />
          <.input
            field={@form[:label_size]}
            type="select"
            label="Label size"
            options={[{"Small", "sm"}, {"Medium", "md"}, {"Large", "lg"}, {"X-large", "xl"}]}
            disabled={@read_only}
          />
        </div>
        <div class="grid grid-cols-2 gap-2">
          <.input
            field={@form[:label_color]}
            type="select"
            label="Label color"
            options={Diogramos.Themes.color_tokens()}
            disabled={@read_only}
          />
          <.input
            field={@form[:label_font_family]}
            type="select"
            label="Label font"
            options={[
              {"Sans-serif", "sans"},
              {"Serif", "serif"},
              {"Monospace", "mono"},
              {"B612", "b612"},
              {"B612 Mono", "b612-mono"}
            ]}
            disabled={@read_only}
          />
        </div>
        <div class="grid grid-cols-2 gap-2">
          <.input
            field={@form[:label_bold]}
            type="checkbox"
            label="Bold label"
            disabled={@read_only}
          />
          <.input
            field={@form[:label_italic]}
            type="checkbox"
            label="Italic label"
            disabled={@read_only}
          />
        </div>
      <% else %>
        <.input
          field={@form[:fill]}
          type="select"
          label="Color"
          options={Diogramos.Themes.color_tokens()}
          disabled={@read_only}
        />
        <.input
          field={@form[:font_family]}
          type="select"
          label="Font"
          options={[
            {"Sans-serif", "sans"},
            {"Serif", "serif"},
            {"Monospace", "mono"},
            {"B612", "b612"},
            {"B612 Mono", "b612-mono"}
          ]}
          disabled={@read_only}
        />
        <.input
          field={@form[:font_size]}
          type="number"
          label="Size (px)"
          min="4"
          max="256"
          step="1"
          disabled={@read_only}
        />
        <div class="grid grid-cols-2 gap-2">
          <.input field={@form[:font_bold]} type="checkbox" label="Bold" disabled={@read_only} />
          <.input field={@form[:font_italic]} type="checkbox" label="Italic" disabled={@read_only} />
        </div>
      <% end %>

      <fieldset class="border-t border-base-300 pt-2 mt-2 flex flex-col gap-2">
        <legend class="font-mono text-[10px] uppercase tracking-wider text-accent px-1 flex items-center gap-2">
          <span>Links</span>
          <button
            type="button"
            phx-click="add_link"
            phx-value-element_id={@id}
            class="btn btn-ghost btn-xs"
            disabled={@read_only}
            title="Add another link"
          >
            <.icon name="hero-plus-micro" class="size-3" /> Add
          </button>
        </legend>
        <%= for {link, idx} <- Enum.with_index(Map.get(@form.params, "links", [])) do %>
          <.link_form_row
            link={link}
            index={idx}
            element_id={@id}
            read_only={@read_only}
          />
        <% end %>
      </fieldset>
    </.form>
    """
  end

  defp property_panel(%{selection: [{:connector, _id}], connector: nil} = assigns) do
    ~H"""
    <p class="text-sm opacity-70">Selected connector no longer exists.</p>
    """
  end

  defp property_panel(%{selection: [{:connector, id}], connector: connector} = assigns) do
    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:form, to_form(connector_form_params(connector), as: :props))

    ~H"""
    <div class="flex items-center justify-between mb-2">
      <span class="font-mono text-xs">connector</span>
      <button
        type="button"
        phx-click="delete_selected"
        class="btn btn-ghost btn-xs text-error"
        disabled={@read_only}
      >
        <.icon name="hero-trash-micro" class="size-4" />
      </button>
    </div>
    <.form
      for={@form}
      id={"con-form-" <> @id}
      phx-change="update_selected"
      phx-submit="update_selected"
      class="flex flex-col gap-2"
    >
      <.input field={@form[:label]} type="text" label="Label" disabled={@read_only} />
      <.input
        field={@form[:routing]}
        type="select"
        label="Routing"
        options={["straight", "orthogonal", "curve"]}
        disabled={@read_only}
      />
      <.input
        field={@form[:dash]}
        type="select"
        label="Tick pattern"
        options={["solid", "dotted", "dashed", "dash-dot"]}
        disabled={@read_only}
      />
      <.input
        field={@form[:color]}
        type="select"
        label="Color"
        options={Diogramos.Themes.color_tokens()}
        disabled={@read_only}
      />
      <div class="grid grid-cols-2 gap-2">
        <.input
          field={@form[:marker_start]}
          type="select"
          label="Start"
          options={["none", "arrow", "filled-arrow", "diamond", "circle"]}
          disabled={@read_only}
        />
        <.input
          field={@form[:marker_end]}
          type="select"
          label="End"
          options={["none", "arrow", "filled-arrow", "diamond", "circle"]}
          disabled={@read_only}
        />
      </div>
      <div class="grid grid-cols-3 gap-2">
        <.input
          field={@form[:start_gap]}
          type="number"
          label="Start gap"
          step="0.5"
          min="0"
          disabled={@read_only}
        />
        <.input
          field={@form[:end_gap]}
          type="number"
          label="End gap"
          step="0.5"
          min="0"
          disabled={@read_only}
        />
        <.input
          field={@form[:stroke_width]}
          type="number"
          label="Width"
          step="0.5"
          min="0.5"
          disabled={@read_only}
        />
      </div>
    </.form>
    """
  end

  defp element_form_params(%{"type" => "circle"} = e) do
    %{
      "label" => e["label"] || "",
      "cx" => e["cx"],
      "cy" => e["cy"],
      "r" => e["r"]
    }
    |> with_style_fields(e)
  end

  defp element_form_params(e) do
    %{
      "label" => e["label"] || "",
      "x" => e["x"],
      "y" => e["y"],
      "w" => e["w"],
      "h" => e["h"]
    }
    |> with_style_fields(e)
  end

  defp with_style_fields(params, %{"type" => "text"} = e) do
    params
    |> Map.put("fill", get_in(e, ["style", "fill"]) || "base-content")
    |> Map.put("font_family", get_in(e, ["style", "font_family"]) || "sans")
    |> Map.put("font_size", get_in(e, ["style", "font_size"]) || 14)
    |> Map.put("font_bold", get_in(e, ["style", "font_bold"]) == true)
    |> Map.put("font_italic", get_in(e, ["style", "font_italic"]) == true)
    |> with_link_fields(e)
  end

  defp with_style_fields(params, e) do
    params
    |> Map.put("fill", get_in(e, ["style", "fill"]) || "base-200")
    |> Map.put("stroke", get_in(e, ["style", "stroke"]) || "base-content")
    |> Map.put("dash", get_in(e, ["style", "dash"]) || "solid")
    |> Map.put("stroke_width", get_in(e, ["style", "stroke_width"]) || 1.5)
    |> Map.put("shadow", get_in(e, ["style", "shadow"]) == true)
    |> Map.put(
      "label_position",
      get_in(e, ["style", "label_position"]) ||
        if(e["type"] == "circle", do: "center", else: "tl")
    )
    |> Map.put("label_size", get_in(e, ["style", "label_size"]) || "md")
    |> Map.put("label_color", get_in(e, ["style", "label_color"]) || "base-content")
    |> Map.put("label_font_family", get_in(e, ["style", "label_font_family"]) || "sans")
    |> Map.put("label_bold", get_in(e, ["style", "label_bold"]) == true)
    |> Map.put("label_italic", get_in(e, ["style", "label_italic"]) == true)
    |> with_link_fields(e)
  end

  defp with_link_fields(params, e) do
    links =
      case e["links"] do
        list when is_list(list) -> list
        _ -> []
      end

    Map.put(
      params,
      "links",
      Enum.map(links, fn link ->
        %{
          "enabled" => link["enabled"] == true,
          "kind" => link["kind"] || "external",
          "target" => link["target"] || "",
          "icon" => link["icon"] || "link"
        }
      end)
    )
  end

  defp connector_form_params(c) do
    %{
      "label" => c["label"] || "",
      "routing" => c["routing"] || "orthogonal",
      "dash" => c["dash"] || "solid",
      "marker_start" => c["marker_start"] || "none",
      "marker_end" => c["marker_end"] || "arrow",
      "start_gap" => c["start_gap"] || 6,
      "end_gap" => c["end_gap"] || 6,
      "stroke_width" => c["stroke_width"] || 2,
      "color" => c["color"] || "base-content"
    }
  end

  defp style_clipboard_compatible?(nil, _), do: false
  defp style_clipboard_compatible?(_, nil), do: false
  defp style_clipboard_compatible?({:element, _}, {:element, _}), do: true
  defp style_clipboard_compatible?({:connector, _}, {:connector, _}), do: true
  defp style_clipboard_compatible?(_, _), do: false

  attr :link, :map, required: true
  attr :index, :integer, required: true
  attr :element_id, :string, required: true
  attr :read_only, :boolean, default: false

  defp link_form_row(assigns) do
    base = "props[links][#{assigns.index}]"

    assigns =
      assigns
      |> assign(:base, base)
      |> assign(:icon_options, [
        {"Link", "link"},
        {"Open in new tab", "arrow-top-right-on-square"},
        {"Document", "document-text"},
        {"Bookmark", "bookmark"},
        {"Globe", "globe-alt"},
        {"Info", "information-circle"}
      ])
      |> assign(:kind_options, [{"External URL", "external"}, {"Canvas slug", "canvas"}])

    ~H"""
    <div class="border border-base-300 rounded-box p-2 flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="font-mono text-[10px] opacity-60">link {@index + 1}</span>
        <button
          type="button"
          phx-click="remove_link"
          phx-value-element_id={@element_id}
          phx-value-index={@index}
          class="btn btn-ghost btn-xs text-error"
          disabled={@read_only}
          title="Remove link"
        >
          <.icon name="hero-x-mark-micro" class="size-3" />
        </button>
      </div>

      <label class="flex items-center gap-2 text-sm">
        <input type="hidden" name={@base <> "[enabled]"} value="false" />
        <input
          type="checkbox"
          name={@base <> "[enabled]"}
          value="true"
          checked={@link["enabled"] == true}
          disabled={@read_only}
          class="checkbox checkbox-xs"
        /> Show icon
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span class="opacity-70">Kind</span>
        <select
          name={@base <> "[kind]"}
          disabled={@read_only}
          class="select select-bordered select-sm"
        >
          <option
            :for={{label, value} <- @kind_options}
            value={value}
            selected={@link["kind"] == value}
          >{label}</option>
        </select>
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span class="opacity-70">Target</span>
        <input
          type="text"
          name={@base <> "[target]"}
          value={@link["target"] || ""}
          placeholder="https://… or canvas-slug"
          disabled={@read_only}
          class="input input-bordered input-sm"
        />
      </label>

      <label class="flex flex-col gap-1 text-xs">
        <span class="opacity-70">Icon</span>
        <select
          name={@base <> "[icon]"}
          disabled={@read_only}
          class="select select-bordered select-sm"
        >
          <option
            :for={{label, value} <- @icon_options}
            value={value}
            selected={@link["icon"] == value}
          >{label}</option>
        </select>
      </label>
    </div>
    """
  end

  attr :clipboard, :any, default: nil

  defp style_clipboard_preview(%{clipboard: nil} = assigns) do
    ~H"""
    <div
      id="clipboard-preview"
      class="text-xs opacity-50 mb-3 italic"
    >
      Clipboard empty. Copy a style to apply it to new shapes.
    </div>
    """
  end

  defp style_clipboard_preview(%{clipboard: {:element, style}} = assigns) do
    assigns = assign(assigns, :style, style)

    ~H"""
    <div
      id="clipboard-preview"
      class="flex items-center gap-2 text-xs mb-3 px-2 py-1 rounded border border-base-300 bg-base-100"
    >
      <span class="opacity-60">clipboard</span>
      <span class="flex items-center gap-1">
        <span
          class="size-3 rounded border border-base-content/20 bg-transparent bg-[repeating-linear-gradient(45deg,_var(--color-base-content)_0_2px,_transparent_2px_4px)]"
          style={"background: " <> token_var(Map.get(@style, "fill", "base-200"))}
          title={"fill: " <> Map.get(@style, "fill", "base-200")}
        />
        <span
          class="size-3 rounded border-2"
          style={"border-color: " <> token_var(Map.get(@style, "stroke", "base-content"))}
          title={"border: " <> Map.get(@style, "stroke", "base-content")}
        />
      </span>
      <%= if @style["shadow"] do %>
        <.icon name="hero-cube-transparent-micro" class="size-3 text-accent" />
      <% end %>
      <span class="ml-auto opacity-50 font-mono">element</span>
    </div>
    """
  end

  defp style_clipboard_preview(%{clipboard: {:connector, style}} = assigns) do
    assigns = assign(assigns, :style, style)

    ~H"""
    <div
      id="clipboard-preview"
      class="flex items-center gap-2 text-xs mb-3 px-2 py-1 rounded border border-base-300 bg-base-100"
    >
      <span class="opacity-60">clipboard</span>
      <svg width="44" height="10" viewBox="0 0 44 10" class="overflow-visible">
        <line
          x1="0"
          y1="5"
          x2="44"
          y2="5"
          stroke-width={Map.get(@style, "stroke_width", 2)}
          stroke-dasharray={dash_preview(Map.get(@style, "dash", "solid"))}
          style={"stroke: " <> token_var(Map.get(@style, "color", "base-content"))}
        />
      </svg>
      <span class="ml-auto opacity-50 font-mono">{@style["routing"] || "orthogonal"}</span>
    </div>
    """
  end

  defp dash_preview("solid"), do: nil
  defp dash_preview("dotted"), do: "2 4"
  defp dash_preview("dashed"), do: "8 6"
  defp dash_preview("dash-dot"), do: "8 4 2 4"
  defp dash_preview(_), do: nil
end

defmodule DiogramosWeb.CanvasLive.Embed do
  use DiogramosWeb, :live_view

  alias Diogramos.Diagrams
  alias Diogramos.Diagrams.{Authority, ConnectorGeometry, Document}
  alias DiogramosWeb.CanvasPresence

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Diagrams.get_canvas_for_embed(token) do
      nil ->
        {:ok,
         socket
         |> assign(:canvas, nil)
         |> assign(:document, Document.new())
         |> assign(:not_found, true)
         |> assign(:page_title, "Canvas not found")}

      canvas ->
        {document, version} =
          case Authority.snapshot(canvas.id) do
            {:ok, %{document: d, version: v}} -> {d, v}
            _ -> {normalize(canvas.document), canvas.version}
          end

        topic = Authority.topic(canvas.id)

        identity = %{
          key: "embed-" <> Diogramos.ULID.generate(),
          name: CanvasPresence.random_animal_name(),
          color: CanvasPresence.random_color(),
          source: "embed"
        }

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Diogramos.PubSub, topic)

          if canvas.embed_show_cursors do
            CanvasPresence.track(self(), topic, identity)
          end
        end

        {:ok,
         socket
         |> assign(:canvas, canvas)
         |> assign(:document, document)
         |> assign(:version, version)
         |> assign(:not_found, false)
         |> assign(:page_title, canvas.title)
         |> assign(:topic, topic)
         |> assign(:peers, [])
         |> assign(:identity, identity)}
    end
  end


  @impl true
  def handle_info({:canvas_op, %{op: op, version: version}}, socket) do
    cond do
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
    if socket.assigns[:canvas] && socket.assigns.canvas.embed_show_cursors do
      peers = CanvasPresence.list_peers(socket.assigns.topic, socket.assigns.identity.key)
      {:noreply, assign(socket, :peers, peers)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("embed_identity", %{"name" => name, "color" => color}, socket) do
    {:noreply, apply_identity(socket, name, color, persist: false)}
  end

  def handle_event("save_identity", %{"identity" => params}, socket) do
    name = (params["name"] || "") |> String.trim() |> String.slice(0, 40)
    name = if name == "", do: "Guest", else: name

    color =
      if params["color"] in DiogramosWeb.CanvasPresence.palette(),
        do: params["color"],
        else: socket.assigns.identity.color

    {:noreply, apply_identity(socket, name, color, persist: true)}
  end

  def handle_event("cursor", %{"x" => x, "y" => y}, socket) when is_number(x) and is_number(y) do
    if socket.assigns.canvas && socket.assigns.canvas.embed_show_cursors do
      CanvasPresence.update(self(), socket.assigns.topic, socket.assigns.identity.key, fn meta ->
        Map.put(meta, :cursor, %{x: x, y: y})
      end)
    end

    {:noreply, socket}
  end

  def handle_event("cursor", _, socket), do: {:noreply, socket}

  defp apply_identity(socket, name, color, opts) do
    identity = %{socket.assigns.identity | name: name, color: color}

    if socket.assigns.canvas && socket.assigns.canvas.embed_show_cursors do
      CanvasPresence.update(self(), socket.assigns.topic, identity.key, fn meta ->
        meta |> Map.put(:name, name) |> Map.put(:color, color)
      end)
    end

    socket = assign(socket, :identity, identity)

    if Keyword.get(opts, :persist, false) do
      push_event(socket, "store_embed_identity", %{name: name, color: color})
    else
      socket
    end
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-100 text-base-content">
      <p class="text-sm opacity-70">This canvas is not available.</p>
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:rendered_connectors, render_connectors(assigns.document))
      |> assign(:palette, DiogramosWeb.CanvasPresence.palette())

    ~H"""
    <div
      id="embed-root"
      data-theme={@canvas.theme}
      class="min-h-screen w-screen bg-base-100 text-base-content relative"
    >
      <svg
        id="embed-svg"
        phx-hook=".EmbedViewport"
        data-cursors={to_string(@canvas.embed_show_cursors)}
        class="w-screen h-screen select-none"
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

        <g id="embed-viewport">
          <g :for={id <- @document["order"]} id={"el-" <> id}>
            <.embed_element_node element={@document["elements"][id]} />
            <.embed_link_overlay element={@document["elements"][id]} />
          </g>

          <g
            :for={{cid, connector, render} <- @rendered_connectors}
            id={"con-" <> cid}
          >
            <path
              d={render.d}
              fill="none"
              style={"stroke: #{DiogramosWeb.CanvasLive.Edit.token_var(connector["color"] || "base-content")}; color: #{DiogramosWeb.CanvasLive.Edit.token_var(connector["color"] || "base-content")};"}
              stroke-width={render.stroke_width}
              stroke-dasharray={render.dash_array}
              marker-start={marker_id(render.marker_start)}
              marker-end={marker_id(render.marker_end)}
            />
          </g>

          <%= if @canvas.embed_show_cursors do %>
            <g id="embed-cursors" class="pointer-events-none">
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
          <% end %>
        </g>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".EmbedViewport">
          const CURSOR_THROTTLE_MS = 33

          export default {
            mounted() {
              this.scale = 1
              this.tx = 0
              this.ty = 0
              this.viewport = this.el.querySelector("#embed-viewport")
              this.lastCursorAt = 0
              this.scheduleFit()

              this.onResize = () => this.scheduleFit()
              this.onPointerMove = (e) => this.onCursorMove(e)
              window.addEventListener("resize", this.onResize)

              // Refit when the iframe / parent container resizes — covers the
              // common case where the SVG was 0 px tall during mount.
              if (typeof ResizeObserver !== "undefined") {
                this.resizeObserver = new ResizeObserver(() => this.scheduleFit())
                this.resizeObserver.observe(this.el)
              }

              if (this.el.dataset.cursors === "true") {
                this.el.addEventListener("pointermove", this.onPointerMove)

                // Restore + persist identity via localStorage so the same
                // visitor keeps their name/colour across embeds.
                this.identityKey = "dx-embed-identity"
                this.handleEvent("store_embed_identity", ({name, color}) => {
                  try { localStorage.setItem(this.identityKey, JSON.stringify({name, color})) } catch (_) {}
                })

                let stored = null
                try { stored = localStorage.getItem(this.identityKey) } catch (_) {}
                if (stored) {
                  try {
                    const parsed = JSON.parse(stored)
                    if (parsed && parsed.name && parsed.color) {
                      this.pushEvent("embed_identity", { name: parsed.name, color: parsed.color })
                    }
                  } catch (_) {}
                }
              }
            },
            destroyed() {
              window.removeEventListener("resize", this.onResize)
              this.el.removeEventListener("pointermove", this.onPointerMove)
              this.resizeObserver && this.resizeObserver.disconnect()
            },
            updated() {
              // Re-fit on document changes pushed via PubSub (new shape inserted,
              // resize, etc) so the camera tracks the diagram's current bbox.
              this.scheduleFit()
            },
            scheduleFit() {
              if (this.fitScheduled) return
              this.fitScheduled = true
              requestAnimationFrame(() => {
                this.fitScheduled = false
                this.fit()
              })
            },
            onCursorMove(e) {
              const now = performance.now()
              if (now - this.lastCursorAt < CURSOR_THROTTLE_MS) return
              this.lastCursorAt = now
              const rect = this.el.getBoundingClientRect()
              const x = (e.clientX - rect.left - this.tx) / this.scale
              const y = (e.clientY - rect.top - this.ty) / this.scale
              this.pushEvent("cursor", { x, y })
            },
            fit() {
              try {
                const bbox = this.viewport.getBBox()
                if (bbox.width === 0 || bbox.height === 0) return
                const rect = this.el.getBoundingClientRect()
                const margin = 24
                const sx = (rect.width - margin * 2) / bbox.width
                const sy = (rect.height - margin * 2) / bbox.height
                this.scale = Math.min(1, Math.min(sx, sy))
                this.tx = -bbox.x * this.scale + (rect.width - bbox.width * this.scale) / 2
                this.ty = -bbox.y * this.scale + (rect.height - bbox.height * this.scale) / 2
                this.viewport.setAttribute(
                  "transform",
                  `translate(${this.tx} ${this.ty}) scale(${this.scale})`
                )
              } catch (_) {}
            }
          }
        </script>
      </svg>

      <%= if @canvas.embed_show_cursors do %>
        <details
          id="embed-identity"
          class="dropdown dropdown-top dropdown-end absolute bottom-3 right-3 z-10"
        >
          <summary class="btn btn-sm bg-base-200 border border-base-300 normal-case">
            <span class="size-3 rounded-full" style={"background: #{@identity.color}"} />
            <span class="font-mono text-xs">{@identity.name}</span>
          </summary>
          <div class="dropdown-content bg-base-200 border border-base-300 rounded-box mt-1 p-3 w-64 shadow-lg">
            <.form
              for={%{}}
              as={:identity}
              id="embed-identity-form"
              phx-submit="save_identity"
              class="flex flex-col gap-2"
            >
              <label class="flex flex-col gap-1 text-xs">
                <span class="opacity-70">Display name</span>
                <input
                  type="text"
                  name="identity[name]"
                  value={@identity.name}
                  maxlength="40"
                  class="input input-bordered input-sm"
                  autocomplete="off"
                />
              </label>
              <div class="text-xs">
                <span class="opacity-70">Cursor color</span>
                <div class="flex gap-1 mt-1">
                  <%= for color <- @palette do %>
                    <label class="cursor-pointer">
                      <input
                        type="radio"
                        name="identity[color]"
                        value={color}
                        checked={color == @identity.color}
                        class="sr-only peer"
                      />
                      <span
                        class="block size-5 rounded-full border-2 border-transparent peer-checked:border-base-content/60"
                        style={"background: #{color}"}
                      />
                    </label>
                  <% end %>
                </div>
              </div>
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
            </.form>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  attr :element, :map, required: true

  defp embed_shape_label(%{element: element} = assigns) do
    if (element["label"] || "") == "" do
      ~H""
    else
      assigns =
        assigns
        |> assign(:geom, DiogramosWeb.CanvasLive.Edit.label_geom(element))
        |> assign(:text_style, DiogramosWeb.CanvasLive.Edit.shape_label_style(element))

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

  attr :element, :map, required: true

  defp embed_link_overlay(%{element: element} = assigns) do
    enabled = DiogramosWeb.CanvasLive.Edit.enabled_links(element)

    if enabled == [] do
      ~H""
    else
      assigns =
        assign(
          assigns,
          :placements,
          DiogramosWeb.CanvasLive.Edit.link_placements(element, enabled)
        )

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

  attr :element, :map, required: true

  defp embed_element_node(%{element: %{"type" => "rect"}} = assigns) do
    ~H"""
    <%= if DiogramosWeb.CanvasLive.Edit.shadow?(@element) do %>
      <rect
        x={@element["x"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        y={@element["y"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        width={@element["w"]}
        height={@element["h"]}
        style={DiogramosWeb.CanvasLive.Edit.shadow_style(@element)}
      />
    <% end %>
    <rect
      x={@element["x"]}
      y={@element["y"]}
      width={@element["w"]}
      height={@element["h"]}
      style={DiogramosWeb.CanvasLive.Edit.shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.embed_shape_label element={@element} />
    """
  end

  defp embed_element_node(%{element: %{"type" => "rounded"}} = assigns) do
    ~H"""
    <%= if DiogramosWeb.CanvasLive.Edit.shadow?(@element) do %>
      <rect
        x={@element["x"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        y={@element["y"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        width={@element["w"]}
        height={@element["h"]}
        rx="8"
        ry="8"
        style={DiogramosWeb.CanvasLive.Edit.shadow_style(@element)}
      />
    <% end %>
    <rect
      x={@element["x"]}
      y={@element["y"]}
      width={@element["w"]}
      height={@element["h"]}
      rx="8"
      ry="8"
      style={DiogramosWeb.CanvasLive.Edit.shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.embed_shape_label element={@element} />
    """
  end

  defp embed_element_node(%{element: %{"type" => "circle"}} = assigns) do
    ~H"""
    <%= if DiogramosWeb.CanvasLive.Edit.shadow?(@element) do %>
      <circle
        cx={@element["cx"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        cy={@element["cy"] + DiogramosWeb.CanvasLive.Edit.shadow_offset()}
        r={@element["r"]}
        style={DiogramosWeb.CanvasLive.Edit.shadow_style(@element)}
      />
    <% end %>
    <circle
      cx={@element["cx"]}
      cy={@element["cy"]}
      r={@element["r"]}
      style={DiogramosWeb.CanvasLive.Edit.shape_style(@element)}
      pointer-events="visiblePainted"
    />
    <.embed_shape_label element={@element} />
    """
  end

  defp embed_element_node(%{element: %{"type" => "text"}} = assigns) do
    ~H"""
    <text
      x={@element["x"]}
      y={@element["y"] + DiogramosWeb.CanvasLive.Edit.text_baseline(@element)}
      style={DiogramosWeb.CanvasLive.Edit.text_element_style(@element)}
    >
      {@element["label"]}
    </text>
    """
  end

  defp render_connectors(document) do
    document["connectors"]
    |> Enum.map(fn {id, c} -> {id, c, ConnectorGeometry.render(c, document)} end)
    |> Enum.reject(fn {_, _, r} -> is_nil(r) end)
  end

  defp marker_id("none"), do: ""
  defp marker_id(name), do: "url(#dx-marker-#{name})"

  defp normalize(nil), do: Document.new()
  defp normalize(%{"elements" => _, "order" => _, "connectors" => _} = doc), do: doc

  defp normalize(other) when is_map(other) do
    %{
      "elements" => Map.get(other, "elements", %{}),
      "order" => Map.get(other, "order", []),
      "connectors" => Map.get(other, "connectors", %{})
    }
  end
end

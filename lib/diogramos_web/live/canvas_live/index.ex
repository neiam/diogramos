defmodule DiogramosWeb.CanvasLive.Index do
  use DiogramosWeb, :live_view

  alias Diogramos.Diagrams
  alias Diogramos.Diagrams.{Canvas, Folder}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Your canvases")
     |> assign(:selected_folder_id, nil)
     |> assign(:new_canvas_form, build_canvas_form())
     |> assign(:new_folder_form, build_folder_form())
     |> assign(:show_canvas_modal, false)
     |> assign(:show_folder_modal, false)
     |> assign(:show_import_modal, false)
     |> assign(:import_error, nil)
     |> assign(:manage_canvas, nil)
     |> assign(:manage_grants, [])
     |> assign(:manage_error, nil)
     |> allow_upload(:canvas_import,
       accept: ~w(.json application/json),
       max_entries: 1,
       max_file_size: 5_000_000
     )
     |> stream(:canvases, Diagrams.list_canvases(scope))
     |> stream(:folders, Diagrams.list_folders(scope))}
  end

  @impl true
  def handle_event("filter_folder", %{"folder_id" => "all"}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:selected_folder_id, nil)
     |> stream(:canvases, Diagrams.list_canvases(scope), reset: true)}
  end

  def handle_event("filter_folder", %{"folder_id" => folder_id}, socket) do
    scope = socket.assigns.current_scope
    {id, _} = Integer.parse(folder_id)

    {:noreply,
     socket
     |> assign(:selected_folder_id, id)
     |> stream(:canvases, Diagrams.list_canvases_in_folder(scope, id), reset: true)}
  end

  def handle_event("toggle_canvas_modal", _, socket) do
    {:noreply, update(socket, :show_canvas_modal, &(!&1))}
  end

  def handle_event("toggle_folder_modal", _, socket) do
    {:noreply, update(socket, :show_folder_modal, &(!&1))}
  end

  def handle_event("create_canvas", %{"canvas" => params}, socket) do
    scope = socket.assigns.current_scope

    params =
      params
      |> Map.put_new("theme", "afterdark")
      |> with_selected_folder(socket.assigns.selected_folder_id)

    case Diagrams.create_canvas(scope, params) do
      {:ok, canvas} ->
        {:noreply,
         socket
         |> assign(:show_canvas_modal, false)
         |> assign(:new_canvas_form, build_canvas_form())
         |> stream_insert(:canvases, canvas, at: 0)
         |> push_navigate(to: ~p"/c/#{canvas.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_canvas_form, to_form(changeset, as: :canvas))}
    end
  end

  def handle_event("toggle_import_modal", _, socket) do
    {:noreply, socket |> update(:show_import_modal, &(!&1)) |> assign(:import_error, nil)}
  end

  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("submit_import", _, socket) do
    scope = socket.assigns.current_scope

    case consume_uploaded_entries(socket, :canvas_import, fn %{path: path}, _entry ->
           with {:ok, raw} <- File.read(path),
                {:ok, data} <- Jason.decode(raw),
                {:ok, canvas} <- Diagrams.import_canvas(scope, data) do
             {:ok, canvas}
           else
             {:error, _} = err -> {:postpone, err}
           end
         end) do
      [%Diogramos.Diagrams.Canvas{} = canvas] ->
        {:noreply,
         socket
         |> assign(:show_import_modal, false)
         |> stream_insert(:canvases, canvas, at: 0)
         |> push_navigate(to: ~p"/c/#{canvas.slug}")}

      [{:error, %Ecto.Changeset{} = changeset}] ->
        {:noreply,
         assign(socket, :import_error, "Could not import: #{inspect(changeset.errors)}")}

      [{:error, :invalid_format}] ->
        {:noreply,
         assign(
           socket,
           :import_error,
           "That file isn't a Diogramos canvas export."
         )}

      [{:error, %Jason.DecodeError{}}] ->
        {:noreply, assign(socket, :import_error, "That file isn't valid JSON.")}

      _ ->
        {:noreply, assign(socket, :import_error, "Could not read upload.")}
    end
  end

  def handle_event("open_manage_modal", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {canvas_id, _} = Integer.parse(id)
    canvas = Diagrams.get_canvas!(scope, canvas_id)

    if canvas.owner_id == scope.user.id do
      {:noreply,
       socket
       |> assign(:manage_canvas, canvas)
       |> assign(:manage_grants, Diagrams.list_user_grants("canvas", canvas.id))
       |> assign(:manage_error, nil)}
    else
      {:noreply, put_flash(socket, :error, "Only the owner can manage collaborators.")}
    end
  end

  def handle_event("close_manage_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:manage_canvas, nil)
     |> assign(:manage_grants, [])
     |> assign(:manage_error, nil)}
  end

  def handle_event("grant_user", %{"email" => email, "role" => role}, socket)
      when role in ["viewer", "editor"] do
    canvas = socket.assigns.manage_canvas
    scope = socket.assigns.current_scope
    email = email |> to_string() |> String.trim()

    cond do
      canvas == nil ->
        {:noreply, socket}

      email == "" ->
        {:noreply, assign(socket, :manage_error, "Enter an email address.")}

      true ->
        case Diogramos.Accounts.get_user_by_email(email) do
          nil ->
            {:noreply, assign(socket, :manage_error, "No registered user with that email.")}

          user when user.id == canvas.owner_id ->
            {:noreply, assign(socket, :manage_error, "The owner already has access.")}

          user ->
            {:ok, _} =
              Diagrams.grant_permission(
                "canvas",
                canvas.id,
                "user",
                user.id,
                role,
                granted_by_id: scope.user.id
              )

            {:noreply,
             socket
             |> assign(:manage_grants, Diagrams.list_user_grants("canvas", canvas.id))
             |> assign(:manage_error, nil)}
        end
    end
  end

  def handle_event("update_canvas_theme", %{"theme" => theme}, socket) do
    canvas = socket.assigns.manage_canvas
    scope = socket.assigns.current_scope

    if canvas == nil do
      {:noreply, socket}
    else
      case Diagrams.update_canvas_metadata(scope, canvas, %{
             "title" => canvas.title,
             "theme" => theme
           }) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:manage_canvas, updated)
           |> stream_insert(:canvases, updated)
           |> put_flash(:info, "Theme updated.")}

        {:error, _} ->
          {:noreply, assign(socket, :manage_error, "Could not update theme.")}
      end
    end
  end

  def handle_event("revoke_user", %{"user_id" => user_id}, socket) do
    canvas = socket.assigns.manage_canvas
    {uid, _} = Integer.parse(user_id)

    if canvas do
      Diagrams.revoke_permission("canvas", canvas.id, "user", uid)

      {:noreply,
       assign(socket, :manage_grants, Diagrams.list_user_grants("canvas", canvas.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_folder", %{"folder" => params}, socket) do
    scope = socket.assigns.current_scope

    case Diagrams.create_folder(scope, params) do
      {:ok, folder} ->
        {:noreply,
         socket
         |> assign(:show_folder_modal, false)
         |> assign(:new_folder_form, build_folder_form())
         |> stream_insert(:folders, folder, at: 0)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_folder_form, to_form(changeset, as: :folder))}
    end
  end

  defp build_canvas_form do
    %Canvas{}
    |> Canvas.create_changeset(%{})
    |> to_form(as: :canvas)
  end

  defp build_folder_form do
    %Folder{}
    |> Folder.changeset(%{})
    |> to_form(as: :folder)
  end

  defp with_selected_folder(params, nil), do: params
  defp with_selected_folder(params, id), do: Map.put_new(params, "folder_id", id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div
        class="grid grid-cols-[16rem_1fr] gap-8 px-6 lg:px-10 py-6 w-full"
        id="canvases-page"
      >
        <aside class="border border-base-300 rounded-box p-3 bg-base-200 h-fit">
          <div class="flex items-center justify-between mb-2">
            <h2 class="font-mono text-xs uppercase tracking-wide text-accent">Folders</h2>
            <button
              type="button"
              phx-click="toggle_folder_modal"
              class="btn btn-ghost btn-xs"
              aria-label="New folder"
              id="btn-new-folder"
            >
              <.icon name="hero-folder-plus-micro" class="size-4" />
            </button>
          </div>

          <ul class="menu menu-sm w-full p-0">
            <li>
              <button
                type="button"
                phx-click="filter_folder"
                phx-value-folder_id="all"
                class={[@selected_folder_id == nil && "menu-active"]}
              >
                <.icon name="hero-inbox-micro" class="size-4" /> All canvases
              </button>
            </li>
            <li :for={{dom_id, folder} <- @streams.folders} id={dom_id}>
              <button
                type="button"
                phx-click="filter_folder"
                phx-value-folder_id={folder.id}
                class={[@selected_folder_id == folder.id && "menu-active"]}
              >
                <.icon name="hero-folder-micro" class="size-4" />
                <span class="truncate">{folder.name}</span>
              </button>
            </li>
          </ul>
        </aside>

        <section>
          <header class="flex items-center justify-between mb-4">
            <h1 class="text-2xl font-bold">{@page_title}</h1>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="toggle_import_modal"
                class="btn btn-ghost btn-sm"
                id="btn-import-canvas"
              >
                <.icon name="hero-arrow-up-tray-micro" class="size-4" /> Import
              </button>
              <button
                type="button"
                phx-click="toggle_canvas_modal"
                class="btn btn-primary btn-sm"
                id="btn-new-canvas"
              >
                <.icon name="hero-plus-micro" class="size-4" /> New canvas
              </button>
            </div>
          </header>

          <ul
            id="canvases"
            phx-update="stream"
            class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4 gap-5"
          >
            <li
              id="canvases-empty"
              class="hidden only:block col-span-full text-center text-base-content/60 py-8"
            >
              No canvases yet. Click <em class="not-italic font-semibold">New canvas</em>
              to create your first one.
            </li>

            <li
              :for={{dom_id, canvas} <- @streams.canvases}
              id={dom_id}
              data-theme={canvas.theme}
              class="border border-base-300 rounded-box bg-base-200 text-base-content overflow-hidden flex flex-col hover:shadow-xl transition min-h-[12rem]"
            >
              <.link
                navigate={~p"/c/#{canvas.slug}"}
                class="flex-1 flex flex-col p-5 gap-1 bg-base-100 hover:bg-base-300 transition"
              >
                <span class="text-lg font-semibold truncate">{canvas.title}</span>
                <span class="text-sm font-mono text-accent truncate">{canvas.slug}</span>
                <span class="mt-auto text-xs text-base-content/60 pt-2">
                  v{canvas.version} · {Calendar.strftime(canvas.updated_at, "%Y-%m-%d")}
                </span>
              </.link>
              <div class="px-4 py-2 flex items-center justify-end gap-1 bg-base-200 border-t border-base-300">
                <%= if canvas.owner_id == @current_scope.user.id do %>
                  <button
                    type="button"
                    phx-click="open_manage_modal"
                    phx-value-id={canvas.id}
                    class="btn btn-ghost btn-xs"
                    title="Manage collaborators"
                  >
                    <.icon name="hero-user-group-micro" class="size-4" /> Manage
                  </button>
                <% end %>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <%= if @show_canvas_modal do %>
        <div
          class="modal modal-open"
          id="new-canvas-modal"
          phx-window-keydown="toggle_canvas_modal"
          phx-key="escape"
        >
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">New canvas</h3>
            <.form
              for={@new_canvas_form}
              id="new-canvas-form"
              phx-submit="create_canvas"
              class="flex flex-col gap-3"
            >
              <.input field={@new_canvas_form[:title]} type="text" label="Title" required />
              <.input
                field={@new_canvas_form[:slug]}
                type="text"
                label="Slug"
                placeholder="my-canvas"
                required
              />
              <.input
                field={@new_canvas_form[:theme]}
                type="select"
                label="Theme"
                options={Diogramos.Themes.all()}
              />
              <div class="modal-action">
                <button type="button" phx-click="toggle_canvas_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Create</button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <%= if @show_folder_modal do %>
        <div
          class="modal modal-open"
          id="new-folder-modal"
          phx-window-keydown="toggle_folder_modal"
          phx-key="escape"
        >
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">New folder</h3>
            <.form
              for={@new_folder_form}
              id="new-folder-form"
              phx-submit="create_folder"
              class="flex flex-col gap-3"
            >
              <.input field={@new_folder_form[:name]} type="text" label="Name" required />
              <div class="modal-action">
                <button type="button" phx-click="toggle_folder_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Create</button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <%= if @show_import_modal do %>
        <div
          class="modal modal-open"
          id="import-canvas-modal"
          phx-window-keydown="toggle_import_modal"
          phx-key="escape"
        >
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-2">Import canvas</h3>
            <p class="text-sm opacity-70 mb-3">
              Upload a JSON file previously exported from another canvas.
            </p>

            <form id="import-canvas-form" phx-change="validate_import" phx-submit="submit_import">
              <.live_file_input upload={@uploads.canvas_import} class="file-input file-input-bordered w-full" />

              <div :for={entry <- @uploads.canvas_import.entries} class="text-xs mt-2">
                <span class="font-mono">{entry.client_name}</span>
                <progress value={entry.progress} max="100" class="w-full" />
                <p :for={err <- upload_errors(@uploads.canvas_import, entry)} class="text-error">
                  {error_to_string(err)}
                </p>
              </div>

              <p :if={@import_error} class="text-error text-sm mt-2">{@import_error}</p>

              <div class="modal-action">
                <button type="button" phx-click="toggle_import_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button
                  type="submit"
                  class="btn btn-primary"
                  disabled={@uploads.canvas_import.entries == []}
                >
                  Import
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%= if @manage_canvas do %>
        <div
          class="modal modal-open"
          id="manage-canvas-modal"
          phx-window-keydown="close_manage_modal"
          phx-key="escape"
        >
          <div class="modal-box max-w-lg">
            <h3 class="font-bold text-lg mb-1">Manage collaborators</h3>
            <p class="text-sm opacity-70 mb-4">
              <span class="font-semibold">{@manage_canvas.title}</span>
              <span class="font-mono text-xs text-accent ml-2">{@manage_canvas.slug}</span>
            </p>

            <h4 class="font-mono text-xs uppercase tracking-wider text-accent mb-2">Theme</h4>
            <form phx-change="update_canvas_theme" class="mb-4">
              <div class="grid grid-cols-3 gap-2">
                <label
                  :for={theme <- Diogramos.Themes.all()}
                  data-theme={theme}
                  class={[
                    "border rounded-box p-3 cursor-pointer flex flex-col items-center gap-1 bg-base-100 text-base-content transition",
                    @manage_canvas.theme == theme && "ring-2 ring-accent border-accent",
                    @manage_canvas.theme != theme && "border-base-300 hover:border-base-content/40"
                  ]}
                >
                  <input
                    type="radio"
                    name="theme"
                    value={theme}
                    checked={@manage_canvas.theme == theme}
                    class="sr-only"
                  />
                  <div class="flex gap-1">
                    <span class="size-3 rounded-full bg-primary" />
                    <span class="size-3 rounded-full bg-secondary" />
                    <span class="size-3 rounded-full bg-accent" />
                  </div>
                  <span class="text-[10px] font-mono uppercase tracking-wider opacity-70">
                    {theme}
                  </span>
                </label>
              </div>
            </form>

            <h4 class="font-mono text-xs uppercase tracking-wider text-accent mb-2">People with access</h4>
            <ul class="flex flex-col gap-1 mb-4">
              <li class="flex items-center justify-between text-sm border border-base-300 rounded-box px-3 py-2 bg-base-100">
                <div class="min-w-0">
                  <span class="font-mono truncate">{@current_scope.user.email}</span>
                  <span class="text-xs opacity-60 block">you (owner)</span>
                </div>
                <span class="badge badge-accent">owner</span>
              </li>
              <li
                :for={grant <- @manage_grants}
                class="flex items-center justify-between text-sm border border-base-300 rounded-box px-3 py-2"
              >
                <div class="min-w-0">
                  <span class="font-mono truncate">{grant.user && grant.user.email || "Anonymous"}</span>
                  <span class="text-xs opacity-60 block">{grant.role}</span>
                </div>
                <button
                  type="button"
                  phx-click="revoke_user"
                  phx-value-user_id={grant.principal_id}
                  class="btn btn-ghost btn-xs text-error"
                  title="Revoke access"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
              </li>
            </ul>

            <h4 class="font-mono text-xs uppercase tracking-wider text-accent mb-2">Add collaborator</h4>
            <form phx-submit="grant_user" class="flex flex-col gap-2" id="manage-grant-form">
              <div class="flex gap-2">
                <input
                  type="email"
                  name="email"
                  placeholder="someone@example.com"
                  class="input input-bordered input-sm flex-1"
                  required
                />
                <select
                  name="role"
                  class="select select-bordered select-sm"
                >
                  <option value="viewer">Viewer</option>
                  <option value="editor" selected>Editor</option>
                </select>
                <button type="submit" class="btn btn-primary btn-sm">Add</button>
              </div>
              <%= if @manage_error do %>
                <p class="text-error text-xs">{@manage_error}</p>
              <% end %>
            </form>

            <div class="modal-action">
              <button type="button" phx-click="close_manage_modal" class="btn btn-ghost">Done</button>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp error_to_string(:too_large), do: "File is too large."
  defp error_to_string(:not_accepted), do: "File must be JSON."
  defp error_to_string(:too_many_files), do: "Only one file at a time."
  defp error_to_string(other), do: to_string(other)
end

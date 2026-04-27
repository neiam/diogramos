defmodule DiogramosWeb.UserLive.Invites do
  use DiogramosWeb, :live_view

  alias Diogramos.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    {:ok, socket |> assign(:page_title, "Invites") |> stream(:invites, Accounts.list_invites(user))}
  end

  @impl true
  def handle_event("create_invite", _, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.create_invite(user) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invite created — copy the link below.")
         |> stream_insert(:invites, with_redeemer(invite), at: 0)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create invite.")}
    end
  end

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.list_invites(user) |> Enum.find(&(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      invite ->
        case Accounts.revoke_invite(user, invite) do
          {:ok, revoked} ->
            {:noreply, stream_insert(socket, :invites, with_redeemer(revoked))}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not revoke invite.")}
        end
    end
  end

  defp with_redeemer(invite),
    do: Diogramos.Repo.preload(invite, :consumed_by)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-2xl mx-auto py-8">
        <header class="flex items-center justify-between mb-4">
          <div>
            <h1 class="text-2xl font-bold">Invites</h1>
            <p class="text-sm opacity-70">
              Each invite link can be used once to create a new account.
            </p>
          </div>
          <button
            type="button"
            id="btn-create-invite"
            phx-click="create_invite"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus-micro" class="size-4" /> New invite
          </button>
        </header>

        <ul id="invites" phx-update="stream" class="flex flex-col gap-2">
          <li
            id="invites-empty"
            class="hidden only:block text-center text-sm opacity-60 py-8"
          >
            No invites yet. Click <em class="not-italic font-semibold">New invite</em>
            to create one.
          </li>
          <li
            :for={{dom_id, invite} <- @streams.invites}
            id={dom_id}
            class={[
              "border border-base-300 rounded-box p-3 flex items-center gap-3 bg-base-200",
              invite.consumed_at && "opacity-60"
            ]}
          >
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 text-xs">
                <span class="font-mono opacity-60">id #{invite.id}</span>
                <%= if invite.consumed_at && invite.consumed_by_id do %>
                  <span class="badge badge-ghost">used</span>
                <% end %>
                <%= if invite.consumed_at && is_nil(invite.consumed_by_id) do %>
                  <span class="badge badge-error">revoked</span>
                <% end %>
                <%= if is_nil(invite.consumed_at) do %>
                  <span class="badge badge-success">active</span>
                <% end %>
              </div>
              <code class="block mt-1 text-xs font-mono truncate">
                {url(~p"/users/register?invite=#{invite.token}")}
              </code>
              <%= if invite.consumed_by do %>
                <p class="text-xs opacity-70 mt-1">
                  Redeemed by <span class="font-mono">{invite.consumed_by.email}</span>
                  on {Calendar.strftime(invite.consumed_at, "%Y-%m-%d %H:%M")}
                </p>
              <% end %>
            </div>
            <div class="flex items-center gap-1">
              <%= if is_nil(invite.consumed_at) do %>
                <button
                  type="button"
                  phx-click="revoke_invite"
                  phx-value-id={invite.id}
                  class="btn btn-ghost btn-xs text-error"
                  title="Revoke invite"
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </button>
              <% end %>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end

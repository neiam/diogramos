defmodule DiogramosWeb.UserLive.Registration do
  use DiogramosWeb, :live_view

  alias Diogramos.Accounts
  alias Diogramos.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <%= if @gated do %>
          <div class="alert alert-warning mt-6">
            <div>
              <p class="font-semibold">Registration is invite-only right now.</p>
              <p class="text-sm opacity-90">
                You'll need an invite link from an existing member to create an account.
              </p>
            </div>
          </div>
        <% else %>
          <%= if @invite do %>
            <div class="alert alert-info mt-6 mb-2">
              <p class="text-sm">
                Welcome — your invite is valid. Finish creating your account below.
              </p>
            </div>
          <% end %>

          <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
            <.input
              field={@form[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />

            <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
              Create an account
            </.button>
          </.form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: DiogramosWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, _session, socket) do
    invite =
      case params["invite"] do
        token when is_binary(token) -> Accounts.get_active_invite(token)
        _ -> nil
      end

    open? = Accounts.registration_open?()
    gated = not open? and is_nil(invite)

    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(:invite, invite)
     |> assign(:gated, gated)
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", _, %{assigns: %{gated: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Registration is invite-only.")}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        if invite = socket.assigns.invite do
          {:ok, _} = Accounts.consume_invite(invite, user)
        end

        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end

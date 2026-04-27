defmodule DiogramosWeb.UserLive.RegistrationTest do
  use DiogramosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Diogramos.AccountsFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      user = user_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          user: %{"email" => user.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "invite-only mode" do
    setup do
      Application.put_env(:diogramos, :registration_open, false)
      on_exit(fn -> Application.put_env(:diogramos, :registration_open, true) end)
      :ok
    end

    test "without an invite, the form is replaced by an invite-only notice", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "invite-only"
      refute html =~ ~s(id="registration_form")
    end

    test "with a valid invite token, the registration form renders", %{conn: conn} do
      owner = user_fixture()
      {:ok, invite} = Diogramos.Accounts.create_invite(owner)

      {:ok, _lv, html} = live(conn, ~p"/users/register?invite=#{invite.token}")
      assert html =~ ~s(id="registration_form")
      refute html =~ "invite-only"
    end

    test "registering through an invite consumes it", %{conn: conn} do
      owner = user_fixture()
      {:ok, invite} = Diogramos.Accounts.create_invite(owner)

      {:ok, lv, _} = live(conn, ~p"/users/register?invite=#{invite.token}")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))
      {:ok, _, _} = render_submit(form) |> follow_redirect(conn, ~p"/users/log-in")

      assert is_nil(Diogramos.Accounts.get_active_invite(invite.token))
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end

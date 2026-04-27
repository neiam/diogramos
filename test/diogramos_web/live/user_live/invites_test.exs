defmodule DiogramosWeb.UserLive.InvitesTest do
  use DiogramosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Diogramos.AccountsFixtures

  alias Diogramos.Accounts

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "renders empty state and lets the user create an invite", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/users/invites")
    assert html =~ "No invites yet"

    lv |> element("#btn-create-invite") |> render_click()
    assert [%Accounts.Invite{}] = Accounts.list_invites(user)

    html = render(lv)
    assert html =~ "active"
    assert html =~ "/users/register?invite="
  end

  test "shows who redeemed an invite once consumed", %{conn: conn, user: user} do
    {:ok, invite} = Accounts.create_invite(user)
    invitee = user_fixture()
    {:ok, _} = Accounts.consume_invite(invite, invitee)

    {:ok, _lv, html} = live(conn, ~p"/users/invites")
    assert html =~ "Redeemed by"
    assert html =~ invitee.email
  end

  test "revoking an invite marks it consumed without a consumer", %{conn: conn, user: user} do
    {:ok, invite} = Accounts.create_invite(user)
    {:ok, lv, _} = live(conn, ~p"/users/invites")

    lv
    |> element("button[phx-click=\"revoke_invite\"][phx-value-id=\"#{invite.id}\"]")
    |> render_click()

    assert html = render(lv)
    assert html =~ "revoked"
  end
end

defmodule DiogramosWeb.ShareLinkControllerTest do
  use DiogramosWeb.ConnCase, async: true

  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams

  setup do
    owner = user_fixture()
    %{owner: owner, owner_scope: Scope.for_user(owner)}
  end

  test "redeems a share link for an anonymous visitor and logs them in", %{
    conn: conn,
    owner_scope: owner_scope
  } do
    canvas = canvas_fixture(owner_scope)
    {:ok, link} = Diagrams.create_share_link(owner_scope, canvas, "viewer")

    conn = get(conn, ~p"/s/#{link.token}")

    assert redirected_to(conn) == "/c/" <> canvas.slug
    assert get_session(conn, :user_token), "anonymous user should be logged in"
  end

  test "redeems a share link for an already-signed-in user without re-logging-in", %{
    conn: conn,
    owner_scope: owner_scope
  } do
    canvas = canvas_fixture(owner_scope)
    {:ok, link} = Diagrams.create_share_link(owner_scope, canvas, "editor")

    visitor = user_fixture()
    conn = log_in_user(conn, visitor)
    pre_token = get_session(conn, :user_token)

    conn = get(conn, ~p"/s/#{link.token}")

    assert redirected_to(conn) == "/c/" <> canvas.slug
    assert get_session(conn, :user_token) == pre_token

    assert Diagrams.effective_role(Scope.for_user(visitor), canvas) == "editor"
  end

  test "invalid token shows a flash and redirects home", %{conn: conn} do
    conn = get(conn, ~p"/s/not-a-real-token")
    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid"
  end
end

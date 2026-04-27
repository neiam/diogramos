defmodule DiogramosWeb.CanvasEmbedRedirectControllerTest do
  use DiogramosWeb.ConnCase, async: true

  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams

  setup do
    owner = user_fixture()
    %{owner: owner, scope: Scope.for_user(owner)}
  end

  test "redirects to /embed/<token> when embedding is enabled", %{conn: conn, scope: scope} do
    canvas = canvas_fixture(scope, %{slug: "embed-target", title: "Embed me"})
    {:ok, canvas} = Diagrams.generate_canvas_embed_token(scope, canvas)

    conn = get(conn, ~p"/c-embed/#{canvas.slug}")

    assert redirected_to(conn) == "/embed/#{canvas.embed_token}"
  end

  test "404s when the canvas exists but has no embed token", %{conn: conn, scope: scope} do
    canvas = canvas_fixture(scope, %{slug: "no-embed", title: "Not embedded"})

    conn = get(conn, ~p"/c-embed/#{canvas.slug}")

    assert response(conn, 404)
  end

  test "404s when the slug doesn't exist", %{conn: conn} do
    conn = get(conn, ~p"/c-embed/does-not-exist")
    assert response(conn, 404)
  end
end

defmodule DiogramosWeb.CanvasExportControllerTest do
  use DiogramosWeb.ConnCase, async: true

  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope

  setup %{conn: conn} do
    user = user_fixture()
    scope = Scope.for_user(user)
    canvas = canvas_fixture(scope, %{slug: "exportable", title: "Export me"})
    %{conn: log_in_user(conn, user), scope: scope, canvas: canvas}
  end

  test "downloads the canvas as JSON", %{conn: conn, canvas: canvas} do
    conn = get(conn, ~p"/c/#{canvas.slug}/export.json")

    assert response_content_type(conn, :json)

    assert ["attachment; filename=\"exportable.json\""] =
             get_resp_header(conn, "content-disposition")

    assert {:ok, %{"format" => "diogramos.canvas.v1", "title" => "Export me"}} =
             Jason.decode(response(conn, 200))
  end

  test "404s for an unknown slug", %{conn: conn} do
    conn = get(conn, ~p"/c/does-not-exist/export.json")
    assert response(conn, 404)
  end
end

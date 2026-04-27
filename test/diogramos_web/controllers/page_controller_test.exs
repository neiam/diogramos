defmodule DiogramosWeb.PageControllerTest do
  use DiogramosWeb.ConnCase

  test "GET / renders the marketing landing for anonymous visitors", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ "Diagrams, drawn together"
    assert html =~ ~p"/users/register"
    assert html =~ ~p"/users/log-in"
  end

  test "GET / shows the canvases CTA when signed in", %{conn: conn} do
    user = Diogramos.AccountsFixtures.user_fixture()
    html = conn |> log_in_user(user) |> get(~p"/") |> html_response(200)
    assert html =~ "Open canvases"
    assert html =~ ~p"/canvases"
  end
end

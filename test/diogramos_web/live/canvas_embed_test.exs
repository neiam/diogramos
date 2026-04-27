defmodule DiogramosWeb.CanvasEmbedTest do
  use DiogramosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams

  setup do
    owner = user_fixture()
    scope = Scope.for_user(owner)
    canvas = canvas_fixture(scope, %{slug: "embed-canvas", title: "Embed me"})
    {:ok, canvas} = Diagrams.generate_canvas_embed_token(scope, canvas)
    Diogramos.DataCase.allow_authority(canvas.id)
    %{owner: owner, scope: scope, canvas: canvas}
  end

  test "renders an embedded canvas without auth", %{conn: conn, canvas: canvas} do
    {:ok, _lv, html} = live(conn, ~p"/embed/#{canvas.embed_token}")
    assert html =~ ~s(id="embed-svg")
    assert html =~ ~s(data-theme="#{canvas.theme}")
  end

  test "invalid token shows a friendly error", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/embed/not-a-real-token")
    assert html =~ "not available"
  end

  test "embed route serves an iframe-friendly CSP", %{conn: conn, canvas: canvas} do
    conn = get(conn, ~p"/embed/#{canvas.embed_token}")
    headers = Map.new(conn.resp_headers)

    assert headers["x-frame-options"] in [nil, ""]
    assert headers["content-security-policy"] =~ "frame-ancestors *"
  end

  test "embed renders every enabled link with its configured icon", %{
    conn: conn,
    canvas: canvas,
    owner: owner
  } do
    editor_conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> log_in_user(owner)

    {:ok, edit_lv, _} = live(editor_conn, ~p"/c/#{canvas.slug}")

    el = %{
      "id" => "01EMBLINKED0000000000000A",
      "type" => "rect",
      "x" => 0,
      "y" => 0,
      "w" => 200,
      "h" => 100,
      "links" => [
        %{
          "enabled" => true,
          "kind" => "external",
          "target" => "https://example.com",
          "icon" => "globe-alt"
        },
        %{
          "enabled" => true,
          "kind" => "external",
          "target" => "https://example.org",
          "icon" => "bookmark"
        }
      ]
    }

    render_hook(edit_lv, "apply_op", %{
      "op" => %{"type" => "insert_element", "element" => el}
    })

    {:ok, embed_lv, _} = live(conn, ~p"/embed/#{canvas.embed_token}")
    _ = :sys.get_state(embed_lv.pid)
    html = render(embed_lv)

    assert html =~ "dx-link-icon-globe-alt"
    assert html =~ "dx-link-icon-bookmark"
    assert html =~ ~s(href="https://example.com")
    assert html =~ ~s(href="https://example.org")
  end

  test "embed identity chip defaults to a random animal name + palette colour", %{
    conn: conn,
    canvas: canvas
  } do
    {:ok, _lv, html} = live(conn, ~p"/embed/#{canvas.embed_token}")
    assert html =~ ~s(id="embed-identity")
    refute html =~ ">Guest<"

    # Two title-cased words ("Crimson Otter") inside the identity chip.
    assert html =~ ~r/<span class="font-mono text-xs">[A-Z][a-z]+ [A-Z][a-z]+<\/span>/

    # Cursor colour is one of the palette swatches.
    assert Enum.any?(DiogramosWeb.CanvasPresence.palette(), fn c ->
             html =~ "background: " <> c
           end)
  end

  test "embed cursor presence is filterable in the editor", %{conn: conn, canvas: canvas, owner: owner} do
    {:ok, embed_lv, _} = live(conn, ~p"/embed/#{canvas.embed_token}")
    render_hook(embed_lv, "cursor", %{"x" => 50, "y" => 70})

    editor_conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> log_in_user(owner)

    {:ok, edit_lv, _} = live(editor_conn, ~p"/c/#{canvas.slug}")
    _ = :sys.get_state(edit_lv.pid)
    html = render(edit_lv)
    assert html =~ ~s(id="cur-embed-)

    # Toggle viewers off — embed cursor should disappear from the editor.
    edit_lv |> element("#btn-toggle-embed-cursors") |> render_click()
    html = render(edit_lv)
    refute html =~ ~s(id="cur-embed-)
  end

  test "save_identity updates the embed's presence and persists via push_event", %{
    conn: conn,
    canvas: canvas
  } do
    {:ok, embed_lv, _} = live(conn, ~p"/embed/#{canvas.embed_token}")

    render_hook(embed_lv, "save_identity", %{
      "identity" => %{"name" => "Alice", "color" => "#22c55e"}
    })

    html = render(embed_lv)
    assert html =~ "Alice"
    assert html =~ "background: #22c55e"
  end

  test "embed receives live updates from the editor", %{conn: conn, canvas: canvas, owner: owner} do
    {:ok, embed_lv, _} = live(conn, ~p"/embed/#{canvas.embed_token}")

    editor_conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> log_in_user(owner)

    {:ok, edit_lv, _} = live(editor_conn, ~p"/c/#{canvas.slug}")

    element = %{
      "id" => "01EMB0000000000000000000A1",
      "type" => "rect",
      "x" => 0,
      "y" => 0,
      "w" => 60,
      "h" => 30,
      "label" => "embed-live"
    }

    render_hook(edit_lv, "apply_op", %{
      "op" => %{"type" => "insert_element", "element" => element}
    })

    _ = :sys.get_state(embed_lv.pid)
    assert render(embed_lv) =~ "embed-live"
  end
end

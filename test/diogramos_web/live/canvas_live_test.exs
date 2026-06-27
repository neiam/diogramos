defmodule DiogramosWeb.CanvasLiveTest do
  use DiogramosWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams

  describe "CanvasLive.Index" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, scope: Scope.for_user(user)}
    end

    test "renders empty state then a created canvas", %{conn: conn, scope: scope} do
      {:ok, _lv, html} = live(conn, ~p"/canvases")
      assert html =~ "No canvases yet"

      _canvas = canvas_fixture(scope, %{slug: "first-canvas", title: "First"})

      {:ok, _lv, html} = live(conn, ~p"/canvases")
      assert html =~ "First"
      assert html =~ "first-canvas"
    end

    test "the new-canvas modal opens and validates", %{conn: conn} do
      {:ok, lv, _} = live(conn, ~p"/canvases")
      lv |> element("#btn-new-canvas") |> render_click()
      assert has_element?(lv, "#new-canvas-modal")
    end

    test "card carries the canvas's theme as data-theme", %{conn: conn, scope: scope} do
      _ = canvas_fixture(scope, %{slug: "themed-card", title: "Themed", theme: "forest"})

      {:ok, _lv, html} = live(conn, ~p"/canvases")
      assert html =~ ~s(data-theme="forest")
    end

    test "manage modal opens for an owned canvas and lists current grants", %{
      conn: conn,
      scope: scope
    } do
      canvas = canvas_fixture(scope, %{slug: "managed-canvas", title: "Managed"})
      collaborator = user_fixture()

      {:ok, _} =
        Diagrams.grant_permission(
          "canvas",
          canvas.id,
          "user",
          collaborator.id,
          "editor",
          granted_by_id: scope.user.id
        )

      {:ok, lv, _} = live(conn, ~p"/canvases")

      lv
      |> element("button[phx-click=\"open_manage_modal\"][phx-value-id=\"#{canvas.id}\"]")
      |> render_click()

      html = render(lv)
      assert html =~ "Manage collaborators"
      assert html =~ collaborator.email
      assert html =~ "editor"
    end

    test "grant_user adds a collaborator and revoke_user removes them", %{
      conn: conn,
      scope: scope
    } do
      canvas = canvas_fixture(scope, %{slug: "share-flow", title: "Share"})
      collaborator = user_fixture()

      {:ok, lv, _} = live(conn, ~p"/canvases")

      lv
      |> element("button[phx-click=\"open_manage_modal\"][phx-value-id=\"#{canvas.id}\"]")
      |> render_click()

      lv
      |> element("#manage-grant-form")
      |> render_submit(%{"email" => collaborator.email, "role" => "viewer"})

      assert Diagrams.effective_role(Scope.for_user(collaborator), canvas) == "viewer"

      lv
      |> element("button[phx-click=\"revoke_user\"][phx-value-user_id=\"#{collaborator.id}\"]")
      |> render_click()

      assert Diagrams.effective_role(Scope.for_user(collaborator), canvas) == nil
    end

    test "manage modal can switch the canvas theme", %{conn: conn, scope: scope} do
      canvas =
        canvas_fixture(scope, %{slug: "theme-switch", title: "Theme switch", theme: "afterdark"})

      {:ok, lv, _} = live(conn, ~p"/canvases")

      lv
      |> element("button[phx-click=\"open_manage_modal\"][phx-value-id=\"#{canvas.id}\"]")
      |> render_click()

      render_hook(lv, "update_canvas_theme", %{"theme" => "forest"})

      reloaded = Diagrams.get_canvas!(scope, canvas.id)
      assert reloaded.theme == "forest"
      assert render(lv) =~ "Theme updated."
    end

    test "grant_user surfaces an error when the email is unknown", %{conn: conn, scope: scope} do
      canvas = canvas_fixture(scope, %{slug: "share-bad-email", title: "Bad email"})

      {:ok, lv, _} = live(conn, ~p"/canvases")

      lv
      |> element("button[phx-click=\"open_manage_modal\"][phx-value-id=\"#{canvas.id}\"]")
      |> render_click()

      lv
      |> element("#manage-grant-form")
      |> render_submit(%{"email" => "ghost@example.com", "role" => "editor"})

      assert render(lv) =~ "No registered user with that email."
    end

    test "filtering by folder narrows the canvas list", %{conn: conn, scope: scope} do
      _outside = canvas_fixture(scope, %{slug: "outside-folder", title: "Outside"})
      folder = folder_fixture(scope)

      inside =
        canvas_fixture(scope, %{slug: "inside-folder", title: "Inside", folder_id: folder.id})

      {:ok, lv, _} = live(conn, ~p"/canvases")
      assert render(lv) =~ "Outside"

      lv
      |> element("button", folder.name)
      |> render_click()

      html = render(lv)
      assert html =~ inside.title
      refute html =~ "Outside"
    end
  end

  describe "CanvasLive.Edit" do
    setup %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      canvas = canvas_fixture(scope, %{slug: "edit-canvas", title: "Edit me"})
      Diogramos.DataCase.allow_authority(canvas.id)
      %{conn: log_in_user(conn, user), scope: scope, canvas: canvas}
    end

    test "renders the editor shell", %{conn: conn, canvas: canvas} do
      {:ok, _lv, html} = live(conn, ~p"/c/#{canvas.slug}")
      assert html =~ canvas.title
      assert html =~ ~s(id="canvas-svg")
      assert html =~ ~s(id="tool-rect")
      assert html =~ ~s(id="tool-fit-camera")
    end

    test "viewer-only access marks the editor read-only", %{
      conn: conn,
      canvas: canvas,
      scope: owner_scope
    } do
      visitor = user_fixture()

      {:ok, _} =
        Diagrams.grant_permission("canvas", canvas.id, "user", visitor.id, "viewer",
          granted_by_id: owner_scope.user.id
        )

      conn = conn |> Plug.Conn.delete_session(:user_token) |> log_in_user(visitor)
      {:ok, lv, html} = live(conn, ~p"/c/#{canvas.slug}")

      assert html =~ "view only"
      assert lv |> element("#tool-rect") |> render() =~ "disabled"
    end

    test "missing canvas redirects to index", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/canvases"}}} =
               live(conn, ~p"/c/does-not-exist")
    end

    test "apply_op insert_element renders the new shape", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01TESTRECT0000000000000000",
        "type" => "rect",
        "x" => 10,
        "y" => 20,
        "w" => 100,
        "h" => 60,
        "label" => "hello"
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => element}})

      html = render(lv)
      assert html =~ ~s(id="el-01TESTRECT0000000000000000")
      assert html =~ "hello"
    end

    test "selecting an element renders the property panel form", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01ELEM00000000000000000000",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40,
        "label" => "hi"
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => element}})
      render_hook(lv, "select_element", %{"id" => element["id"]})

      html = render(lv)
      assert html =~ ~s(id="el-form-01ELEM00000000000000000000")
      assert html =~ ~s(name="props[label]")
    end

    test "update_selected applies a patch and is held by the authority", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01ELEM11111111111111111111",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40,
        "label" => "before"
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => element}})
      render_hook(lv, "select_element", %{"id" => element["id"]})

      render_hook(lv, "update_selected", %{
        "props" => %{"label" => "after", "x" => "10", "y" => "20", "w" => "80", "h" => "40"}
      })

      {:ok, %{document: doc, version: version}} =
        Diogramos.Diagrams.Authority.snapshot(canvas.id)

      assert doc["elements"][element["id"]]["label"] == "after"
      assert doc["elements"][element["id"]]["x"] == 10
      assert version > canvas.version
    end

    test "delete_selected removes the element from the document", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01ELEM22222222222222222222",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => element}})
      render_hook(lv, "select_element", %{"id" => element["id"]})
      render_hook(lv, "delete_selected", %{})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      refute Map.has_key?(doc["elements"], element["id"])
    end

    test "inserting a connector renders the connector path", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01EA000000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40
      }

      b = %{
        "id" => "01EB000000000000000000000B",
        "type" => "rect",
        "x" => 200,
        "y" => 100,
        "w" => 80,
        "h" => 40
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})

      connector = %{
        "id" => "01CN0000000000000000000001",
        "from" => %{"element" => a["id"], "anchor" => "auto", "_other" => b["id"]},
        "to" => %{"element" => b["id"], "anchor" => "auto", "_other" => a["id"]}
      }

      render_hook(lv, "apply_op", %{
        "op" => %{"type" => "insert_connector", "connector" => connector}
      })

      html = render(lv)
      assert html =~ ~s(id="con-01CN0000000000000000000001")
      assert html =~ ~s(marker-end=)
    end

    test "mermaid export modal renders the source", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01MMD0000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30,
        "label" => "Hello"
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})

      lv |> element("#btn-export-mermaid") |> render_click()

      html = render(lv)
      assert html =~ "flowchart LR"
      assert html =~ "Hello"
    end

    test "embed toggle generates and clears the token", %{
      conn: conn,
      canvas: canvas,
      scope: scope
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      lv |> element("#btn-toggle-embed") |> render_click()

      reloaded = Diagrams.get_canvas!(scope, canvas.id)
      assert reloaded.embed_token

      lv |> element("#btn-toggle-embed") |> render_click()
      assert is_nil(Diagrams.get_canvas!(scope, canvas.id).embed_token)
    end

    test "clipboard preview surfaces in the property panel", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01CLP00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30,
        "style" => %{"fill" => "primary", "stroke" => "accent"}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      assert render(lv) =~ "Clipboard empty"

      render_hook(lv, "select_element", %{"id" => a["id"]})
      render_hook(lv, "copy_style", %{})

      html = render(lv)
      refute html =~ "Clipboard empty"
      assert html =~ "var(--color-primary)"
      assert html =~ "var(--color-accent)"
      assert html =~ ~s(<span class="ml-auto opacity-50 font-mono">element</span>)
    end

    test "new shape inherits the clipboard style", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      template = %{
        "id" => "01CLPTPL00000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30,
        "style" => %{"fill" => "warning", "stroke" => "primary", "shadow" => true}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => template}})
      render_hook(lv, "select_element", %{"id" => template["id"]})
      render_hook(lv, "copy_style", %{})

      fresh = %{
        "id" => "01CLPNEW00000000000000000B",
        "type" => "rect",
        "x" => 200,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => fresh}})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert doc["elements"][fresh["id"]]["style"]["fill"] == "warning"
      assert doc["elements"][fresh["id"]]["style"]["stroke"] == "primary"
      assert doc["elements"][fresh["id"]]["style"]["shadow"] == true
    end

    test "text element honors font/size/style controls", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      t = %{
        "id" => "01TXT00000000000000000000A",
        "type" => "text",
        "x" => 50,
        "y" => 60,
        "w" => 100,
        "h" => 30,
        "label" => "B612 sample",
        "style" => %{
          "font_family" => "b612-mono",
          "font_size" => 28,
          "font_bold" => true,
          "font_italic" => true,
          "fill" => "primary"
        }
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => t}})

      html = render(lv)
      assert html =~ "B612 Mono"
      assert html =~ "font-size: 28px"
      assert html =~ "font-weight: 700"
      assert html =~ "font-style: italic"
      assert html =~ "fill: var(--color-primary)"
    end

    test "z-order controls reorder the document", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01ZA00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      b = %{
        "id" => "01ZB00000000000000000000B",
        "type" => "rect",
        "x" => 50,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      c = %{
        "id" => "01ZC00000000000000000000C",
        "type" => "rect",
        "x" => 100,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => c}})

      render_hook(lv, "select_element", %{"id" => a["id"]})
      render_hook(lv, "z_order", %{"action" => "to_front"})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert List.last(doc["order"]) == a["id"]

      render_hook(lv, "select_element", %{"id" => c["id"]})
      render_hook(lv, "z_order", %{"action" => "to_back"})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert hd(doc["order"]) == c["id"]
    end

    test "transparent fill renders without a color var", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01TRP00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30,
        "style" => %{"fill" => "transparent", "stroke" => "primary"}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})

      html = render(lv)
      assert html =~ "fill: transparent"
      assert html =~ "stroke: var(--color-primary)"
    end

    test "shadow toggle renders a translucent backing shape", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01SHDW0000000000000000000A",
        "type" => "rect",
        "x" => 50,
        "y" => 50,
        "w" => 80,
        "h" => 40,
        "style" => %{"fill" => "primary", "shadow" => true}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})

      html = render(lv)
      assert html =~ "opacity: 0.55"
      # 50 + shadow_offset (12) = 62
      assert html =~ ~s(x="62")
    end

    test "snap-to-grid toggle exposes the grid pattern", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")
      refute render(lv) =~ "url(#canvas-grid-pattern)"

      lv |> element("#btn-toggle-grid") |> render_click()

      html = render(lv)
      assert html =~ ~s(data-snap-grid="true")
      assert html =~ "url(#canvas-grid-pattern)"
    end

    test "set_grid event applies a stored preference on mount", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")
      render_hook(lv, "set_grid", %{"on" => true})

      html = render(lv)
      assert html =~ ~s(data-snap-grid="true")
    end

    test "select_set replaces selection with multiple items", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01MS00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      b = %{
        "id" => "01MS00000000000000000000B",
        "type" => "rect",
        "x" => 80,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})

      render_hook(lv, "select_set", %{"elements" => [a["id"], b["id"]], "connectors" => []})

      html = render(lv)
      assert html =~ "multi-selection-panel"
      assert html =~ ~s(<span class="font-mono">2</span>)
      assert html =~ "elements"
      assert html =~ "connectors"
    end

    test "copy + paste selection clones elements with new ids and an offset", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01CP00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      b = %{
        "id" => "01CP00000000000000000000B",
        "type" => "rect",
        "x" => 80,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})

      render_hook(lv, "select_set", %{"elements" => [a["id"], b["id"]], "connectors" => []})
      render_hook(lv, "copy_selection", %{})
      render_hook(lv, "paste_selection", %{})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      ids = Map.keys(doc["elements"])
      assert length(ids) == 4
      pasted = ids -- [a["id"], b["id"]]
      assert length(pasted) == 2

      # Pasted shapes are offset from their originals.
      pasted_xs = pasted |> Enum.map(&doc["elements"][&1]["x"]) |> Enum.sort()
      assert pasted_xs == [24, 104]
    end

    test "copy + paste selection remaps connector endpoints to new element ids", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01CC00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      b = %{
        "id" => "01CC00000000000000000000B",
        "type" => "rect",
        "x" => 100,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      k = %{
        "id" => "01CK00000000000000000000K",
        "from" => %{"element" => a["id"], "anchor" => "auto"},
        "to" => %{"element" => b["id"], "anchor" => "auto"}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_connector", "connector" => k}})

      render_hook(lv, "select_set", %{
        "elements" => [a["id"], b["id"]],
        "connectors" => [k["id"]]
      })

      render_hook(lv, "copy_selection", %{})
      render_hook(lv, "paste_selection", %{})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert map_size(doc["elements"]) == 4
      assert map_size(doc["connectors"]) == 2

      [orig, copy] =
        doc["connectors"]
        |> Map.values()
        |> Enum.sort_by(& &1["id"])

      # Original and copy point to different element pairs.
      refute orig["from"]["element"] == copy["from"]["element"]
      refute orig["to"]["element"] == copy["to"]["element"]
    end

    test "delete_selected removes every item in a multi-selection", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01MD00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      b = %{
        "id" => "01MD00000000000000000000B",
        "type" => "rect",
        "x" => 80,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})

      render_hook(lv, "select_set", %{"elements" => [a["id"], b["id"]], "connectors" => []})
      render_hook(lv, "delete_selected", %{})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert doc["elements"] == %{}
    end

    test "label position + size apply to shape labels", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01LBL00000000000000000000A",
        "type" => "rect",
        "x" => 100,
        "y" => 50,
        "w" => 200,
        "h" => 100,
        "label" => "centered",
        "style" => %{"label_position" => "center", "label_size" => "lg"}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})

      html = render(lv)
      assert html =~ ~s(text-anchor="middle")
      assert html =~ ~s(dominant-baseline="middle")
      assert html =~ "font-size: 18px"
    end

    test "label font/color/weight apply to shape labels", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01LBL00000000000000000000B",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 100,
        "h" => 60,
        "label" => "Hello",
        "style" => %{
          "label_color" => "primary",
          "label_font_family" => "b612-mono",
          "label_bold" => true,
          "label_italic" => true
        }
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})

      html = render(lv)
      assert html =~ "fill: var(--color-primary)"
      assert html =~ "B612 Mono"
      assert html =~ "font-weight: 700"
      assert html =~ "font-style: italic"
    end

    test "multiple metadata links render side-by-side icons", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01LNK00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 200,
        "h" => 100,
        "links" => [
          %{
            "enabled" => true,
            "kind" => "external",
            "target" => "https://elixir-lang.org",
            "icon" => "globe-alt"
          },
          %{
            "enabled" => true,
            "kind" => "canvas",
            "target" => "another-canvas",
            "icon" => "link"
          }
        ]
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})

      html = render(lv)
      assert html =~ ~s(href="https://elixir-lang.org")
      # The editor renders canvas links with the :editor context (link_href/2),
      # which points at the canvas editor (/c/<slug>); /c-embed/<slug> is only
      # used in the read-only embed view.
      assert html =~ ~s(href="/c/another-canvas")
      assert html =~ "dx-link-icon-globe-alt"
      assert html =~ "dx-link-icon-link"
    end

    test "add_link / remove_link append + drop links", %{
      conn: conn,
      canvas: canvas
    } do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01LNK00000000000000000000B",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 100,
        "h" => 60
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})
      render_hook(lv, "select_element", %{"id" => el["id"]})

      render_hook(lv, "add_link", %{"element_id" => el["id"]})
      render_hook(lv, "add_link", %{"element_id" => el["id"]})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert length(doc["elements"][el["id"]]["links"]) == 2

      render_hook(lv, "remove_link", %{"element_id" => el["id"], "index" => "0"})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert length(doc["elements"][el["id"]]["links"]) == 1
    end

    test "border dash + width style applies to shapes", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01BRD0000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40,
        "style" => %{"dash" => "dashed", "stroke_width" => 4}
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})

      html = render(lv)
      assert html =~ "stroke-width: 4"
      assert html =~ "stroke-dasharray: 8 6"
    end

    test "selected element shows a resize handle in select mode", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      el = %{
        "id" => "01RSZ00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => el}})
      render_hook(lv, "select_element", %{"id" => el["id"]})

      assert render(lv) =~ ~s(data-resize-handle="01RSZ00000000000000000000A")
    end

    test "copy/paste style clones colors between elements", %{conn: conn, canvas: canvas} do
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      a = %{
        "id" => "01STY00000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 60,
        "h" => 30,
        "style" => %{"fill" => "primary", "stroke" => "accent"}
      }

      b = %{
        "id" => "01STY00000000000000000000B",
        "type" => "rect",
        "x" => 100,
        "y" => 0,
        "w" => 60,
        "h" => 30
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => a}})
      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => b}})

      render_hook(lv, "select_element", %{"id" => a["id"]})
      render_hook(lv, "copy_style", %{})

      render_hook(lv, "select_element", %{"id" => b["id"]})
      render_hook(lv, "paste_style", %{})

      {:ok, %{document: doc}} = Diogramos.Diagrams.Authority.snapshot(canvas.id)
      assert doc["elements"][b["id"]]["style"]["fill"] == "primary"
      assert doc["elements"][b["id"]]["style"]["stroke"] == "accent"
    end

    test "cursor presence broadcasts to peers", %{
      conn: conn,
      canvas: canvas,
      scope: owner_scope
    } do
      collaborator = user_fixture()

      {:ok, _} =
        Diogramos.Diagrams.grant_permission(
          "canvas",
          canvas.id,
          "user",
          collaborator.id,
          "editor",
          granted_by_id: owner_scope.user.id
        )

      {:ok, lv_a, _} = live(conn, ~p"/c/#{canvas.slug}")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> log_in_user(collaborator)

      {:ok, lv_b, _} = live(conn_b, ~p"/c/#{canvas.slug}")

      render_hook(lv_a, "cursor", %{"x" => 123, "y" => 45})

      # Let the presence diff propagate.
      _ = :sys.get_state(lv_b.pid)
      html = render(lv_b)
      assert html =~ ~s(id="cur-user-)
      assert html =~ "translate(123 45)"
    end

    test "drag locks ghost the element for peers", %{
      conn: conn,
      canvas: canvas,
      scope: owner_scope
    } do
      collaborator = user_fixture()

      {:ok, _} =
        Diogramos.Diagrams.grant_permission(
          "canvas",
          canvas.id,
          "user",
          collaborator.id,
          "editor",
          granted_by_id: owner_scope.user.id
        )

      {:ok, lv_a, _} = live(conn, ~p"/c/#{canvas.slug}")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> log_in_user(collaborator)

      {:ok, lv_b, _} = live(conn_b, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01LOCK0000000000000000000A",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40
      }

      render_hook(lv_a, "apply_op", %{
        "op" => %{"type" => "insert_element", "element" => element}
      })

      render_hook(lv_a, "set_lock", %{"id" => element["id"]})

      _ = :sys.get_state(lv_b.pid)
      html = render(lv_b)
      assert html =~ ~s(id="el-01LOCK0000000000000000000A")
      assert html =~ "opacity-40"
    end

    test "two LV processes converge via the authority broadcast", %{
      conn: conn,
      canvas: canvas,
      scope: owner_scope
    } do
      collaborator = user_fixture()

      {:ok, _} =
        Diogramos.Diagrams.grant_permission(
          "canvas",
          canvas.id,
          "user",
          collaborator.id,
          "editor",
          granted_by_id: owner_scope.user.id
        )

      {:ok, lv_a, _} = live(conn, ~p"/c/#{canvas.slug}")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> log_in_user(collaborator)

      {:ok, lv_b, _} = live(conn_b, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01CONV0000000000000000000F",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 80,
        "h" => 40,
        "label" => "from-A"
      }

      render_hook(lv_a, "apply_op", %{
        "op" => %{"type" => "insert_element", "element" => element}
      })

      # The authority broadcasts to lv_b; render after a brief sync.
      _ = :sys.get_state(lv_b.pid)
      assert render(lv_b) =~ "from-A"
    end

    test "apply_op rejected when role is viewer", %{
      conn: conn,
      canvas: canvas,
      scope: owner_scope
    } do
      visitor = user_fixture()

      {:ok, _} =
        Diagrams.grant_permission("canvas", canvas.id, "user", visitor.id, "viewer",
          granted_by_id: owner_scope.user.id
        )

      conn = conn |> Plug.Conn.delete_session(:user_token) |> log_in_user(visitor)
      {:ok, lv, _} = live(conn, ~p"/c/#{canvas.slug}")

      element = %{
        "id" => "01TESTRECT0000000000000000",
        "type" => "rect",
        "x" => 0,
        "y" => 0,
        "w" => 50,
        "h" => 50
      }

      render_hook(lv, "apply_op", %{"op" => %{"type" => "insert_element", "element" => element}})
      refute render(lv) =~ "el-01TESTRECT0000000000000000"
    end
  end
end

defmodule Diogramos.DiagramsTest do
  use Diogramos.DataCase, async: true

  import Diogramos.AccountsFixtures
  import Diogramos.DiagramsFixtures

  alias Diogramos.Accounts.Scope
  alias Diogramos.Diagrams
  alias Diogramos.Diagrams.{Canvas, Folder}

  describe "canvases" do
    setup do
      user = user_fixture()
      other = user_fixture()
      %{scope: Scope.for_user(user), other_scope: Scope.for_user(other)}
    end

    test "create_canvas/2 inserts a canvas owned by the caller", %{scope: scope} do
      assert {:ok, %Canvas{} = canvas} =
               Diagrams.create_canvas(scope, %{
                 slug: "first",
                 title: "First Canvas",
                 theme: "afterdark"
               })

      assert canvas.owner_id == scope.user.id
      assert canvas.document == %{"elements" => %{}, "order" => [], "connectors" => %{}}
      assert canvas.version == 0
    end

    test "create_canvas/2 rejects unknown themes", %{scope: scope} do
      assert {:error, cs} =
               Diagrams.create_canvas(scope, %{
                 slug: "bad",
                 title: "Bad",
                 theme: "not-a-theme"
               })

      assert "is invalid" in errors_on(cs)[:theme]
    end

    test "list_canvases/1 returns owned canvases", %{scope: a, other_scope: b} do
      mine = canvas_fixture(a, %{slug: "mine-#{System.unique_integer([:positive])}"})
      _theirs = canvas_fixture(b)

      ids = Enum.map(Diagrams.list_canvases(a), & &1.id)
      assert mine.id in ids
      assert length(Diagrams.list_canvases(a)) == 1
    end

    test "viewer can read but not edit; editor can edit", %{scope: a, other_scope: b} do
      canvas = canvas_fixture(a)

      {:ok, _} =
        Diagrams.grant_permission("canvas", canvas.id, "user", b.user.id, "viewer",
          granted_by_id: a.user.id
        )

      assert %Canvas{} = Diagrams.get_canvas!(b, canvas.id)

      assert {:error, :forbidden} =
               Diagrams.update_canvas_metadata(b, canvas, %{title: "x", theme: canvas.theme})

      {:ok, _} =
        Diagrams.grant_permission("canvas", canvas.id, "user", b.user.id, "editor",
          granted_by_id: a.user.id
        )

      assert {:ok, %Canvas{title: "renamed"}} =
               Diagrams.update_canvas_metadata(b, canvas, %{title: "renamed", theme: canvas.theme})
    end

    test "folder grant cascades to canvases inside the folder", %{scope: a, other_scope: b} do
      folder = folder_fixture(a)
      canvas = canvas_fixture(a, %{folder_id: folder.id})

      assert Diagrams.effective_role(b, canvas) == nil

      {:ok, _} =
        Diagrams.grant_permission("folder", folder.id, "user", b.user.id, "editor",
          granted_by_id: a.user.id
        )

      assert Diagrams.effective_role(b, canvas) == "editor"
    end

    test "export + import_canvas round-trips a canvas", %{scope: a} do
      original =
        canvas_fixture(a, %{slug: "round-trip-original", title: "Round-trip"})

      doc = %{
        "elements" => %{
          "01EX00000000000000000000A" => %{
            "id" => "01EX00000000000000000000A",
            "type" => "rect",
            "x" => 0,
            "y" => 0,
            "w" => 50,
            "h" => 25,
            "label" => "exported",
            "style" => %{}
          }
        },
        "order" => ["01EX00000000000000000000A"],
        "connectors" => %{}
      }

      {:ok, original} = Diagrams.replace_canvas_document(a, original, doc)

      {:ok, payload} = Diagrams.export_canvas(a, original)
      assert payload["format"] == "diogramos.canvas.v1"
      assert payload["document"] == doc

      {:ok, imported} = Diagrams.import_canvas(a, payload)
      assert imported.id != original.id
      assert imported.slug != original.slug
      assert imported.title == original.title
      assert imported.document == doc
    end

    test "import_canvas rejects payloads with the wrong format", %{scope: a} do
      assert {:error, :invalid_format} =
               Diagrams.import_canvas(a, %{"format" => "something-else", "document" => %{}})
    end

    test "embed token round-trip", %{scope: a} do
      canvas = canvas_fixture(a)
      assert {:ok, c2} = Diagrams.generate_canvas_embed_token(a, canvas)
      assert c2.embed_token
      assert %Canvas{id: id} = Diagrams.get_canvas_for_embed(c2.embed_token)
      assert id == canvas.id
    end
  end

  describe "share links" do
    setup do
      owner = user_fixture()
      %{owner_scope: Scope.for_user(owner)}
    end

    test "create + redeem grants access to a signed-in user", %{owner_scope: owner} do
      canvas = canvas_fixture(owner)
      visitor = user_fixture()

      {:ok, link} = Diagrams.create_share_link(owner, canvas, "viewer")
      assert {:ok, ^visitor, ^canvas} = Diagrams.redeem_share_link(link.token, visitor)

      assert Diagrams.effective_role(Scope.for_user(visitor), canvas) == "viewer"
    end

    test "redeem with no current user mints an anonymous user", %{owner_scope: owner} do
      canvas = canvas_fixture(owner)
      {:ok, link} = Diagrams.create_share_link(owner, canvas, "editor")

      assert {:ok, %{kind: "anonymous"} = anon, ^canvas} =
               Diagrams.redeem_share_link(link.token, nil)

      assert Diagrams.effective_role(Scope.for_user(anon), canvas) == "editor"
    end

    test "revoked links are rejected", %{owner_scope: owner} do
      canvas = canvas_fixture(owner)
      {:ok, link} = Diagrams.create_share_link(owner, canvas, "viewer")
      {:ok, _} = Diagrams.revoke_share_link(owner, link)

      assert {:error, :invalid_link} = Diagrams.redeem_share_link(link.token, nil)
    end

    test "expired links are rejected", %{owner_scope: owner} do
      canvas = canvas_fixture(owner)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      {:ok, link} = Diagrams.create_share_link(owner, canvas, "viewer", expires_at: past)

      assert {:error, :invalid_link} = Diagrams.redeem_share_link(link.token, nil)
    end

    test "non-admin cannot create share links", %{owner_scope: owner} do
      canvas = canvas_fixture(owner)
      stranger = user_fixture()

      assert {:error, :forbidden} =
               Diagrams.create_share_link(Scope.for_user(stranger), canvas, "viewer")
    end
  end

  describe "folders" do
    setup do
      user = user_fixture()
      other = user_fixture()
      %{scope: Scope.for_user(user), other_scope: Scope.for_user(other)}
    end

    test "create_folder/2 inserts a folder owned by the caller", %{scope: scope} do
      assert {:ok, %Folder{name: "designs", owner_id: owner_id}} =
               Diagrams.create_folder(scope, %{name: "designs"})

      assert owner_id == scope.user.id
    end

    test "list_folders/1 returns only folders the user can see", %{scope: a, other_scope: b} do
      _mine = folder_fixture(a, %{name: "mine"})
      _theirs = folder_fixture(b, %{name: "theirs"})

      names = Enum.map(Diagrams.list_folders(a), & &1.name)
      assert "mine" in names
      refute "theirs" in names
    end

    test "list_folders/1 includes folders shared with the user via direct grant", %{
      scope: a,
      other_scope: b
    } do
      shared = folder_fixture(b, %{name: "shared"})

      {:ok, _} =
        Diagrams.grant_permission(
          "folder",
          shared.id,
          "user",
          a.user.id,
          "viewer",
          granted_by_id: b.user.id
        )

      names = Enum.map(Diagrams.list_folders(a), & &1.name)
      assert "shared" in names
    end

    test "rename_folder/3 requires write access", %{scope: a, other_scope: b} do
      f = folder_fixture(a, %{name: "old"})
      assert {:error, :forbidden} = Diagrams.rename_folder(b, f, "new")
      assert {:ok, %Folder{name: "new"}} = Diagrams.rename_folder(a, f, "new")
    end

    test "move_folder/3 rejects cycles", %{scope: a} do
      parent = folder_fixture(a, %{name: "parent"})
      {:ok, child} = Diagrams.create_folder(a, %{name: "child", parent_id: parent.id})

      assert {:error, :cycle} = Diagrams.move_folder(a, parent, child.id)
    end

    test "delete_folder/2 cascades to children via FK", %{scope: a} do
      parent = folder_fixture(a, %{name: "parent"})
      {:ok, child} = Diagrams.create_folder(a, %{name: "child", parent_id: parent.id})

      assert {:ok, _} = Diagrams.delete_folder(a, parent)
      assert_raise Ecto.NoResultsError, fn -> Diagrams.get_folder!(a, child.id) end
    end

    test "effective_role returns owner for the owner and nil for outsiders", %{
      scope: a,
      other_scope: b
    } do
      f = folder_fixture(a, %{name: "x"})
      assert Diagrams.effective_role(a, f) == "owner"
      assert Diagrams.effective_role(b, f) == nil
    end

    test "authorize honors role rank", %{scope: a, other_scope: b} do
      f = folder_fixture(a, %{name: "auth"})

      {:ok, _} =
        Diagrams.grant_permission("folder", f.id, "user", b.user.id, "viewer",
          granted_by_id: a.user.id
        )

      assert Diagrams.authorize(b, :read, f) == :ok
      assert Diagrams.authorize(b, :write, f) == {:error, :forbidden}

      {:ok, _} =
        Diagrams.grant_permission("folder", f.id, "user", b.user.id, "editor",
          granted_by_id: a.user.id
        )

      assert Diagrams.authorize(b, :write, f) == :ok
      assert Diagrams.authorize(b, :admin, f) == {:error, :forbidden}
    end
  end
end

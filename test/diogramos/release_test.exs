defmodule Diogramos.ReleaseTest do
  @moduledoc """
  We exercise `upsert_user/2` directly rather than the full `init/2`
  pipeline because `init/2` calls `Ecto.Migrator.with_repo`, which
  bootstraps a brand-new repo connection that conflicts with the test
  sandbox. The behaviour we care about — confirmed-at-on-create and
  password-rotation-on-update — lives in `upsert_user/2`.
  """
  use Diogramos.DataCase, async: true

  alias Diogramos.Accounts.User
  alias Diogramos.Release

  test "creates a confirmed user with the given password on first run" do
    assert {:ok, %User{} = user} = Release.upsert_user("admin@example.com", "very-strong-pw-1")
    assert user.email == "admin@example.com"
    assert user.confirmed_at
    assert user.kind == "registered"
    assert User.valid_password?(user, "very-strong-pw-1")
  end

  test "rotates the password and re-stamps confirmed_at on subsequent runs" do
    {:ok, original} = Release.upsert_user("admin@example.com", "very-strong-pw-1")

    # Force a clearly-different timestamp so we can assert the bump.
    {:ok, original} =
      original
      |> Ecto.Changeset.change(confirmed_at: ~U[2020-01-01 00:00:00Z])
      |> Diogramos.Repo.update()

    assert {:ok, rotated} = Release.upsert_user("admin@example.com", "different-strong-pw")
    assert rotated.id == original.id
    assert User.valid_password?(rotated, "different-strong-pw")
    refute User.valid_password?(rotated, "very-strong-pw-1")
    assert DateTime.compare(rotated.confirmed_at, original.confirmed_at) == :gt
  end
end

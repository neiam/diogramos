defmodule Diogramos.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Diogramos.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Diogramos.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Diogramos.DataCase
    end
  end

  setup tags do
    Diogramos.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Diogramos.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Eagerly starts the canvas authority for the given canvas id and grants
  it access to the current test's sandbox connection. Tests that exercise
  the live op pipeline (which crosses process boundaries via the
  authority GenServer) must call this in their setup.
  """
  def allow_authority(canvas_id) do
    {:ok, pid} = Diogramos.Diagrams.Authority.for_canvas(canvas_id)
    Ecto.Adapters.SQL.Sandbox.allow(Diogramos.Repo, self(), pid)
    on_exit(fn -> Diogramos.Diagrams.Authority.stop(canvas_id) end)
    pid
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

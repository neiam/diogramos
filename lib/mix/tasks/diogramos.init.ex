defmodule Mix.Tasks.Diogramos.Init do
  @moduledoc """
  Creates (or rotates) an initial confirmed user.

      mix diogramos.init you@example.com "a strong password"

  Runs migrations first so this task is safe on a fresh database.
  """
  use Mix.Task

  @shortdoc "Migrate + create/rotate the initial user"

  @impl Mix.Task
  def run([email, password]) do
    Mix.Task.run("app.config")
    Diogramos.Release.migrate()

    case Diogramos.Release.init(email, password) do
      {:ok, _user} -> :ok
      {:error, _} -> Mix.raise("Could not initialize user — see error above.")
    end
  end

  def run(_) do
    Mix.raise("usage: mix diogramos.init <email> <password>")
  end
end

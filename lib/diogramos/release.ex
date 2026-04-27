defmodule Diogramos.Release do
  @moduledoc """
  Operational tasks runnable from a release without Mix.

  ## Usage from a release

      bin/diogramos eval 'Diogramos.Release.migrate()'
      bin/diogramos eval 'Diogramos.Release.init("admin@example.com", "a-strong-password-here")'
      bin/diogramos eval 'Diogramos.Release.rollback(Diogramos.Repo, 20260427191720)'

  ## Usage from dev (Mix is available)

      mix run -e 'Diogramos.Release.init("you@example.com", "hello world!!")'

  `init/2` is idempotent: re-running with the same email confirms the
  account and rotates the password.
  """
  @app :diogramos

  alias Diogramos.Accounts.User
  alias Diogramos.Repo

  @doc "Runs all pending migrations against every configured Ecto repo."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls a single repo back to the given migration version."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Bootstraps an initial user with the given email + password and stamps
  `confirmed_at` so the account can log in immediately. Idempotent: if a
  user with that email already exists the password is rotated and
  confirmation is re-stamped.

  Pass either binaries or atoms (atoms get coerced via `to_string/1`).
  """
  @spec init(String.t() | atom(), String.t() | atom()) :: {:ok, User.t()} | {:error, term()}
  def init(email, password) do
    load_app()

    email = to_string(email)
    password = to_string(password)

    [repo | _] = repos()

    {:ok, result, _started} =
      Ecto.Migrator.with_repo(repo, fn _ -> upsert_user(email, password) end)

    case result do
      {:ok, %User{} = user} ->
        IO.puts("✓ ready: #{user.email}")
        {:ok, user}

      {:error, changeset} ->
        IO.puts("✗ failed: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc false
  def upsert_user(email, password) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(User, email: email) do
      nil ->
        %User{kind: "registered"}
        |> User.email_changeset(%{email: email}, validate_unique: true)
        |> User.password_changeset(%{password: password})
        |> Ecto.Changeset.put_change(:confirmed_at, now)
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.password_changeset(%{password: password})
        |> Ecto.Changeset.put_change(:confirmed_at, now)
        |> Repo.update()
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end

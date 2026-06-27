# Cap ExUnit's concurrency at the Repo pool size so async tests never wait on a
# sandbox connection (each owns one for its duration). Without this, the default
# `max_cases` (= cores × 2) on a many-core runner outruns a capped `POOL_SIZE`.
max_cases = Application.get_env(:diogramos, Diogramos.Repo)[:pool_size]

ExUnit.start(max_cases: max_cases)
Ecto.Adapters.SQL.Sandbox.mode(Diogramos.Repo, :manual)

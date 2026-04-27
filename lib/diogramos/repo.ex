defmodule Diogramos.Repo do
  use Ecto.Repo,
    otp_app: :diogramos,
    adapter: Ecto.Adapters.Postgres
end

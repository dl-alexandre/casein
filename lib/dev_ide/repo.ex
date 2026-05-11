defmodule DevIde.Repo do
  use Ecto.Repo,
    otp_app: :dev_ide,
    adapter: Ecto.Adapters.Postgres
end

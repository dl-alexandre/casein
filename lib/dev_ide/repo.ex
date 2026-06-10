defmodule DevIde.Repo do
  # Own top-level boundary so both the domain (DevIDE) and infra (DevIde)
  # layers can depend on it without creating a DevIDE <-> DevIde cycle.
  use Boundary, top_level?: true, deps: [], exports: []

  use Ecto.Repo,
    otp_app: :dev_ide,
    adapter: Ecto.Adapters.Postgres
end

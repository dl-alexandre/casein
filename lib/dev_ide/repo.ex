defmodule DevIDE.Repo do
  # Own top-level boundary so both the domain (DevIDE) and infra (DevIde)
  # layers can depend on it without creating a DevIDE <-> DevIde cycle.
  use Boundary, top_level?: true, deps: [], exports: [Adapter]

  use Ecto.Repo,
    otp_app: :dev_ide,
    adapter: Application.compile_env(:dev_ide, :repo_adapter, Ecto.Adapters.Postgres)
end

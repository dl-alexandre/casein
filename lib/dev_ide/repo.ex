defmodule DevIDE.Repo do
  # Own top-level boundary so the domain and application infrastructure can
  # depend on the Repo without creating a boundary cycle.
  use Boundary, top_level?: true, deps: [], exports: [Adapter]

  use Ecto.Repo,
    otp_app: :dev_ide,
    adapter: Application.compile_env(:dev_ide, :repo_adapter, Ecto.Adapters.Postgres)
end

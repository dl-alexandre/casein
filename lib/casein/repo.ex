defmodule Casein.Repo do
  # Own top-level boundary so the domain and application infrastructure can
  # depend on the Repo without creating a boundary cycle.
  use Boundary, top_level?: true, deps: [], exports: [Adapter]

  use Ecto.Repo,
    otp_app: :casein,
    adapter: Application.compile_env(:casein, :repo_adapter, Ecto.Adapters.Postgres)
end

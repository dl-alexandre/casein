defmodule CaseinWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CaseinWeb.ConnCase` with ExUnit async mode enabled, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CaseinWeb.Endpoint

      use CaseinWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CaseinWeb.ConnCase
      import Casein.Factory
    end
  end

  setup tags do
    Casein.Test.ManagerReqTest.setup(tags)
    Casein.DataCase.setup_sandbox(tags)
    reset_rate_limit_table()
    # Async tests rely on config/test.exs defaults (lines 77-79); sync tests may
    # override forward_auth/admins/on_devbox and need a per-test reset.
    unless tags[:async], do: reset_devbox_env_overrides()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp reset_rate_limit_table do
    case :ets.whereis(Casein.RateLimit) do
      :undefined -> :ok
      _table -> :ets.delete_all_objects(Casein.RateLimit)
    end
  end

  defp reset_devbox_env_overrides do
    Application.put_env(:casein, :forward_auth, false)
    Application.put_env(:casein, :admins, [])
    Application.put_env(:casein, :on_devbox, false)
  end
end

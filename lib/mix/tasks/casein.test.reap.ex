defmodule Mix.Tasks.Casein.Test.Reap do
  @moduledoc """
  Drops per-process Casein test databases whose owning OS process is gone.

      mix casein.test.reap

  Test databases are named `casein_test<partition>_<pid>`. A database is kept
  whenever `kill -0 <pid>` succeeds, including when a PID has been reused.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Drops test databases belonging to dead OS processes"
  @database_pattern ~r/^casein_test.*_([0-9]+)$/

  @impl Mix.Task
  def run([]) do
    {:ok, _started} = Application.ensure_all_started(:postgrex)

    {:ok, connection} = Postgrex.start_link(admin_connection_options())

    try do
      connection
      |> database_names()
      |> stale_database_names()
      |> Enum.each(&drop_database(connection, &1))
    after
      GenServer.stop(connection)
    end
  end

  def run(_args), do: Mix.raise("usage: mix casein.test.reap")

  @doc false
  def stale_database_names(database_names, pid_alive? \\ &pid_alive?/1) do
    Enum.filter(database_names, fn database_name ->
      case Regex.run(@database_pattern, database_name, capture: :all_but_first) do
        [pid] -> not pid_alive?.(pid)
        _other -> false
      end
    end)
  end

  @doc false
  def pid_alive?(pid) when is_binary(pid) do
    case System.find_executable("kill") do
      nil -> Mix.raise("casein.test.reap requires a kill executable")
      kill -> match?({_output, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
    end
  end

  defp admin_connection_options do
    test_config = Config.Reader.read!("config/test.exs", env: :test)

    repo_config =
      test_config
      |> Keyword.fetch!(:casein)
      |> Keyword.fetch!(Casein.Repo)

    if Keyword.has_key?(repo_config, :database) and
         not Keyword.has_key?(repo_config, :hostname) do
      Mix.raise("casein.test.reap only supports the PostgreSQL test repository")
    end

    repo_config
    |> Keyword.take([:username, :password, :hostname, :port, :socket_dir, :ssl, :parameters])
    |> Keyword.put(:database, "postgres")
  end

  defp database_names(connection) do
    %Postgrex.Result{rows: rows} =
      Postgrex.query!(
        connection,
        "SELECT datname FROM pg_database WHERE datname ~ '^casein_test.*_[0-9]+$'",
        []
      )

    List.flatten(rows)
  end

  defp drop_database(connection, database_name) do
    Postgrex.query!(connection, "DROP DATABASE #{quote_identifier(database_name)}", [])
    Mix.shell().info("dropped #{database_name}")
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
  end
end

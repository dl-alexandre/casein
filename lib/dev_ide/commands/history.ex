defmodule DevIDE.Commands.History do
  @moduledoc """
  Persistence boundary for command run records.

  argv values are pulled from `DevIDE.Commands.argv_for/1` only — the
  `start_run/1` API resolves the argv from the allowlisted command_id, so
  the wire payload cannot inject arbitrary args.
  """

  alias DevIDE.Commands
  alias DevIDE.Commands.History.Record

  @output_cap 64 * 1024

  @callback create(Record.t()) :: {:ok, Record.t()} | {:error, term()}
  @callback update(id :: String.t(), attrs :: map()) :: {:ok, Record.t()} | {:error, term()}
  @callback get(id :: String.t()) :: {:ok, Record.t()} | :error
  @callback recent_for(workspace_id :: String.t() | nil, limit :: pos_integer()) :: [Record.t()]
  @callback list(opts :: keyword()) :: [Record.t()]

  @spec start_run(map()) :: {:ok, Record.t()} | {:error, term()}
  def start_run(%{command_id: command_id} = attrs) do
    case Commands.argv_for(command_id) do
      {:ok, argv} ->
        record = %Record{
          id: Map.get(attrs, :id, Ecto.UUID.generate()),
          workspace_id: Map.fetch!(attrs, :workspace_id),
          actor_id: Map.get(attrs, :actor_id),
          command_id: command_id,
          argv: argv,
          status: "running",
          started_at: Map.get(attrs, :started_at, DateTime.utc_now()),
          metadata: Map.get(attrs, :metadata, %{}),
          output_truncated: false
        }

        impl().create(record)

      :error ->
        {:error, :not_allowed}
    end
  end

  def start_run(_), do: {:error, :invalid_attrs}

  @spec finish_run(String.t(), map()) :: {:ok, Record.t()} | {:error, term()}
  def finish_run(id, attrs) when is_binary(id) and is_map(attrs) do
    {output, truncated} = cap_output(Map.get(attrs, :output, ""))

    duration_ms =
      case {attrs[:started_at], attrs[:finished_at]} do
        {%DateTime{} = s, %DateTime{} = f} -> DateTime.diff(f, s, :millisecond)
        _ -> attrs[:duration_ms]
      end

    update_attrs =
      attrs
      |> Map.take([:status, :exit_code, :finished_at, :metadata])
      |> Map.put(:output, output)
      |> Map.put(:output_truncated, truncated)
      |> Map.put(:duration_ms, duration_ms)
      |> stringify(:status)
      |> stringify(:exit_code)

    impl().update(id, update_attrs)
  end

  def get(id), do: impl().get(id)
  def recent_for(workspace_id, limit \\ 20), do: impl().recent_for(workspace_id, limit)
  def list(opts \\ []), do: impl().list(opts)

  defp cap_output(nil), do: {nil, false}
  defp cap_output(""), do: {"", false}

  defp cap_output(s) when is_binary(s) and byte_size(s) <= @output_cap, do: {s, false}

  defp cap_output(s) when is_binary(s) do
    tail = binary_part(s, byte_size(s) - @output_cap, @output_cap)
    {"[…truncated]\n" <> tail, true}
  end

  defp stringify(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_atom(v) and not is_nil(v) -> Map.put(map, key, Atom.to_string(v))
      {:ok, v} when is_integer(v) -> Map.put(map, key, Integer.to_string(v))
      _ -> map
    end
  end

  defp impl,
    do:
      Application.get_env(
        :dev_ide,
        :command_history_adapter,
        DevIDE.Commands.History.MemoryAdapter
      )
end

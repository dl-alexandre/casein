defmodule DevIDE.CLI.Runtimes do
  @moduledoc "Read/control CLI for runtime orchestration records."

  alias DevIDE.Runtimes

  def run(["ls" | args]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, switches: [workspace: :string, status: :string])

    filters =
      %{
        "workspace_id" => opts[:workspace],
        "status" => opts[:status]
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    lines =
      Runtimes.list_runtimes(filters)
      |> Enum.map(fn runtime ->
        Enum.join(
          [
            runtime.id,
            runtime.workspace_id,
            runtime.status,
            runtime.host_id,
            runtime.repo || "-",
            runtime.branch || "-",
            runtime.isolation_mode,
            runtime.worktree_path || "-"
          ],
          "\t"
        )
      end)

    {:ok, Enum.join(["id\tworkspace\tstatus\thost\trepo\tbranch\tisolation\tpath" | lines], "\n")}
  end

  def run(["show", runtime_id]) do
    case Runtimes.get_runtime(runtime_id) do
      {:ok, runtime} ->
        payload =
          runtime
          |> Runtimes.payload()
          |> Map.put(
            :events,
            Enum.map(Runtimes.events_for(runtime_id), &Runtimes.event_payload/1)
          )

        {:ok, Jason.encode!(payload, pretty: true)}

      :error ->
        {:error, "runtime not found: #{runtime_id}"}
    end
  end

  def run(["expire", runtime_id | args]) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [reason: :string])

    case Runtimes.expire_runtime(runtime_id, %{"reason" => opts[:reason] || "operator_expired"}) do
      {:ok, runtime} -> {:ok, "expired\t#{runtime.id}\t#{runtime.status}"}
      :error -> {:error, "runtime not found: #{runtime_id}"}
      {:error, reason} -> {:error, "expire failed: #{reason}"}
    end
  end

  # Flags (e.g. `cleanup --stale`) belong to the bulk path — without this
  # clause they'd be swallowed as a runtime id by the single-id clause below.
  def run(["cleanup", "--" <> _ = flag | rest]), do: bulk_cleanup([flag | rest])

  def run(["cleanup", runtime_id]) do
    case Runtimes.cleanup_runtime(runtime_id) do
      {:ok, runtime} -> {:ok, "cleaned\t#{runtime.id}\t#{runtime.status}"}
      :error -> {:error, "runtime not found: #{runtime_id}"}
      {:error, reason} -> {:error, "cleanup failed: #{reason}"}
    end
  end

  def run(["cleanup" | args]), do: bulk_cleanup(args)

  def run(_), do: {:error, "usage: jx runtimes ls|show <id>|expire <id>|cleanup [id]"}

  defp bulk_cleanup(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: [stale: :boolean])

    expired =
      if opts[:stale] do
        Runtimes.expire_stale(DateTime.utc_now())
      else
        []
      end

    cleaned = Runtimes.cleanup_expired()

    {:ok, "expired=#{length(expired)} cleaned=#{length(cleaned)}"}
  end
end

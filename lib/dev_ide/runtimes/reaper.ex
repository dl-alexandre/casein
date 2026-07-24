defmodule Casein.Runtimes.Reaper do
  @moduledoc """
  Periodic sweeper for stale agent-worktree runtimes and their preview servers.

  Calls `Runtimes.expire_stale/2`, tears down git-clean worktrees whose preview
  port is idle, kills any orphaned preview-server OS processes recorded for the
  runtime, then invokes `Runtimes.cleanup_expired/2` for successfully reaped
  ids. Destructive cleanup is gated behind `:runtime_reaper_dry_run` (default
  `true`) so rollout can start log-only.
  """

  use GenServer

  require Logger

  alias Casein.Git
  alias Casein.Runtimes
  alias Casein.Runtimes.{PreviewKiller, PreviewServer, Runtime, WorktreeAlarm}
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.WorkspaceRecord

  @git_timeout_ms 10_000

  @default_sweep_interval_ms 3_600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec sweep_now(keyword()) :: map()
  def sweep_now(opts \\ []) do
    GenServer.call(__MODULE__, {:sweep_now, opts})
  end

  @impl true
  def init(_opts) do
    Logger.info(
      "[runtime-reaper] supervised under Casein.Supervision.PlatformServices " <>
        "enabled=#{enabled?()} dry_run=#{dry_run?()}"
    )

    if enabled?(), do: schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:sweep_now, opts}, _from, state) do
    {:reply, do_sweep(opts), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Logger.info(
      "[runtime-reaper] scheduled sweep (PlatformServices-supervised janitor; " <>
        "production caller for expire_stale/2 and cleanup_expired/2)"
    )

    _ = do_sweep([])
    _ = sweep_worktree_alarms()
    if enabled?(), do: schedule_sweep()
    {:noreply, state}
  end

  # Surface stale worktrees the runtime reaper does NOT remove — dirty ones (hold
  # uncommitted agent work) and unreported ones — as `workspace.agent_worktree_stale`
  # audit events. WorktreeAlarm never deletes; it is the triage signal so abandoned
  # dirty worktrees stop rotting invisibly. Removal of clean+idle+pushed worktrees is
  # handled out-of-band by scripts/cleanup-agent-worktrees.sh (systemd timer).
  defp sweep_worktree_alarms do
    result = WorktreeAlarm.sweep_now(emit: true)

    if result.alarm_count > 0 do
      Logger.info(
        "[runtime-reaper] worktree alarms scanned=#{result.scanned} " <>
          "alarms=#{result.alarm_count} emitted=#{result.emitted}"
      )
    end

    result
  rescue
    error ->
      Logger.warning("[runtime-reaper] worktree alarm sweep failed: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[runtime-reaper] worktree alarm sweep exited: #{inspect(reason)}")
      :error
  end

  defp do_sweep(opts) do
    dry_run? = Keyword.get(opts, :dry_run, dry_run?())
    now = DateTime.utc_now()
    ttl_seconds = Keyword.get(opts, :ttl_seconds, ttl_seconds())

    Logger.info(
      "[runtime-reaper] invoking Runtimes.expire_stale/2 ttl_seconds=#{ttl_seconds} dry_run=#{dry_run?}"
    )

    expired = Runtimes.expire_stale(now, ttl_seconds: ttl_seconds)

    candidates =
      Runtimes.list_runtimes(%{"status" => "expired"})
      |> Enum.filter(&reapable?/1)

    {torn_down_ids, skipped} =
      if dry_run? do
        Enum.each(candidates, fn runtime ->
          Logger.info(
            "[runtime-reaper] dry-run: would reap runtime #{runtime.id} " <>
              "worktree=#{runtime.worktree_path || "n/a"}"
          )
        end)

        {[], Enum.map(candidates, &%{runtime_id: &1.id, reason: :dry_run})}
      else
        Enum.reduce(candidates, {[], []}, fn runtime, {ids_acc, skipped_acc} ->
          case teardown_expired_runtime(runtime.id) do
            :ok ->
              {[runtime.id | ids_acc], skipped_acc}

            {:skip, reason} ->
              {ids_acc, [%{runtime_id: runtime.id, reason: reason} | skipped_acc]}

            {:error, reason} ->
              Logger.warning("[runtime-reaper] failed to reap #{runtime.id}: #{inspect(reason)}")
              {ids_acc, [%{runtime_id: runtime.id, reason: reason} | skipped_acc]}
          end
        end)
      end

    cleaned =
      cond do
        dry_run? ->
          Logger.info("[runtime-reaper] dry-run: skipping Runtimes.cleanup_expired/2")
          []

        torn_down_ids == [] ->
          []

        true ->
          only_ids = Enum.reverse(torn_down_ids)

          Logger.info(
            "[runtime-reaper] invoking Runtimes.cleanup_expired/2 only_ids=#{inspect(only_ids)}"
          )

          Runtimes.cleanup_expired(now, only_ids: only_ids)
      end

    %{
      expired: length(expired),
      reaped: length(cleaned),
      cleaned_ids: Enum.map(cleaned, & &1.id),
      skipped: Enum.reverse(skipped),
      dry_run: dry_run?
    }
  end

  defp teardown_expired_runtime(runtime_id) do
    Runtimes.with_runtime_lock(runtime_id, fn ->
      Runtimes.with_preview_port_lock(fn ->
        case Runtimes.get_runtime(runtime_id) do
          {:ok, %Runtime{status: "expired"} = runtime} ->
            if reapable?(runtime),
              do: teardown_runtime(runtime),
              else: {:skip, :no_longer_reapable}

          {:ok, %Runtime{}} ->
            {:skip, :no_longer_expired}

          :error ->
            {:skip, :runtime_missing}
        end
      end)
    end)
  end

  defp teardown_runtime(%Runtime{} = runtime) do
    with :ok <- teardown_preview_server(runtime) do
      teardown_worktree(runtime)
    end
  end

  defp reapable?(%Runtime{} = runtime) do
    agent_worktree_runtime?(runtime) and worktree_clean?(runtime) and
      preview_server_idle?(runtime)
  end

  defp agent_worktree_runtime?(%Runtime{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "kind") == "agent_worktree" or
      Map.get(metadata, "provisioning_model") == "agent_worktree"
  end

  defp agent_worktree_runtime?(_), do: false

  defp worktree_clean?(%Runtime{metadata: metadata, worktree_path: path}) do
    cond do
      Map.get(metadata || %{}, "worktree_status") == "dirty" ->
        false

      Map.get(metadata || %{}, "worktree_status") == "clean" ->
        true

      is_binary(path) and path != "" ->
        case Git.status_short(path) do
          {:ok, []} -> true
          {:ok, _} -> false
          _ -> false
        end

      true ->
        false
    end
  end

  defp preview_server_idle?(%Runtime{metadata: metadata}) do
    case PreviewServer.for_metadata(metadata || %{}) do
      %{"port" => port} when is_integer(port) -> not port_reachable?(port)
      _ -> true
    end
  end

  # worktree_path is app-registered; git worktree remove is tried before rm_rf fallback.
  # sobelow_skip ["Traversal.FileModule"]
  defp teardown_worktree(%Runtime{worktree_path: path, workspace_id: workspace_id})
       when is_binary(path) and path != "" do
    with {:ok, %WorkspaceRecord{host_path: root}} <- State.get(workspace_id),
         true <- is_binary(root) and root != "" do
      case git_worktree_remove(root, path) do
        {_, 0} ->
          :ok

        {output, status} ->
          Logger.warning(
            "[runtime-reaper] git worktree remove failed for #{path} " <>
              "(status=#{status}): #{String.slice(output, 0, 500)}"
          )

          case File.rm_rf(path) do
            {:ok, _} -> :ok
            {:error, reason, _} -> {:error, {:worktree_remove_failed, reason}}
          end
      end
    else
      _ -> {:error, :workspace_root_missing}
    end
  end

  defp teardown_worktree(_runtime), do: :ok

  defp git_worktree_remove(root, path) do
    task =
      Task.async(fn ->
        System.cmd("git", ["-C", root, "worktree", "remove", "--force", path],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {"timed out after #{@git_timeout_ms}ms", 124}
      {:exit, reason} -> {"command exited: #{inspect(reason)}", 125}
    end
  end

  defp teardown_preview_server(%Runtime{metadata: metadata}) do
    case PreviewServer.for_metadata(metadata || %{}) do
      %{} = server ->
        PreviewKiller.kill(server)

      _ ->
        :ok
    end
  end

  defp port_reachable?(port) when is_integer(port) and port > 0 and port < 65_536 do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp port_reachable?(_), do: false

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval_ms())
  end

  defp enabled? do
    Application.get_env(:casein, :runtime_reaper_enabled, false)
  end

  defp dry_run? do
    Application.get_env(:casein, :runtime_reaper_dry_run, true)
  end

  defp sweep_interval_ms do
    Application.get_env(
      :casein,
      :runtime_reaper_sweep_interval_ms,
      @default_sweep_interval_ms
    )
  end

  defp ttl_seconds do
    Application.get_env(:casein, :runtime_reaper_ttl_seconds, 60 * 60 * 6)
  end
end

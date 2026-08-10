defmodule Casein.Runtimes.WorktreeAlarm do
  @moduledoc """
  Detects stale agent worktrees that need human attention.

  Alarms on worktrees that are older than the TTL, have no live agent process,
  lack an exit handoff (`exit_status`, `wip:` commit, or push), and are either
  unreported or still dirty. Never deletes worktrees — log + audit only.
  """

  require Logger

  alias Casein.Audit
  alias Casein.Git
  alias Casein.Git.Inspector, as: GitInspector
  alias Casein.Runtimes
  alias Casein.Runtimes.Runtime
  alias Casein.Terminals.Backend
  alias Casein.Workspaces
  alias Casein.Workspaces.State.WorkspaceRecord

  @default_ttl_seconds 86_400

  @type alarm :: %{
          path: String.t(),
          workspace_id: String.t() | nil,
          runtime_id: String.t() | nil,
          branch: String.t() | nil,
          dirty: boolean(),
          reported: boolean(),
          process_alive: boolean(),
          exit_handoff: boolean(),
          age_seconds: non_neg_integer(),
          reasons: [String.t()]
        }

  @spec sweep_now(keyword()) :: %{
          alarms: [alarm()],
          scanned: non_neg_integer(),
          alarm_count: non_neg_integer(),
          ttl_seconds: pos_integer(),
          emitted: non_neg_integer()
        }
  def sweep_now(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, ttl_seconds())
    emit? = Keyword.get(opts, :emit, true)

    reported_index = reported_index()
    candidates = scan_roots(reported_index) ++ scan_reported_runtimes(reported_index)

    alarms =
      candidates
      |> Enum.uniq_by(& &1.path)
      |> Enum.filter(&alarm_candidate?(&1, now, ttl_seconds))
      |> Enum.map(&finalize_alarm(&1, ttl_seconds))

    emitted =
      if emit? do
        Enum.count(alarms, &emit_alarm/1)
      else
        0
      end

    %{
      alarms: alarms,
      scanned: length(candidates),
      alarm_count: length(alarms),
      ttl_seconds: ttl_seconds,
      emitted: emitted
    }
  end

  defp reported_index do
    Runtimes.list_runtimes(%{})
    |> Enum.filter(&agent_worktree_runtime?/1)
    |> Enum.reject(&(&1.status in ["cleaned", "expired"]))
    |> Enum.reduce(%{}, fn %Runtime{} = runtime, acc ->
      path = runtime.worktree_path || Map.get(runtime.metadata || %{}, "worktree_path")

      if is_binary(path) and path != "" do
        Map.put(acc, Path.expand(path), runtime)
      else
        acc
      end
    end)
  end

  defp scan_roots(reported_index) do
    worktree_roots()
    |> Enum.flat_map(&scan_root/1)
    |> Enum.map(fn path ->
      runtime = Map.get(reported_index, Path.expand(path))
      candidate(path, runtime)
    end)
  end

  defp scan_reported_runtimes(reported_index) do
    reported_index
    |> Map.values()
    |> Enum.map(fn %Runtime{} = runtime ->
      path = runtime.worktree_path || Map.get(runtime.metadata || %{}, "worktree_path")
      candidate(path, runtime)
    end)
    |> Enum.reject(&is_nil(&1.path))
  end

  defp scan_root(root) do
    root = Path.expand(root)

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&linked_worktree?/1)

      _ ->
        []
    end
  end

  defp linked_worktree?(path) do
    File.regular?(Path.join(path, ".git"))
  end

  defp candidate(path, runtime) when is_binary(path) do
    path = Path.expand(path)
    metadata = (runtime && runtime.metadata) || %{}
    dirty? = dirty?(path, metadata)
    branch = (runtime && runtime.branch) || Map.get(metadata, "branch") || git_branch(path)

    %{
      path: path,
      workspace_id: (runtime && runtime.workspace_id) || workspace_for_path(path),
      runtime_id: runtime && runtime.id,
      branch: branch,
      dirty: dirty?,
      reported: not is_nil(runtime),
      process_alive: process_alive?(path, runtime),
      exit_handoff: exit_handoff?(metadata, path),
      age_seconds: worktree_age_seconds(path, runtime),
      reasons: []
    }
  end

  defp candidate(_path, _runtime), do: %{path: nil}

  defp alarm_candidate?(%{path: path} = candidate, _now, ttl_seconds)
       when is_binary(path) do
    age_ok = candidate.age_seconds >= ttl_seconds
    stale = age_ok and not candidate.process_alive and not candidate.exit_handoff
    needs_attention = not candidate.reported or candidate.dirty

    stale and needs_attention
  end

  defp alarm_candidate?(_candidate, _now, _ttl_seconds), do: false

  defp finalize_alarm(candidate, ttl_seconds) do
    reasons =
      []
      |> maybe_reason(not candidate.reported, "unreported")
      |> maybe_reason(candidate.dirty, "dirty")
      |> maybe_reason(not candidate.process_alive, "no_process")
      |> maybe_reason(candidate.age_seconds >= ttl_seconds, "stale")

    Map.put(candidate, :reasons, reasons)
  end

  defp maybe_reason(reasons, true, label), do: [label | reasons]
  defp maybe_reason(reasons, false, _label), do: reasons

  defp dirty?(path, metadata) do
    case Map.get(metadata, "worktree_status") do
      "dirty" ->
        true

      "clean" ->
        false

      _ ->
        case Git.status_short(path) do
          {:ok, []} -> false
          {:ok, _} -> true
          _ -> false
        end
    end
  end

  defp exit_handoff?(metadata, path) do
    metadata = metadata || %{}
    status = Map.get(metadata, "exit_status")

    status in ["landed", "wip", "handoff"] or wip_commit?(path)
  end

  defp wip_commit?(path) do
    case System.cmd("git", ["-C", path, "log", "-1", "--pretty=%s"], stderr_to_stdout: true) do
      {message, 0} -> String.starts_with?(String.trim(message), "wip:")
      _ -> false
    end
  end

  defp process_alive?(_path, %Runtime{tmux_session_id: session})
       when is_binary(session) and session != "" do
    tmux_session_alive?(session)
  end

  defp process_alive?(_path, %Runtime{heartbeat_at: heartbeat, created_at: created})
       when not is_nil(heartbeat) or not is_nil(created) do
    last = heartbeat || created

    DateTime.compare(DateTime.add(last, process_grace_seconds(), :second), DateTime.utc_now()) ==
      :gt
  end

  defp process_alive?(_path, _runtime), do: false

  defp tmux_session_alive?(session) do
    backend = Backend.module()

    if Code.ensure_loaded?(backend) and function_exported?(backend, :session_exists?, 1) do
      backend.session_exists?(session)
    else
      false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp worktree_age_seconds(path, runtime) do
    fs_age = file_age_seconds(path)

    runtime_age =
      case runtime do
        %Runtime{} = rt ->
          last = rt.heartbeat_at || rt.created_at
          if last, do: DateTime.diff(DateTime.utc_now(), last, :second), else: fs_age

        _ ->
          fs_age
      end

    max(fs_age, runtime_age)
  end

  defp file_age_seconds(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} ->
        max(0, System.os_time(:second) - mtime)

      _ ->
        0
    end
  end

  defp workspace_for_path(path) do
    with {:ok, %GitInspector{} = info} <- GitInspector.inspect_cwd(path) do
      Workspaces.list_records()
      |> Enum.find_value(fn %WorkspaceRecord{} = record ->
        if related_to_workspace?(record, info), do: record.external_id
      end)
    else
      _ -> nil
    end
  end

  defp related_to_workspace?(%WorkspaceRecord{host_path: root}, %GitInspector{} = info) do
    root = clean_path(root)
    git_common_dir = clean_path(info.git_common_dir)

    cond do
      is_binary(root) and is_binary(git_common_dir) and under_root?(git_common_dir, root) ->
        true

      is_binary(root) ->
        case GitInspector.inspect_cwd(root) do
          {:ok, parent} -> same_path?(parent.git_common_dir, git_common_dir)
          :error -> false
        end

      true ->
        false
    end
  end

  defp git_branch(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        branch = String.trim(branch)
        if branch in ["", "HEAD"], do: nil, else: branch

      _ ->
        nil
    end
  end

  defp emit_alarm(%{path: path} = alarm) do
    workspace_id = alarm.workspace_id || "unknown"

    Logger.warning(
      "[worktree-alarm] stale agent worktree path=#{path} " <>
        "workspace=#{workspace_id} branch=#{alarm.branch || "n/a"} " <>
        "reasons=#{inspect(alarm.reasons)} age_s=#{alarm.age_seconds}"
    )

    _ =
      Audit.emit!(%{
        action: "workspace.agent_worktree_stale",
        workspace_id: workspace_id,
        target_type: "worktree",
        target_ref: path,
        metadata: %{
          "path" => path,
          "runtime_id" => alarm.runtime_id,
          "branch" => alarm.branch,
          "dirty" => alarm.dirty,
          "reported" => alarm.reported,
          "process_alive" => alarm.process_alive,
          "exit_handoff" => alarm.exit_handoff,
          "age_seconds" => alarm.age_seconds,
          "reasons" => alarm.reasons
        }
      })

    true
  end

  defp agent_worktree_runtime?(%Runtime{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "kind") == "agent_worktree" or
      Map.get(metadata, "provisioning_model") == "agent_worktree"
  end

  defp agent_worktree_runtime?(_), do: false

  defp worktree_roots do
    configured =
      Application.get_env(:casein, :agent_worktree_roots, []) ++ env_agent_worktree_roots()

    if configured != [] do
      configured
    else
      default_agent_worktree_roots()
    end
  end

  defp default_agent_worktree_roots do
    [Path.join(System.tmp_dir!(), "casein-agent-worktrees")]
  end

  defp env_agent_worktree_roots do
    case System.get_env("CASEIN_AGENT_WORKTREE_ROOTS") do
      nil ->
        []

      value ->
        String.split(value, [",", ":"], trim: true)
    end
  end

  defp under_root?(path, root) when is_binary(path) and is_binary(root) do
    path = Path.expand(path)
    root = Path.expand(root)
    rel = Path.relative_to(path, root)
    rel != path and not String.starts_with?(rel, "..")
  end

  defp under_root?(_, _), do: false

  defp same_path?(left, right) when is_binary(left) and is_binary(right),
    do: Path.expand(left) == Path.expand(right)

  defp same_path?(_, _), do: false

  defp clean_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp clean_path(_), do: nil

  defp ttl_seconds do
    Application.get_env(:casein, :worktree_alarm_ttl_seconds, @default_ttl_seconds)
  end

  defp process_grace_seconds do
    Application.get_env(:casein, :worktree_alarm_process_grace_seconds, 300)
  end
end

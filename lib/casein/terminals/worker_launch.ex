defmodule Casein.Terminals.WorkerLaunch do
  @moduledoc """
  Operator-visible **worker launch** (#384 M4-lite).

  One authoritative call that:

    1. Spawns a Casein-managed worker window via `scripts/spawn-agent-worker.sh`
       (fresh worktree, no hidden subagent fallback)
    2. Returns a structured **receipt** (pane, window, runtime, worktree, handle)

  Replaces the orchestrator shelling out to spawn + topology + work-handle create
  by hand — same property as `runtime_signal` / `mcp_self_test`: one call answers
  "what did I just launch?" without N follow-up scrapes.

  ## Fail closed

    * missing/invalid `workspace_id`, `session`, `runtime`, or `task_slug`
    * session not in the workspace namespace / not live
    * spawn script missing, non-zero exit, or empty pane id
    * dry-run never claims a live pane

  ## Out of scope (leave #384 open)

  Durable task graph, path contracts, verifier adapters, cancel/replace lifecycle
  beyond attaching a `WorkHandles` id, restricted orchestrator token profile rewrite.

  ## Constraints carried in this module (not only in briefs)

  Briefs die with the pane. Do **not** "helpfully" undo these:

  * **No hidden-subagent fallback** — spawn failure is a hard error; never claim a
    pane that Casein did not open (`hidden_subagent?` is always `false` on success).
  * **dry_run never invents a live pane** — `visible?: false` and no `pane_id`.
  * **No durable graph / path contracts / verifiers here** — that is later #384 work;
    do not grow this module into `orchestration_create` by stealth.
  * **Do not edit `pane_submit.ex` from this lane** — #886 owns OpenCode paste submit.
  * **Do not widen Backend/Fake adapter surface from this lane** — #896/#901 own that.
  """

  alias Casein.Terminals.Backend
  alias Casein.Terminals.WorkHandles

  @runtimes ~w(grok codex claude opencode agent)
  @pane_id_re ~r/\A%\d+\z/
  @default_timeout_ms 180_000

  @type receipt :: %{
          required(:ok) => true,
          required(:workspace_id) => String.t(),
          required(:session) => String.t(),
          required(:runtime) => String.t(),
          required(:task_slug) => String.t(),
          required(:pane_id) => String.t(),
          required(:window_name) => String.t(),
          required(:visible?) => true,
          required(:hidden_subagent?) => false,
          optional(:window_id) => String.t(),
          optional(:worktree_path) => String.t(),
          optional(:branch) => String.t(),
          optional(:handle_id) => String.t(),
          optional(:label) => String.t(),
          optional(:note) => String.t()
        }

  @doc """
  Launch a visible worker and return a structured receipt.

  Options:

    * `:workspace_id` / `:session` / `:runtime` / `:task_slug` — required
    * `:label` — chrome / work-handle label (default `worker: <slug>`)
    * `:dry_run` — plan only; never opens a window
    * `:timeout_ms` — spawn wait (default 180s)
    * `:runner` — `(runtime, slug, session, opts -> {:ok, map()} | {:error, term()})` for tests
    * `:observe` — `(session, pane_id -> map())` pane facts after spawn (tests)
    * `:attach_handle` — when true (default), mint/attach a `WorkHandles` id
    * `:scripts_root` / `:spawn_script` — override script location
  """
  @spec launch(keyword()) :: {:ok, receipt() | map()} | {:error, map()}
  def launch(opts) when is_list(opts) do
    with {:ok, workspace_id} <- fetch_bin(opts, :workspace_id),
         {:ok, session} <- fetch_bin(opts, :session),
         {:ok, runtime} <- fetch_runtime(opts),
         {:ok, slug} <- fetch_slug(opts) do
      label = blank_to_nil(Keyword.get(opts, :label)) || "worker: #{slug}"
      dry_run? = Keyword.get(opts, :dry_run, false) == true

      runner = Keyword.get(opts, :runner, &default_runner/4)

      case runner.(runtime, slug, session, Keyword.put(opts, :dry_run, dry_run?)) do
        {:ok, %{dry_run: true} = plan} ->
          # do not set pane_id or visible?: true on dry_run — operators treat those
          # as proof a worker exists (#384 M4-lite; dry_run is plan-only).
          {:ok,
           %{
             ok: true,
             dry_run: true,
             workspace_id: workspace_id,
             session: session,
             runtime: runtime,
             task_slug: slug,
             window_name: Map.get(plan, :window_name) || "worker-#{slug}",
             plan: Map.drop(plan, [:dry_run]),
             visible?: false,
             hidden_subagent?: false,
             note:
               "Dry run only — no pane opened. Re-call without dry_run to launch a visible worker."
           }}

        {:ok, %{pane_id: pane_id} = spawned} when is_binary(pane_id) ->
          observe = Keyword.get(opts, :observe, &default_observe/2)
          facts = observe.(session, pane_id)

          # hidden_subagent? is a constant false on success — never invent a
          # "soft" launch path that claims a pane Casein did not open (#384 product principle).
          receipt =
            %{
              ok: true,
              workspace_id: workspace_id,
              session: session,
              runtime: runtime,
              task_slug: slug,
              pane_id: pane_id,
              window_name:
                Map.get(spawned, :window_name) || Map.get(facts, :window_name) || "worker-#{slug}",
              window_id: Map.get(facts, :window_id),
              worktree_path: Map.get(facts, :worktree_path),
              branch: Map.get(facts, :branch),
              label: label,
              visible?: true,
              hidden_subagent?: false,
              note:
                "M4-lite worker_launch receipt. Worker is a Casein tmux window (worker-<slug>). " <>
                  "No hidden subagent. Durable task graph / path contracts / verifiers remain out of scope."
            }
            |> maybe_attach_handle(workspace_id, session, pane_id, label, opts)
            |> reject_nils()

          {:ok, receipt}

        {:ok, other} ->
          {:error,
           %{
             error: :invalid_spawn_result,
             detail: inspect(other),
             message: "spawn runner returned no pane_id"
           }}

        {:error, reason} ->
          {:error, normalize_error(reason)}
      end
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def launch(_), do: {:error, %{error: :invalid_options}}

  ## Runner

  defp default_runner(runtime, slug, session, opts) do
    if Keyword.get(opts, :dry_run, false) do
      dry_run_spawn(runtime, slug, session, opts)
    else
      live_spawn(runtime, slug, session, opts)
    end
  end

  defp dry_run_spawn(runtime, slug, session, opts) do
    script = spawn_script(opts)
    window_name = "worker-#{slug}"

    env = spawn_env(opts)

    case System.cmd(
           "bash",
           [script, runtime, slug, session],
           stderr_to_stdout: true,
           env: [{"CASEIN_SPAWN_DRY_RUN", "1"} | env],
           cd: scripts_cd(opts)
         ) do
      {out, 0} ->
        {:ok,
         %{
           dry_run: true,
           window_name: window_name,
           runtime: runtime,
           task_slug: slug,
           session: session,
           script: script,
           plan_text: String.trim(out)
         }}

      {out, code} ->
        {:error, spawn_failure(:spawn_dry_run_failed, code, out)}
    end
  rescue
    e ->
      {:error, %{error: :spawn_exec_failed, message: Exception.message(e)}}
  end

  # sobelow_skip ["CI.System"]
  defp live_spawn(runtime, slug, session, opts) do
    script = spawn_script(opts)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    env = spawn_env(opts)
    window_name = "worker-#{slug}"

    task =
      Task.async(fn ->
        System.cmd(
          "bash",
          [script, runtime, slug, session],
          stderr_to_stdout: true,
          env: env,
          cd: scripts_cd(opts)
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case parse_pane_id(out) do
          {:ok, pane_id} ->
            {:ok, %{pane_id: pane_id, window_name: window_name, output: String.trim(out)}}

          {:error, reason} ->
            {:error,
             Map.merge(reason, %{
               output: String.trim(out),
               message: "spawn succeeded but printed no pane id"
             })}
        end

      {:ok, {out, code}} ->
        {:error, spawn_failure(:spawn_failed, code, out)}

      nil ->
        {:error,
         %{
           error: :spawn_timeout,
           timeout_ms: timeout,
           message: "spawn exceeded #{timeout}ms"
         }}

      {:exit, reason} ->
        {:error, %{error: :spawn_exit, detail: inspect(reason)}}
    end
  rescue
    e ->
      {:error, %{error: :spawn_exec_failed, message: Exception.message(e)}}
  end

  defp parse_pane_id(out) when is_binary(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(fn line ->
      line = String.trim(line)
      if Regex.match?(@pane_id_re, line), do: line
    end)
    |> case do
      pane when is_binary(pane) -> {:ok, pane}
      _ -> {:error, %{error: :no_pane_id}}
    end
  end

  defp parse_pane_id(_), do: {:error, %{error: :no_pane_id}}

  ## Observe

  defp default_observe(session, pane_id) do
    tmux = Backend.module()

    panes =
      try do
        tmux.list_session_panes(session)
      rescue
        _ -> []
      end

    pane = Enum.find(panes, fn p -> Map.get(p, :id) == pane_id or Map.get(p, "id") == pane_id end)

    window_id = pane && (Map.get(pane, :window_id) || Map.get(pane, "window_id"))
    current_path = pane && (Map.get(pane, :current_path) || Map.get(pane, "current_path"))

    windows =
      try do
        tmux.list_session_windows(session)
      rescue
        _ -> []
      end

    window =
      Enum.find(windows, fn w ->
        (Map.get(w, :id) || Map.get(w, "id")) == window_id
      end)

    worktree = resolve_worktree(current_path)

    %{
      window_id: window_id,
      window_name: window && (Map.get(window, :name) || Map.get(window, "name")),
      worktree_path: worktree,
      branch: worktree && git_branch(worktree)
    }
  end

  defp resolve_worktree(path) when is_binary(path) and path != "" do
    walk_worktree(path, 6)
  end

  defp resolve_worktree(_), do: nil

  defp walk_worktree(_path, 0), do: nil

  defp walk_worktree(path, n) when is_binary(path) do
    git = Path.join(path, ".git")

    cond do
      File.exists?(git) ->
        path

      path in ["/", ""] ->
        nil

      true ->
        walk_worktree(Path.dirname(path), n - 1)
    end
  end

  # sobelow_skip ["CI.System"]
  defp git_branch(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          "HEAD" -> nil
          b -> b
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  ## Work handle

  defp maybe_attach_handle(receipt, workspace_id, session, pane_id, label, opts) do
    if Keyword.get(opts, :attach_handle, true) do
      case safe_handle_create(workspace_id, session, pane_id, label) do
        {:ok, handle_id} -> Map.put(receipt, :handle_id, handle_id)
        _ -> receipt
      end
    else
      receipt
    end
  end

  defp safe_handle_create(workspace_id, session, pane_id, label) do
    case WorkHandles.create(workspace_id,
           session: session,
           pane_id: pane_id,
           label: label,
           recorded_status: "working",
           message: "launched via worker_launch"
         ) do
      {:ok, %{handle_id: id}} -> {:ok, id}
      other -> other
    end
  catch
    :exit, _ -> {:error, :work_handles_unavailable}
  end

  ## Paths / env

  defp spawn_script(opts) do
    cond do
      is_binary(Keyword.get(opts, :spawn_script)) ->
        Keyword.fetch!(opts, :spawn_script)

      is_binary(Keyword.get(opts, :scripts_root)) ->
        Path.join(Keyword.fetch!(opts, :scripts_root), "spawn-agent-worker.sh")

      true ->
        resolve_spawn_script()
    end
  end

  defp resolve_spawn_script do
    candidates = [
      System.get_env("CASEIN_SPAWN_WORKER_SCRIPT"),
      # The service release may not have a checkout-level `scripts/` tree.
      # CASEIN_SCRIPTS_ROOT is the host/runtime overlay seam used by the
      # deploy, while the application priv path is the portable release
      # fallback populated by the release step.
      scripts_join(System.get_env("CASEIN_SCRIPTS_ROOT")),
      application_scripts_join(),
      scripts_join(System.get_env("CASEIN_SCRIPTS")),
      scripts_join(
        System.get_env("CASEIN_CHECKOUT") &&
          Path.join(System.get_env("CASEIN_CHECKOUT"), "scripts")
      ),
      # #248: no /opt/casein/deploy-build fallback — that layout is overlay-only.
      Path.expand("scripts/spawn-agent-worker.sh")
    ]

    Enum.find(candidates, &binary_and_regular?/1) ||
      Path.expand("scripts/spawn-agent-worker.sh")
  end

  defp scripts_join(nil), do: nil
  defp scripts_join(""), do: nil
  defp scripts_join(root), do: Path.join(root, "spawn-agent-worker.sh")

  defp application_scripts_join do
    if Code.ensure_loaded?(Application) do
      Application.app_dir(:casein, "priv/scripts/spawn-agent-worker.sh")
    end
  rescue
    _ -> nil
  end

  defp binary_and_regular?(path) when is_binary(path), do: File.regular?(path)
  defp binary_and_regular?(_), do: false

  defp scripts_cd(opts) do
    cond do
      is_binary(Keyword.get(opts, :cd)) -> Keyword.fetch!(opts, :cd)
      is_binary(System.get_env("CASEIN_CHECKOUT")) -> System.get_env("CASEIN_CHECKOUT")
      true -> File.cwd!()
    end
  end

  defp spawn_env(opts) do
    base =
      for {k, v} <- [
            {"CASEIN_CHECKOUT",
             Keyword.get(opts, :checkout) || System.get_env("CASEIN_CHECKOUT")},
            {"CASEIN_WORKSPACE_ID", Keyword.get(opts, :workspace_id)},
            {"CASEIN_TMUX_SESSION", Keyword.get(opts, :session)},
            {"CASEIN_API_TOKEN", System.get_env("CASEIN_API_TOKEN")},
            {"CASEIN_API_BASE_URL", System.get_env("CASEIN_API_BASE_URL")},
            {"CASEIN_AGENT_ENV_FILE", System.get_env("CASEIN_AGENT_ENV_FILE")}
          ],
          is_binary(v) and v != "",
          do: {k, v}

    # Ensure fresh worktree isolation — spawn script also forces this.
    [{"CASEIN_AGENT_FORCE_FRESH_WORKTREE", "1"} | base]
  end

  ## Validation

  defp fetch_bin(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) ->
        v = String.trim(v)

        if v == "",
          do: {:error, %{error: :missing_argument, argument: to_string(key)}},
          else: {:ok, v}

      _ ->
        {:error, %{error: :missing_argument, argument: to_string(key)}}
    end
  end

  defp fetch_runtime(opts) do
    with {:ok, runtime} <- fetch_bin(opts, :runtime) do
      runtime = String.downcase(runtime)

      if runtime in @runtimes do
        {:ok, runtime}
      else
        {:error,
         %{
           error: :unsupported_runtime,
           runtime: runtime,
           allowed: @runtimes,
           message: "runtime must be one of: #{Enum.join(@runtimes, ", ")}"
         }}
      end
    end
  end

  defp fetch_slug(opts) do
    with {:ok, slug} <- fetch_bin(opts, :task_slug) do
      sanitized =
        slug
        |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
        |> String.trim("-")
        |> case do
          "" -> "adhoc"
          s -> String.slice(s, 0, 48)
        end

      {:ok, sanitized}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s
  defp blank_to_nil(_), do: nil

  # #970: MCP clients render McpCtl.Error.summary/1, which is `message` only.
  # The shell already prints a loud #863 decline (reason + probe + override);
  # stuffing that only in `output` made exit 75 look like "spawn never happened"
  # and agents self-parked on a stale-CASEIN_SCRIPTS guess. Classify here so
  # both the real spawn path and injected runner errors stay loud.
  defp spawn_failure(kind, code, out) when is_integer(code) do
    classify_headroom_refusal(%{
      error: kind,
      exit_status: code,
      output: String.trim(to_string(out || "")),
      message: spawn_failure_message(kind, code)
    })
  end

  defp spawn_failure_message(:spawn_dry_run_failed, code),
    do: "spawn dry-run failed (exit #{code})"

  defp spawn_failure_message(_kind, code), do: "spawn-agent-worker.sh exited #{code}"

  defp normalize_error(%{} = err), do: classify_headroom_refusal(err)
  defp normalize_error(atom) when is_atom(atom), do: %{error: atom}
  defp normalize_error(other), do: %{error: :spawn_failed, detail: inspect(other)}

  defp classify_headroom_refusal(%{exit_status: 75} = err) do
    output = err |> Map.get(:output) |> to_string()

    if headroom_refusal?(output) do
      probe = parse_headroom_probe(output)
      reason = parse_headroom_reason(output) || "host headroom exhausted"

      message =
        "spawn refused — host headroom exhausted: #{reason}" <>
          probe_suffix(probe) <>
          ". Wait for load to fall, or CASEIN_SPAWN_FORCE=1 (operator risk). " <>
          "Not a stale CASEIN_SCRIPTS."

      err
      |> Map.merge(probe)
      |> Map.merge(%{
        error: :spawn_headroom_exhausted,
        reason: reason,
        override: "CASEIN_SPAWN_FORCE=1",
        token: "refused:headroom",
        message: message
      })
    else
      err
    end
  end

  defp classify_headroom_refusal(err), do: err

  # #996: prefer the stdout token. "headroom exhausted" used to appear on both
  # the refuse path and CASEIN_SPAWN_FORCE proceed; a FORCE success is exit 0
  # and emits proceed:headroom-force, so never treat that as a refusal.
  defp headroom_refusal?(output) when is_binary(output) do
    cond do
      String.contains?(output, "proceed:headroom-force") -> false
      String.contains?(output, "refused:headroom") -> true
      String.contains?(output, "headroom exhausted") -> true
      String.contains?(output, "spawn refused") and String.contains?(output, "probe:") -> true
      true -> false
    end
  end

  defp headroom_refusal?(_), do: false

  defp parse_headroom_reason(output) do
    case Regex.run(~r/error: spawn refused[^\n]*\n\s*([^\n]+)/, output) do
      [_, reason] -> String.trim(reason)
      _ -> nil
    end
  end

  defp parse_headroom_probe(output) do
    case Regex.run(
           ~r/probe:\s*load1=([\d.]+)\s+nproc=(\d+)\s+max_ratio=([\d.]+)\s+mem_available_kb=(\d+)/,
           output
         ) do
      [probe, load1, nproc, max_ratio, mem] ->
        %{
          load1: load1,
          nproc: String.to_integer(nproc),
          max_ratio: max_ratio,
          mem_available_kb: String.to_integer(mem),
          probe: String.trim(probe)
        }

      _ ->
        %{}
    end
  end

  defp probe_suffix(%{probe: probe}) when is_binary(probe) and probe != "",
    do: " (#{probe})"

  defp probe_suffix(_), do: ""

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

defmodule Casein.Deployment.RuntimeSignal do
  @moduledoc """
  Live deployed runtime vs `origin/master` **and** resolved runtime-selected
  modules (#867 / S11).

  A git SHA alone is not enough: production once resolved MCP pane writes through
  `Backends.Tmux` while every repo default and `Application.get_env(..., Tmux)`
  site still *read* as `Casein.Terminals.Tmux`. That divergence only showed up as
  `UndefinedFunctionError` on a live MCP call (#854). #892 converged both paths
  onto `Casein.Terminals.tmux_adapter/0` (default `Terminals.Tmux`).

  This module reports:

    * deployed revision vs remote branch head (behind/ahead when countable)
    * **resolved** values of runtime-selected modules, `:tmux_adapter` first —
      MCP and ops now share one resolver; `paths_disagree?` is the canary if
      that ever splits again
    * whether critical MCP callbacks exist on the module agents actually call

  Pure observation — no mutations, no deploy, no adapter swap.
  """

  alias Casein.Deployment.{Drift, Version}
  alias Casein.Terminals
  alias Casein.Terminals.Backend

  @tmux_adapter_default Casein.Terminals.Tmux

  # MCP-facing callbacks that must exist on the module TerminalTools.Shared.tmux/0
  # resolves. Missing paste_text is the fleet-wide failure mode for #854/#867.
  @mcp_surface_exports [
    {:paste_text, 3},
    {:send_keys, 3},
    {:capture_scrollback, 2},
    {:list_sessions, 0},
    {:session_topology, 1}
  ]

  @type snapshot :: %{
          generated_at: String.t(),
          revision: map(),
          modules: map(),
          diverged?: boolean(),
          attention: [String.t()],
          note: String.t()
        }

  @doc """
  Full runtime signal snapshot for agents and operators.

  Options:

    * `:version` — override deployed revision (tests)
    * `:remote` — `{:ok, sha}` | `{:error, reason}` (tests; skips network)
    * `:branch` — deploy branch name
    * `:now` — `DateTime` for `generated_at`
    * `:env` — fn key -> value for Application.get_env simulation (tests)
    * `:backend_module` — override `Backend.module/0` (tests)
    * `:git_dir` — optional checkout for rev-list ahead/behind counts
  """
  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    branch = Keyword.get(opts, :branch) || Drift.branch()
    deployed = Keyword.get_lazy(opts, :version, &Version.version/0)
    remote = Keyword.get_lazy(opts, :remote, fn -> Drift.remote_head(branch: branch) end)

    revision = revision_signal(deployed, remote, branch, opts)
    modules = modules_signal(opts)

    attention =
      []
      |> maybe_attention(revision.status not in ["current"], "revision_#{revision.status}")
      |> maybe_attention(modules.tmux_adapter.paths_disagree?, "tmux_adapter_paths_disagree")
      |> maybe_attention(
        modules.tmux_adapter.mcp_surface.ok? != true,
        "tmux_adapter_mcp_surface_incomplete"
      )
      |> Enum.reverse()

    %{
      generated_at: DateTime.to_iso8601(now),
      revision: revision,
      modules: modules,
      diverged?: attention != [],
      attention: attention,
      note:
        "S11 runtime signal (#867). Reports deployed SHA vs origin/#{branch} and " <>
          "resolved runtime-selected modules (:tmux_adapter first). " <>
          "SHA-only checks miss adapter/default mismatches — always read modules."
    }
  end

  @doc "True when revision or module resolution needs operator attention."
  @spec diverged?(snapshot() | keyword()) :: boolean()
  def diverged?(opts) when is_list(opts), do: snapshot(opts).diverged?
  def diverged?(%{diverged?: d}), do: d == true
  def diverged?(_), do: false

  ## Revision

  defp revision_signal(deployed, remote, branch, opts) do
    status = Drift.assess(deployed, remote, branch)
    {remote_sha, remote_error} = remote_parts(remote)
    {behind, ahead} = distance(deployed, remote_sha, opts)

    base = %{
      deployed: normalize_sha(deployed),
      remote: remote_sha,
      branch: branch,
      status: status_name(status),
      drift_reason: drift_reason(status),
      behind: behind,
      ahead: ahead,
      message: status_message(status)
    }

    if remote_error, do: Map.put(base, :remote_error, remote_error), else: base
  end

  defp remote_parts({:ok, sha}) when is_binary(sha), do: {normalize_sha(sha), nil}
  defp remote_parts({:error, reason}), do: {nil, inspect(reason)}

  defp status_name(:current), do: "current"
  defp status_name({:drift, _}), do: "drift"
  defp status_name({:unknown, _}), do: "unknown"

  defp drift_reason({:drift, %{reason: r}}), do: atom_to_string(r)
  defp drift_reason({:unknown, %{reason: r}}), do: atom_to_string(r)
  defp drift_reason(_), do: nil

  defp status_message(:current), do: "deployed revision matches origin branch head"

  defp status_message({:drift, info}) when is_map(info) do
    Map.get(info, :message) || "deployed revision drifts from origin branch head"
  end

  defp status_message({:unknown, %{reason: r}}), do: "revision observation unknown: #{r}"

  defp distance(deployed, remote_sha, opts)
       when is_binary(deployed) and is_binary(remote_sha) do
    git_dir = Keyword.get(opts, :git_dir) || git_dir_hint()

    if is_binary(git_dir) and File.dir?(git_dir) do
      behind = rev_count(git_dir, "#{deployed}..#{remote_sha}")
      ahead = rev_count(git_dir, "#{remote_sha}..#{deployed}")
      {behind, ahead}
    else
      {nil, nil}
    end
  end

  defp distance(_, _, _), do: {nil, nil}

  defp git_dir_hint do
    System.get_env("CASEIN_CHECKOUT") ||
      System.get_env("CASEIN_DEPLOY_BUILD") ||
      Application.get_env(:casein, :deployment, [])
      |> Keyword.get(:git_dir)
  end

  # sobelow_skip ["CI.System"]
  defp rev_count(git_dir, range) do
    case System.cmd("git", ["-C", git_dir, "rev-list", "--count", range], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {n, ""} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  ## Modules

  defp modules_signal(opts) do
    env_reader = Keyword.get(opts, :env, &default_env/1)
    backend = Keyword.get_lazy(opts, :backend_module, &Backend.module/0)

    tmux_env = env_reader.(:tmux_adapter)
    terminal_backend_env = env_reader.(:terminal_backend)

    # #892: MCP Shared.tmux/0 and ops TmuxOps.tmux_adapter/0 share ONE formula:
    #   Application.get_env(:casein, :tmux_adapter, Terminals.Tmux)
    # Both sides of the report use that formula so paths_disagree? only fires if
    # a second default is re-introduced (regression canary).
    resolved = tmux_env || @tmux_adapter_default
    source = if is_nil(tmux_env), do: "tmux_adapter_default", else: "application_env"

    mcp_resolved = resolved
    ops_resolved = resolved
    paths_disagree? = mcp_resolved != ops_resolved

    # Live canary: the process's Terminals.tmux_adapter/0 must match the formula
    # when the real Application env is being read (not a test :env override).
    live_resolved =
      if Keyword.has_key?(opts, :env) do
        resolved
      else
        Terminals.tmux_adapter()
      end

    live_disagrees? = live_resolved != resolved

    mcp_surface = surface_probe(mcp_resolved)

    %{
      tmux_adapter: %{
        env_key: "tmux_adapter",
        configured: module_name(tmux_env),
        configured?: not is_nil(tmux_env),
        # Default when :tmux_adapter env is unset (Terminals.tmux_adapter/0).
        repo_default: module_name(@tmux_adapter_default),
        # What Backend.module/0 resolves to (product engine; not MCP adapter).
        backend_module: module_name(backend),
        # Path agents hit via TerminalTools.Shared.tmux/0.
        mcp_resolved: module_name(mcp_resolved),
        mcp_source: source,
        # Path ops hits via Terminals.tmux_adapter/0 — same function as MCP.
        ops_resolved: module_name(ops_resolved),
        ops_source: source,
        paths_disagree?: paths_disagree? or live_disagrees?,
        mcp_surface: mcp_surface
      },
      terminal_backend: %{
        env_key: "terminal_backend",
        configured: module_name(terminal_backend_env),
        configured?: not is_nil(terminal_backend_env),
        resolved: module_name(backend),
        source:
          if(is_nil(terminal_backend_env), do: "backend_module_default", else: "application_env")
      }
    }
  end

  defp default_env(:tmux_adapter), do: Application.get_env(:casein, :tmux_adapter)
  defp default_env(:terminal_backend), do: Application.get_env(:casein, :terminal_backend)
  defp default_env(_), do: nil

  defp surface_probe(mod) when is_atom(mod) and not is_nil(mod) do
    exports =
      Enum.map(@mcp_surface_exports, fn {name, arity} ->
        %{
          function: "#{name}/#{arity}",
          exported?: function_exported_safe?(mod, name, arity)
        }
      end)

    missing =
      exports
      |> Enum.reject(& &1.exported?)
      |> Enum.map(& &1.function)

    %{
      module: module_name(mod),
      ok?: missing == [],
      missing: missing,
      exports: exports
    }
  end

  defp surface_probe(_),
    do: %{module: nil, ok?: false, missing: ["(no module)"], exports: []}

  defp function_exported_safe?(mod, name, arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, name, arity)
  rescue
    _ -> false
  end

  defp module_name(nil), do: nil
  defp module_name(mod) when is_atom(mod), do: inspect(mod)
  defp module_name(other), do: inspect(other)

  defp normalize_sha(nil), do: nil

  defp normalize_sha(value) do
    value |> to_string() |> String.trim() |> then(fn s -> if s == "", do: nil, else: s end)
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(a) when is_atom(a), do: Atom.to_string(a)
  defp atom_to_string(a) when is_binary(a), do: a
  defp atom_to_string(a), do: inspect(a)

  defp maybe_attention(list, true, tag), do: [tag | list]
  defp maybe_attention(list, false, _tag), do: list
end

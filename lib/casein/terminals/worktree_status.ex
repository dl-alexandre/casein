defmodule Casein.Terminals.WorktreeStatus do
  @moduledoc """
  Read-only structured Git inspection for one worker pane (#384 M4.2).

  One call answers "what is this worker's tree?" by joining `WorkerStatus`
  identity with `Git.Inspector` — the same inspector `casein://fleet/summary`
  already uses. Not a second git scraper and not a second fleet classifier.

  ## Kind discipline

    * `inspect_state: unknown` means the tree could not be inspected. It is
      **never** quiet, idle, clean, or "not ahead".
    * `ahead: nil` (no upstream) is not `ahead: 0` — squash-merge + deleted
      remote branch must not look like unpushed work.
    * `commits_not_on_origin?` is omitted when `ahead` is not an integer.
    * This slice does **not** emit dirty/clean — that needs porcelain and is
      later inspection (`worktree_changed_paths`).

  ## Out of scope (leave #384 open)

  changed_paths / diff, `worker_replace`, `worker_send_contract`, durable
  graph / path contracts / verifiers, restricted orchestrator profile.
  """

  alias Casein.Git.Inspector
  alias Casein.Terminals.WorkerStatus

  @type payload :: %{
          workspace_id: String.t(),
          session: String.t(),
          generated_at: String.t(),
          found?: boolean(),
          pane_id: String.t() | nil,
          window_id: String.t() | nil,
          window_name: String.t() | nil,
          worktree_path: String.t() | nil,
          git: map(),
          note: String.t()
        }

  @doc """
  Project an enriched topology plus Git.Inspector into a worktree_status payload.

  Options:

    * `:workspace_id` / `:session` / `:pane` — required identity
    * `:window_id` — optional disambiguator
    * `:now` — `DateTime` for `generated_at`
    * `:inspect` — `(path -> {:ok, map() | Inspector.t()} | :error)` for tests
  """
  @spec project(map(), keyword()) :: payload()
  def project(topology, opts \\ []) when is_map(topology) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    pane_id = Keyword.fetch!(opts, :pane)
    window_id = Keyword.get(opts, :window_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    inspect_fun = Keyword.get(opts, :inspect, &default_inspect/1)

    case WorkerStatus.find_pane(topology, pane_id, window_id) do
      nil ->
        not_found(workspace_id, session, pane_id, window_id, now)

      pane ->
        found(workspace_id, session, pane, topology, inspect_fun, now)
    end
  end

  ## Internals

  defp found(workspace_id, session, pane, topology, inspect_fun, now) do
    window = window_for(pane, topology)
    worktree = blank_to_nil(pane_field(pane, :worktree_path))

    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      found?: true,
      pane_id: pane_field(pane, :id),
      window_id: pane_field(pane, :window_id) || window_field(window, :id),
      window_name:
        pane_field(pane, :window_name) || window_field(window, :name) ||
          window_field(window, "name"),
      worktree_path: worktree,
      git: git_json(worktree, inspect_fun),
      note:
        "M4.2 worktree_status. Joins WorkerStatus identity + Git.Inspector " <>
          "(same inspector as casein://fleet/summary). inspect_state unknown ≠ clean " <>
          "and ≠ not-ahead. changed_paths / worker_replace remain out of scope."
    }
    |> reject_nils()
  end

  defp not_found(workspace_id, session, pane_id, window_id, now) do
    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: DateTime.to_iso8601(now),
      found?: false,
      pane_id: pane_id,
      window_id: window_id,
      git: unknown_git("pane_not_found"),
      note:
        "M4.2 worktree_status: pane not found in session topology. " <>
          "inspect_state unknown — not clean, not quiet."
    }
    |> reject_nils()
  end

  defp git_json(nil, _inspect_fun), do: unknown_git("no_worktree")
  defp git_json("", _inspect_fun), do: unknown_git("no_worktree")

  defp git_json(path, inspect_fun) when is_binary(path) do
    case inspect_fun.(path) do
      {:ok, info} -> ok_git(info)
      :error -> unknown_git("inspect_failed")
      {:error, reason} -> unknown_git(reason_to_string(reason))
      _ -> unknown_git("inspect_failed")
    end
  end

  defp ok_git(info) when is_map(info) do
    ahead = git_field(info, :ahead)
    behind = git_field(info, :behind)

    %{
      inspect_state: "ok",
      branch: blank_to_nil(git_field(info, :branch)),
      head_sha: blank_to_nil(git_field(info, :head_sha)),
      upstream: blank_to_nil(git_field(info, :upstream)),
      ahead: ahead,
      behind: behind,
      detached?: git_field(info, :detached?),
      commits_not_on_origin?: commits_not_on_origin?(ahead)
    }
    |> reject_nils()
  end

  # do not set ahead: 0 or commits_not_on_origin?: false on unknown —
  # operators treat those as proof the tree is synced (#384 / #904 honesty).
  defp unknown_git(reason) do
    %{
      inspect_state: "unknown",
      unknown_reason: reason_to_string(reason)
    }
  end

  defp commits_not_on_origin?(ahead) when is_integer(ahead) and ahead > 0, do: true
  defp commits_not_on_origin?(ahead) when is_integer(ahead), do: false
  defp commits_not_on_origin?(_), do: nil

  defp default_inspect(path), do: Inspector.inspect_cwd(path)

  defp window_for(pane, %{windows: windows}) when is_list(windows) do
    wid = pane_field(pane, :window_id)

    Enum.find(windows, fn window ->
      window_field(window, :id) == wid
    end)
  end

  defp window_for(_, _), do: nil

  defp pane_field(nil, _key), do: nil

  defp pane_field(pane, key) when is_map(pane) do
    Map.get(pane, key) || Map.get(pane, Atom.to_string(key))
  end

  defp window_field(nil, _key), do: nil

  defp window_field(window, key) when is_map(window) do
    Map.get(window, key) || Map.get(window, Atom.to_string(key))
  end

  defp git_field(%_{} = info, key), do: Map.get(info, key)

  defp git_field(info, key) when is_map(info) do
    Map.get(info, key) || Map.get(info, Atom.to_string(key))
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason) and reason != "", do: reason
  defp reason_to_string(_), do: "inspect_failed"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(value), do: value

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

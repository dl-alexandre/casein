defmodule Casein.Terminals.WorktreeDiff do
  @moduledoc """
  Read-only bounded unified diff for one worker pane (#384 M4.4).

  One call answers "what is the patch?" by joining `WorkerStatus` identity
  with `git diff HEAD` (staged + unstaged vs HEAD). Not an arbitrary command,
  not a path contract, and not a LiveView hot-path read.

  ## Kind discipline

    * `status_state: unknown` means git did not produce a diff. It is **never**
      clean or "nothing changed".
    * Do **not** emit `diff: ""` on unknown — operators treat empty as proof
      the tree matches HEAD (#904 inverse).
    * `diff: ""` is allowed only when git succeeded and the tree matches HEAD.
    * Output is capped; `truncated?: true` when the cap is hit.

  ## Out of scope (leave #384 open)

  Path-contract / forbidden-set enforcement, `worker_replace`,
  `worker_send_contract`, durable graph / verifiers, restricted orchestrator
  profile.
  """

  alias Casein.Terminals.WorkerStatus

  @max_bytes 65_536

  @type payload :: %{
          workspace_id: String.t(),
          session: String.t(),
          generated_at: String.t(),
          found?: boolean(),
          pane_id: String.t() | nil,
          window_id: String.t() | nil,
          window_name: String.t() | nil,
          worktree_path: String.t() | nil,
          status_state: String.t(),
          note: String.t()
        }

  @doc """
  Project an enriched topology plus a unified diff into a worktree_diff payload.

  Options:

    * `:workspace_id` / `:session` / `:pane` — required identity
    * `:window_id` — optional disambiguator
    * `:now` — `DateTime` for `generated_at`
    * `:diff` — `(path -> {:ok, binary()} | :error)` unified diff for tests
  """
  @spec project(map(), keyword()) :: payload()
  def project(topology, opts \\ []) when is_map(topology) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    pane_id = Keyword.fetch!(opts, :pane)
    window_id = Keyword.get(opts, :window_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    diff_fun = Keyword.get(opts, :diff, &default_diff/1)

    case WorkerStatus.find_pane(topology, pane_id, window_id) do
      nil ->
        not_found(workspace_id, session, pane_id, window_id, now)

      pane ->
        found(workspace_id, session, pane, topology, diff_fun, now)
    end
  end

  ## Internals

  defp found(workspace_id, session, pane, topology, diff_fun, now) do
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
      note:
        "M4.4 worktree_diff. Joins WorkerStatus identity + git diff HEAD. " <>
          "status_state unknown never emits diff: \"\". path contracts / " <>
          "worker_replace remain out of scope."
    }
    |> Map.merge(diff_json(worktree, diff_fun))
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
      status_state: "unknown",
      unknown_reason: "pane_not_found",
      note: "M4.4 worktree_diff: pane not found. status_state unknown — not an empty patch."
    }
    |> reject_nils()
  end

  defp diff_json(nil, _diff_fun), do: unknown_diff("no_worktree")
  defp diff_json("", _diff_fun), do: unknown_diff("no_worktree")

  defp diff_json(path, diff_fun) when is_binary(path) do
    case diff_fun.(path) do
      {:ok, body} when is_binary(body) -> ok_diff(body)
      :error -> unknown_diff("diff_failed")
      {:error, reason} -> unknown_diff(reason_to_string(reason))
      _ -> unknown_diff("diff_failed")
    end
  end

  defp ok_diff(body) do
    {kept, truncated?} = cap_bytes(body)

    %{
      status_state: "ok",
      diff: kept,
      byte_count: byte_size(kept),
      truncated?: truncated?
    }
  end

  # do not set diff: "" on unknown — operators treat that as proof the tree
  # matches HEAD (#384 M4.4; #904 inverse).
  defp unknown_diff(reason) do
    %{
      status_state: "unknown",
      unknown_reason: reason
    }
  end

  defp cap_bytes(body) when byte_size(body) <= @max_bytes, do: {body, false}

  defp cap_bytes(body) do
    {binary_part(body, 0, @max_bytes), true}
  end

  # unified diff is read-only `git diff HEAD`; path is the pane worktree.
  # sobelow_skip ["CI.System"]
  defp default_diff(path) do
    if File.dir?(path) do
      case System.cmd(
             "git",
             ["-C", path, "diff", "--no-color", "--no-ext-diff", "HEAD", "--"],
             stderr_to_stdout: true
           ) do
        {out, 0} -> {:ok, out}
        _ -> :error
      end
    else
      :error
    end
  rescue
    ErlangError -> :error
  end

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

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason) and reason != "", do: reason
  defp reason_to_string(_), do: "diff_failed"

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

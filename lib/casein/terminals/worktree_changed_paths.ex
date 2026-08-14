defmodule Casein.Terminals.WorktreeChangedPaths do
  @moduledoc """
  Read-only structured dirty-path list for one worker pane (#384 M4.3).

  One call answers "what files did this worker change?" by joining
  `WorkerStatus` identity with `git status --porcelain=v1 -z` — the same
  porcelain `AgentProgress` already samples for fingerprints. Not a path
  contract, not a diff, and not a LiveView hot-path read.

  ## Kind discipline

    * `status_state: unknown` means porcelain did not run. It is **never**
      clean, quiet, or "nothing changed".
    * Do **not** emit `changed_paths: []` on unknown — operators treat an
      empty list as proof the tree is clean (#904 inverse).
    * `changed_paths: []` is allowed only when porcelain succeeded and was
      empty (`status_state: ok`).
    * No path-contract language (no `/**`, no forbidden-set). Paths are
      repository-relative strings as git printed them.

  ## Out of scope (leave #384 open)

  `worktree_diff`, `worker_replace`, `worker_send_contract`, durable graph /
  path contracts / verifiers, restricted orchestrator profile.
  """

  alias Casein.Terminals.WorkerStatus

  @max_paths 200

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
  Project an enriched topology plus porcelain into a changed-paths payload.

  Options:

    * `:workspace_id` / `:session` / `:pane` — required identity
    * `:window_id` — optional disambiguator
    * `:now` — `DateTime` for `generated_at`
    * `:status` — `(path -> {:ok, binary()} | :error)` porcelain body for tests
  """
  @spec project(map(), keyword()) :: payload()
  def project(topology, opts \\ []) when is_map(topology) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    session = Keyword.fetch!(opts, :session)
    pane_id = Keyword.fetch!(opts, :pane)
    window_id = Keyword.get(opts, :window_id)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    status_fun = Keyword.get(opts, :status, &default_status/1)

    case WorkerStatus.find_pane(topology, pane_id, window_id) do
      nil ->
        not_found(workspace_id, session, pane_id, window_id, now)

      pane ->
        found(workspace_id, session, pane, topology, status_fun, now)
    end
  end

  ## Internals

  defp found(workspace_id, session, pane, topology, status_fun, now) do
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
        "M4.3 worktree_changed_paths. Joins WorkerStatus identity + git porcelain. " <>
          "status_state unknown never emits changed_paths: []. worktree_diff / " <>
          "path contracts / worker_replace remain out of scope."
    }
    |> Map.merge(paths_json(worktree, status_fun))
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
      note:
        "M4.3 worktree_changed_paths: pane not found. status_state unknown — " <>
          "not an empty change list."
    }
    |> reject_nils()
  end

  defp paths_json(nil, _status_fun), do: unknown_paths("no_worktree")
  defp paths_json("", _status_fun), do: unknown_paths("no_worktree")

  defp paths_json(path, status_fun) when is_binary(path) do
    case status_fun.(path) do
      {:ok, body} when is_binary(body) -> ok_paths(body)
      :error -> unknown_paths("status_failed")
      {:error, reason} -> unknown_paths(reason_to_string(reason))
      _ -> unknown_paths("status_failed")
    end
  end

  defp ok_paths(body) do
    parsed = parse_porcelain_z(body)
    {kept, rest} = Enum.split(parsed, @max_paths)

    %{
      status_state: "ok",
      changed_paths: kept,
      count: length(kept),
      truncated?: rest != []
    }
  end

  # do not set changed_paths: [] on unknown — operators treat that as proof
  # the tree is clean (#384 M4.3; #904 inverse).
  defp unknown_paths(reason) do
    %{
      status_state: "unknown",
      unknown_reason: reason
    }
  end

  defp parse_porcelain_z(body) when is_binary(body) do
    body
    |> String.split("\0", trim: true)
    |> parse_entries([])
    |> Enum.reverse()
  end

  defp parse_entries([], acc), do: acc

  defp parse_entries([head | rest], acc) do
    case entry_shape(head) do
      {:rename, xy, orig} ->
        case rest do
          [new_path | rest2] ->
            parse_entries(rest2, [path_row(xy, new_path, orig) | acc])

          [] ->
            parse_entries([], [path_row(xy, orig, nil) | acc])
        end

      {:ok, xy, path} ->
        parse_entries(rest, [path_row(xy, path, nil) | acc])

      :skip ->
        parse_entries(rest, acc)
    end
  end

  defp entry_shape(<<x, y, rest::binary>>) when x in ?A..?Z or x in [?\s, ??] do
    xy = <<x, y>>
    path = rest |> String.trim_leading() |> String.trim()

    cond do
      path == "" -> :skip
      x in [?R, ?C] -> {:rename, xy, path}
      true -> {:ok, xy, path}
    end
  end

  defp entry_shape(_), do: :skip

  defp path_row(xy, path, nil), do: %{xy: xy, path: path}

  defp path_row(xy, path, orig) do
    %{xy: xy, path: path, orig_path: orig}
  end

  # porcelain is read-only `git status`; path is the pane worktree.
  # sobelow_skip ["CI.System"]
  defp default_status(path) do
    if File.dir?(path) do
      case System.cmd("git", ["-C", path, "status", "--porcelain=v1", "-z"],
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
  defp reason_to_string(_), do: "status_failed"

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

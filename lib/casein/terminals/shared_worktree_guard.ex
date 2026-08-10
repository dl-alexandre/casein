defmodule Casein.Terminals.SharedWorktreeGuard do
  @moduledoc """
  Refuse a git mutation sent into a worktree another pane is also sitting in.

  `terminal_topology` has reported `shared_worktrees` for a while, and that
  warning is read by whoever asks for the topology — which is not the caller
  about to run `git reset --hard` in the shared tree. Concurrent git in one
  worktree corrupts index state rather than failing cleanly, so the discovery
  path is somebody else's lost work. This turns the same signal into an answer
  at the moment of the write.

  **Soft** block: `allow_shared_worktree: true` on the call goes through. Sharing
  a worktree is sometimes deliberate — `scripts/lib/agent-worktree.sh` adopts an
  existing tree on purpose — so the guard's job is to make the sharing *known*,
  not to make it impossible. What it removes is the silent case.

  Three properties keep it cheap, and keep it from being wrong more often than
  right:

    * The command is classified first (`Casein.Git.MutationScan`), so a send that
      is not a git write never pays for a topology snapshot. Nearly all of them
      are not.

    * The tree checked is the tree that would be *written*. `git -C <elsewhere>
      commit` from a shared pane writes elsewhere and is allowed; the repo's own
      scripts use `git -C` constantly, and a guard that blocked them would be
      turned off within a day.

    * The conflict is with another *window*. Casein runs one agent per window, so
      panes sharing a worktree inside one window are that agent's own surfaces —
      its shell, a file pane, a preview split. Half the shared-worktree hits on a
      real box are that shape.
  """

  alias Casein.Git.MutationScan
  alias Casein.Terminals.PaneLiveness
  alias Casein.Terminals.PaneState
  alias Casein.Terminals.TmuxTopology

  @escape_hatch "allow_shared_worktree"

  @doc """
  Check a command bound for `pane` in `session`.

  Returns `:ok`, or `{:error, payload}` describing the refusal — including who
  else is in the tree, so the caller can act without a second round trip.

  Options:

    * `:allow_shared_worktree` — caller asserts the share is deliberate
    * `:tmux` — tmux adapter (defaults to the configured one)
  """
  @spec check(String.t(), String.t() | nil, String.t() | term(), keyword()) ::
          :ok | {:error, map()}
  def check(session, pane, command, opts \\ []) do
    if Keyword.get(opts, :allow_shared_worktree, false) do
      :ok
    else
      case MutationScan.scan(command) do
        :none -> :ok
        {:mutation, mutation} -> check_mutation(session, pane, mutation, opts)
      end
    end
  end

  defp check_mutation(session, pane, mutation, opts) do
    panes = session_panes(session, opts)

    with {:ok, target} <- target_pane(panes, pane),
         {:ok, worktree} <- mutation_worktree(target, mutation),
         [_ | _] = others <- shared_with(panes, worktree, target) do
      {:error, refusal(target, worktree, others, mutation)}
    else
      _ -> :ok
    end
  end

  defp session_panes(session, opts) do
    tmux = Keyword.get(opts, :tmux, default_tmux())

    session
    |> TmuxTopology.snapshot(tmux: tmux)
    |> PaneLiveness.enrich_topology(liveness: false)
    |> Map.get(:panes, [])
  rescue
    # A guard that cannot read the topology must not become a guard that blocks
    # every send. Failing open here matches the tool's own behaviour when tmux is
    # unreachable: the send fails on its own terms, with its own error.
    _ -> []
  catch
    :exit, _ -> []
  end

  defp target_pane([], _pane), do: :error

  defp target_pane(panes, pane) do
    case Enum.find(panes, &(PaneState.map_get(&1, :id) == pane)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  # Which tree the command writes: the pane's own, unless it redirected with
  # `-C` / `--work-tree`.
  defp mutation_worktree(target, %{dir: nil}) do
    case Map.get(target, :worktree_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> :error
    end
  end

  defp mutation_worktree(target, %{dir: dir}) do
    dir
    |> expand_against(PaneState.map_get(target, :current_path))
    |> then(fn path -> %{current_path: path} end)
    |> PaneLiveness.pane_worktree()
    |> case do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> :error
    end
  end

  defp expand_against(dir, cwd) when is_binary(cwd) and cwd != "", do: Path.expand(dir, cwd)
  defp expand_against(dir, _cwd), do: Path.expand(dir)

  # Other *windows* in this worktree — not other panes.
  #
  # Casein runs one agent per window, so panes sharing a worktree inside one
  # window are that agent's own surfaces: its shell, a file pane, a preview split,
  # all inheriting its cwd. On this box roughly half the shared-worktree hits are
  # exactly that shape, and refusing them would refuse an agent's own commits —
  # the guard would be wrong far more often than right, and off within a day.
  #
  # The topology *warning* still reports every sharing pane, which is correct for
  # a warning; the difference is that a refusal has to be sure. The incident this
  # exists for was windows 2, 3 and 4 adopting one worktree.
  defp shared_with(panes, worktree, target) do
    windows = Map.new(panes, &{PaneState.map_get(&1, :id), PaneState.map_get(&1, :window_id)})
    target_id = PaneState.map_get(target, :id)
    target_window = PaneState.map_get(target, :window_id)

    panes
    |> PaneLiveness.shared_worktrees()
    |> Map.get(worktree, [])
    |> Enum.reject(&(&1 == target_id or Map.get(windows, &1) == target_window))
  end

  defp refusal(target, worktree, others, mutation) do
    pane_id = PaneState.map_get(target, :id)
    occupants = Enum.join(others, ", ")

    %{
      error: :shared_worktree_mutation,
      refused: true,
      safe_to_mutate: false,
      pane: pane_id,
      worktree_path: worktree,
      shared_with: others,
      git_subcommand: mutation.subcommand,
      command: mutation.command,
      message:
        "Refused: `git #{mutation.subcommand}` would write #{worktree}, which #{occupants} " <>
          "#{plural_verb(others)} also working in. Concurrent git in one worktree corrupts index " <>
          "state rather than failing cleanly, so this would land on their uncommitted work, " <>
          "not just yours.",
      remedy:
        "Give this work its own worktree — `bash scripts/spawn-agent-worker.sh <runtime> " <>
          "<task-slug>` branches a fresh one off the primary checkout. If the sharing is " <>
          "deliberate, re-send with `#{@escape_hatch}: true`.",
      escape_hatch: @escape_hatch,
      next_tool: "terminal_topology"
    }
  end

  defp plural_verb([_one]), do: "is"
  defp plural_verb(_many), do: "are"

  # Same resolution as Impl.Shared.tmux/0, so a test that stubs the adapter for
  # the tool also stubs it for the guard.
  # Prefer Backend for topology reads covered by the behaviour; fall back to the
  # legacy :tmux_adapter key so existing FakeTmuxAdapter tests stay green.
  defp default_tmux do
    Application.get_env(:casein, :tmux_adapter) || Casein.Terminals.Backend.module()
  end
end

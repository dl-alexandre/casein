defmodule Casein.Terminals.OrphanSessions do
  @moduledoc """
  Enumerates live `casein_*` tmux sessions whose workspace Casein no longer
  knows about (#20702).

  Casein has no workspace delete path of its own: the milc-devbox manager owns
  workspace lifecycle and, when a workspace is deleted there, tears down its
  containers, routes, worktree and DNS without telling Casein. The tmux session
  is Casein's, not the manager's, so it is in nobody's teardown. It stays alive,
  holds an agent-budget slot, and the UI close control cannot reach it because
  that control resolves a pane through its workspace — which no longer exists.

  Nothing here kills anything. `Casein.Workspaces.Reconciler` states the reason
  in its own moduledoc: reaping the resources a retired workspace leaves behind
  is destructive, needs its own gating, and belongs in a separate pass built on
  the retirement signal. This module is the missing *first* half of that — the
  enumeration that makes an orphan findable, so it can be retired deliberately
  rather than discovered by an agent-budget shortfall.

  ## Two confidences, and why the distinction is the point

  A session is only reported when Casein can see a reason to doubt it, and the
  two reasons are not equally strong:

    * `:retired` — a workspace record exists and the Reconciler has marked it
      stale, i.e. Casein positively observed the manager stop vouching for it.
      This is the case the issue describes.

    * `:unknown` — no workspace record matches the session at all. This is
      **not** proof of deletion. `GET /api/workspaces` filters to the caller's
      own user unless an admin passes `all=true`, so on a shared box a session
      with no record may simply belong to another developer whose workspaces
      Casein never listed. Treating that as an orphan is how a sweep becomes
      "kill every other developer's panes".

  Callers must not collapse the two. `:unknown` is a prompt to go and look, not
  a verdict.

  ## What is deliberately not used

  Directory existence. A name-to-path check is unreliable here: workspaces may
  live at custom paths, so an absent `/data/workspaces/<name>` proves nothing
  about a workspace that was never there. Matching is against workspace
  *records*, which is the only thing Casein is authoritative about.

  Session-to-workspace matching goes through `TmuxPolicy.session_in_namespace?/2`
  rather than a bare prefix test, because `_` is legal in a sanitized workspace
  name: `casein_acme_` is a genuine prefix of workspace `acme_prod`'s session
  `casein_acme_prod_1`, and a plain `String.starts_with?/2` would attribute one
  workspace's sessions to another.
  """

  alias Casein.Terminals.Backend
  alias Casein.Terminals.TmuxPolicy
  alias Casein.Workspaces.Scratch
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.WorkspaceRecord

  @session_prefix "casein_"

  @type confidence :: :retired | :unknown

  @type orphan :: %{
          session: String.t(),
          attached: boolean(),
          workspace: String.t() | nil,
          confidence: confidence()
        }

  @doc """
  Lists orphan candidates from the live tmux inventory.

  Prefers the backend's `list_sessions_result/0` over `list_sessions/0`: the
  latter collapses a failed `tmux list-sessions` into an empty list, which
  would render a broken tmux as a confident "no orphans". An error is returned
  as an error so it cannot be read as a clean result.
  """
  @spec list() :: {:ok, [orphan()]} | {:error, term()}
  def list do
    with {:ok, sessions} <- session_inventory(Backend.module()) do
      {:ok, classify(sessions, State.list())}
    end
  end

  # `list_sessions_result/0` is not a `Casein.Terminals.Backend` callback, only
  # an optional refinement some backends provide, so it is probed the same way
  # `Backends.Tmux` probes its own adapter rather than assumed to exist.
  defp session_inventory(mod) do
    if function_exported?(mod, :list_sessions_result, 0) do
      mod.list_sessions_result()
    else
      {:ok, mod.list_sessions()}
    end
  end

  @doc """
  Classifies a tmux inventory against workspace records.

  Pure, so the classification can be tested without tmux or a database.
  """
  @spec classify([map()], [WorkspaceRecord.t()]) :: [orphan()]
  def classify(sessions, records) when is_list(sessions) and is_list(records) do
    {retired, live} = Enum.split_with(records, &WorkspaceRecord.retired?/1)

    live_prefixes = prefixes(live)
    retired_prefixes = prefixes(retired)

    sessions
    |> Enum.filter(&casein_session?/1)
    |> Enum.reject(&scratch_session?/1)
    |> Enum.flat_map(&classify_session(&1, live_prefixes, retired_prefixes))
    |> Enum.sort_by(& &1.session)
  end

  defp prefixes(records) do
    for %WorkspaceRecord{name: name} <- records,
        is_binary(name),
        name != "",
        do: {name, TmuxPolicy.workspace_session_prefix(name)}
  end

  defp classify_session(%{session: session} = entry, live_prefixes, retired_prefixes) do
    if owner(session, live_prefixes) do
      []
    else
      case owner(session, retired_prefixes) do
        nil -> [orphan(session, entry, nil, :unknown)]
        name -> [orphan(session, entry, name, :retired)]
      end
    end
  end

  defp classify_session(_entry, _live, _retired), do: []

  defp owner(session, prefixes) do
    Enum.find_value(prefixes, fn {name, prefix} ->
      if TmuxPolicy.session_in_namespace?(session, prefix), do: name
    end)
  end

  defp orphan(session, entry, workspace, confidence) do
    %{
      session: session,
      attached: Map.get(entry, :attached, false) == true,
      workspace: workspace,
      confidence: confidence
    }
  end

  defp casein_session?(%{session: session}) when is_binary(session),
    do: String.starts_with?(session, @session_prefix)

  defp casein_session?(_), do: false

  # Scratch is a real workspace with a sentinel id and no manager record by
  # design, so it is workspaceless on purpose and would otherwise be reported
  # as an orphan on every run, forever.
  defp scratch_session?(%{session: session}) do
    TmuxPolicy.session_in_namespace?(session, TmuxPolicy.workspace_session_prefix(Scratch.id()))
  end

  defp scratch_session?(_), do: false
end

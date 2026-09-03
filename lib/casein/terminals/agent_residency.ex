defmodule Casein.Terminals.AgentResidency do
  @moduledoc """
  Where the agents counted against the host budget actually live.

  `Casein.Terminals.HostCapacity` counts agent processes, and
  `Casein.Terminals.TmuxWindowJanitor` reaps idle tmux *windows*. Between the
  two sits a population nobody enumerates: an agent process is only reachable
  by the janitor if some tmux pane is its ancestor, and the janitor exempts a
  session that has an attached client. An agent that meets neither condition is
  counted forever and reaped never.

  This module names that population. It walks each agent process up its parent
  chain and reports which tmux pane — if any — holds it:

    * `:in_pane` — a pane process is an ancestor, so the janitor can see it
      (whether it *reaps* it is the janitor's idle and attachment policy, not
      ours).
    * `:no_pane` — no ancestor is a pane process. The janitor cannot reach it
      by any timeout. `orphan?` marks the subset already reparented to init.

  Matching an agent's own pid against `pane_pid` is not enough: `pane_pid` is
  the pane's shell, and the agent is its descendant. The ancestor walk is the
  whole point.

  The same walk answers a second question: **whose** slot each agent is. Every
  agent runs as the shared OS user, so `ps` attributes nothing and
  `CASEIN_AGENT_MAX_PER_USER` is inert by construction; the holding pane's tmux
  session is the only workspace identity available. `by_workspace` groups the
  budget that way, with `nil` for the agents no pane holds — the slots no
  per-workspace reservation could ever cover.

  It reads and reports; it kills nothing and changes no policy. What *should*
  happen to a `:no_pane` agent is a question for whoever owns the reaper — this
  only makes the answer measurable instead of hand-counted.
  """

  alias Casein.Terminals.HostCapacity
  alias Casein.Terminals.TmuxRunner
  alias Casein.Workspaces.Identity

  @typedoc "One agent process and the pane holding it, if any."
  @type resident :: %{
          pid: String.t(),
          ppid: String.t(),
          command: String.t(),
          residency: :in_pane | :no_pane,
          orphan?: boolean(),
          pane: %{session: String.t(), pane_id: String.t()} | nil,
          workspace: String.t() | nil
        }

  @typedoc "Every agent, classified, with the counts worth alerting on."
  @type report :: %{
          residents: [resident()],
          total: non_neg_integer(),
          in_pane: non_neg_integer(),
          no_pane: non_neg_integer(),
          orphans: non_neg_integer(),
          by_workspace: %{optional(String.t() | nil) => non_neg_integer()}
        }

  # A parent chain longer than this is a cycle or a fork bomb; either way,
  # stop rather than loop.
  @max_ancestry_depth 64

  @doc """
  Classify the live host: read `ps`, read every tmux pane, cross-reference.

  Options are for tests: `:listing` supplies the `ps` output, `:panes` the pane
  map, and `:runner` the tmux call — each skipping the read it replaces.
  """
  @spec report(keyword()) :: {:ok, report()} | {:error, term()}
  def report(opts \\ []) do
    with {:ok, listing} <- fetch(opts, :listing, &process_listing/0),
         {:ok, panes} <- fetch(opts, :panes, fn -> pane_processes(opts) end) do
      {:ok, classify(listing, panes)}
    end
  end

  @doc """
  Classify a `ps -eo user=,pid=,ppid=,args=` listing against a pane map.

  Pure: every input is an argument, so the interesting cases — an agent three
  levels below its pane, an agent under a dead pane, an agent on init — are
  testable without a tmux server.
  """
  @spec classify(String.t(), %{
          optional(String.t()) => %{session: String.t(), pane_id: String.t()}
        }) ::
          report()
  def classify(listing, panes) when is_binary(listing) and is_map(panes) do
    parents = HostCapacity.process_parents(listing)

    residents =
      listing
      |> HostCapacity.agent_sessions()
      |> Enum.map(&classify_one(&1, parents, panes))

    %{
      residents: residents,
      total: length(residents),
      in_pane: Enum.count(residents, &(&1.residency == :in_pane)),
      no_pane: Enum.count(residents, &(&1.residency == :no_pane)),
      orphans: Enum.count(residents, & &1.orphan?),
      by_workspace: Enum.frequencies_by(residents, & &1.workspace)
    }
  end

  defp classify_one(agent, parents, panes) do
    pane = holding_pane(agent.pid, parents, panes)

    agent
    |> Map.put(:residency, if(pane, do: :in_pane, else: :no_pane))
    |> Map.put(:orphan?, agent.ppid == "1")
    |> Map.put(:pane, pane)
    |> Map.put(:workspace, workspace_of(pane))
  end

  # Every agent runs as the same OS user, so `ps` cannot say who a slot belongs
  # to — the tmux session it hangs off is the only attribution available, and an
  # agent with no pane has none at all. `nil` is that answer, kept as a key
  # rather than dropped: the unattributable slots are the ones no per-workspace
  # reservation can ever cover, so their count is part of the picture.
  defp workspace_of(nil), do: nil
  defp workspace_of(%{session: session}), do: Identity.session_workspace(session)

  # Walk pid -> parent -> ... looking for a pane process. The agent's own pid
  # is checked first: a bare `claude` run as the pane command is its own pane.
  defp holding_pane(pid, parents, panes),
    do: holding_pane(pid, parents, panes, @max_ancestry_depth)

  defp holding_pane(_pid, _parents, _panes, 0), do: nil
  defp holding_pane(pid, _parents, _panes, _depth) when pid in ["", "0", "1"], do: nil

  defp holding_pane(pid, parents, panes, depth) do
    case Map.fetch(panes, pid) do
      {:ok, pane} -> pane
      :error -> walk_up(pid, parents, panes, depth)
    end
  end

  defp walk_up(pid, parents, panes, depth) do
    case Map.fetch(parents, pid) do
      # Parent is gone from the listing, or points back at itself: stop.
      {:ok, ^pid} -> nil
      {:ok, parent} -> holding_pane(parent, parents, panes, depth - 1)
      :error -> nil
    end
  end

  @doc """
  `%{pane_pid => %{session, pane_id}}` for every pane on the tmux server.

  `-a` is deliberate: a per-session read would inherit the very blind spot
  this module exists to measure. `:runner` overrides the tmux call in tests.
  """
  @spec pane_processes(keyword()) ::
          {:ok, %{optional(String.t()) => %{session: String.t(), pane_id: String.t()}}}
          | {:error, term()}
  def pane_processes(opts \\ []) do
    fmt = ~S(#{session_name}|#{pane_id}|#{pane_pid})
    runner = Keyword.get(opts, :runner, &TmuxRunner.run/1)

    case runner.(["list-panes", "-a", "-F", fmt]) do
      {out, 0} -> {:ok, parse_panes(out)}
      # No server running means no panes, which is a real answer: then every
      # agent is `:no_pane`, and that is exactly what we want reported.
      {_out, _code} -> {:ok, %{}}
    end
  end

  defp parse_panes(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "|", parts: 3) do
        [session, pane_id, pid] when pid != "" ->
          Map.put(acc, String.trim(pid), %{session: session, pane_id: pane_id})

        _ ->
          acc
      end
    end)
  end

  defp process_listing do
    case HostCapacity.process_listing() do
      listing when is_binary(listing) -> {:ok, listing}
      nil -> {:error, :ps_unavailable}
    end
  end

  defp fetch(opts, key, reader) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> reader.()
    end
  end
end

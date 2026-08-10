defmodule Casein.Terminals.FleetBoard do
  @moduledoc """
  Operator-visible **fleet aggregate** over per-window agent chrome.

  Per-pane signals already exist (`AgentState`, `AgentLiveness` / `PaneLiveness`,
  `IssueBinding`, `FleetChrome`). This module does not own state and does not
  invent a second classifier — it projects already-resolved window tabs into:

    * bucket counts (`needs_you`, `working`, `ready_no_task`, `idle`, `done`,
      `unknown`)
    * sorted rows an operator can scan for "what are my N workers doing?"
    * an attention count for cockpit badge chrome

  ## Kind discipline

  Report-only (`:blocked`, `:errored`) and derived-only (`:stalled`) stay
  distinct on each row. Unknown observation never becomes quiet/idle — a row
  without a known agent state lands in `:unknown`, not `:idle`.

  ## Attention model

  `needs_you?` on a row follows `Casein.Attention.Delivery.session_classification/1`
  over the row's agent signal (blocked / errored / stalled / quiet-done-as-idle),
  plus fleet `ready_no_task` (spawned idle capacity). Surfaces share that
  salience path rather than ranking beside it (#787 / #788).
  """

  alias Casein.Attention.Delivery
  alias Casein.Attention.Salience
  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.OrphanedClaims

  @type bucket ::
          :needs_you | :working | :ready_no_task | :idle | :done | :unknown

  @type liveness_view :: %{
          optional(:state) => :active | :quiet | :unknown,
          optional(:reason) => atom() | String.t() | nil,
          optional(:quiet_for_seconds) => non_neg_integer() | nil,
          optional(:last_write_at) => String.t() | DateTime.t() | nil,
          optional(:commit_count) => non_neg_integer() | nil
        }

  @type blocked_on :: %{
          kind: :report | :derived | :unknown,
          reason: atom() | nil,
          detail: String.t() | nil
        }

  @type row :: %{
          window_id: String.t(),
          pane_id: String.t() | nil,
          name: String.t(),
          display_name: String.t(),
          agent_state: atom() | nil,
          agent_state_message: String.t() | nil,
          chip_text: String.t() | nil,
          chip_class: String.t() | nil,
          dot_class: String.t() | nil,
          label: String.t() | nil,
          issue: pos_integer() | nil,
          issue_title: String.t() | nil,
          task_summary: String.t() | nil,
          fleet_role: FleetChrome.fleet_role() | nil,
          fleet_readiness: FleetChrome.fleet_readiness() | nil,
          ready_no_task_for_seconds: non_neg_integer() | nil,
          quiet?: boolean(),
          unseen_quiet?: boolean(),
          needs_you?: boolean(),
          attention_reason: atom() | nil,
          bucket: bucket(),
          active?: boolean(),
          liveness: liveness_view() | nil,
          blocked_on: blocked_on() | nil
        }

  @type board :: %{
          rows: [row()],
          counts: %{optional(bucket()) => non_neg_integer()},
          attention_count: non_neg_integer(),
          total: non_neg_integer(),
          empty?: boolean(),
          orphaned_claims: OrphanedClaims.snapshot(),
          gate_queue: map()
        }

  @bucket_order [:needs_you, :working, :ready_no_task, :idle, :done, :unknown]

  @doc "Stable bucket order for chrome (needs-you first)."
  @spec bucket_order() :: [bucket()]
  def bucket_order, do: @bucket_order

  @doc """
  Build a fleet board from render-ready window tabs (`SessionBarVM.window_tab/4`).

  Options:

    * `:agent_only` — when true (default), drop windows with no agent role and
      no known agent state (pure shell windows stay off the fleet board)
    * `:orphaned_claims` — precomputed `OrphanedClaims` snapshot; when omitted
      the board derives bound issue numbers from tabs and leaves observation
      as unknown unless `:claimed` / `:list_claimed` is also supplied
    * `:claimed` / `:list_claimed` / `:tmux_session` — forwarded to
      `OrphanedClaims.observe/1` when `:orphaned_claims` is omitted
    * `:gate_queue` — precomputed `GateQueue.observe/1` result map; when omitted
      the board observes the host lock (cached). Pass `GateQueue.unknown()` to
      skip observation (tests / offline).
  """
  @spec from_window_tabs([map()], keyword()) :: board()
  def from_window_tabs(tabs, opts \\ []) when is_list(tabs) do
    agent_only? = Keyword.get(opts, :agent_only, true)

    rows =
      tabs
      |> Enum.map(&row_from_window_tab/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn row -> not agent_only? or fleet_row?(row) end)
      |> Enum.sort_by(&row_sort_key/1)

    counts =
      Enum.reduce(rows, empty_counts(), fn row, acc ->
        Map.update!(acc, row.bucket, &(&1 + 1))
      end)

    orphaned = resolve_orphaned_claims(rows, opts)
    orphan_attention = orphan_attention_count(orphaned)
    attention_count = Enum.count(rows, & &1.needs_you?) + orphan_attention

    %{
      rows: rows,
      counts: counts,
      attention_count: attention_count,
      total: length(rows),
      empty?: rows == [],
      orphaned_claims: orphaned,
      gate_queue: resolve_gate_queue(opts)
    }
  end

  @doc "Empty board for mount / no-session sockets."
  @spec empty() :: board()
  def empty do
    %{
      rows: [],
      counts: empty_counts(),
      attention_count: 0,
      total: 0,
      empty?: true,
      orphaned_claims: OrphanedClaims.unknown(),
      gate_queue: GateQueue.unknown()
    }
  end

  @doc "True when the board has any needs-you row or orphaned claim."
  @spec needs_attention?(board()) :: boolean()
  def needs_attention?(%{attention_count: n}) when is_integer(n) and n > 0, do: true
  def needs_attention?(_), do: false

  ## Internals

  defp row_from_window_tab(tab) when is_map(tab) do
    window_id = Map.get(tab, :id) || Map.get(tab, "id")
    if not is_binary(window_id) or window_id == "", do: throw(:skip)

    agent_state = normalize_state(Map.get(tab, :agent_state) || Map.get(tab, "agent_state"))

    message =
      blank_to_nil(Map.get(tab, :agent_state_message) || Map.get(tab, "agent_state_message"))

    fleet_role = normalize_role(Map.get(tab, :fleet_role) || Map.get(tab, "fleet_role"))

    fleet_readiness =
      normalize_readiness(Map.get(tab, :fleet_readiness) || Map.get(tab, "fleet_readiness"))

    ready_for =
      case Map.get(tab, :ready_no_task_for_seconds) || Map.get(tab, "ready_no_task_for_seconds") do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end

    quiet? = Map.get(tab, :quiet?) == true or Map.get(tab, :quiet) == true
    unseen_quiet? = Map.get(tab, :unseen_quiet?) == true

    {needs_you?, attention_reason} =
      needs_you_projection(agent_state, quiet?, fleet_readiness)

    bucket = bucket_for(needs_you?, agent_state, fleet_readiness)
    liveness = liveness_from_tab(tab)
    blocked_on = blocked_on_from(agent_state, message, attention_reason, liveness)

    %{
      window_id: window_id,
      pane_id: blank_to_nil(Map.get(tab, :agent_pane_id) || Map.get(tab, "agent_pane_id")),
      name: to_string(Map.get(tab, :name) || Map.get(tab, "name") || window_id),
      display_name:
        to_string(
          Map.get(tab, :display_name) || Map.get(tab, "display_name") ||
            Map.get(tab, :name) || window_id
        ),
      agent_state: agent_state,
      agent_state_message: message,
      chip_text:
        blank_to_nil(Map.get(tab, :agent_state_chip) || Map.get(tab, "agent_state_chip")),
      chip_class:
        blank_to_nil(
          Map.get(tab, :agent_state_chip_class) || Map.get(tab, "agent_state_chip_class")
        ),
      dot_class: blank_to_nil(Map.get(tab, :activity_class) || Map.get(tab, "activity_class")),
      label: blank_to_nil(Map.get(tab, :label) || Map.get(tab, "label")),
      issue: normalize_issue(Map.get(tab, :issue) || Map.get(tab, "issue")),
      issue_title: blank_to_nil(Map.get(tab, :issue_title) || Map.get(tab, "issue_title")),
      task_summary: blank_to_nil(Map.get(tab, :task_summary) || Map.get(tab, "task_summary")),
      fleet_role: fleet_role,
      fleet_readiness: fleet_readiness,
      ready_no_task_for_seconds: ready_for,
      quiet?: quiet?,
      unseen_quiet?: unseen_quiet?,
      needs_you?: needs_you?,
      attention_reason: attention_reason,
      bucket: bucket,
      active?: Map.get(tab, :active?) == true or Map.get(tab, :active) == true,
      liveness: liveness,
      blocked_on: blocked_on
    }
  catch
    :skip -> nil
  end

  defp row_from_window_tab(_), do: nil

  # External observation only. Missing liveness is nil (not observed), never quiet.
  # `:unknown` keeps its reason so chrome cannot render "could not observe" as idle.
  defp liveness_from_tab(tab) when is_map(tab) do
    case Map.get(tab, :liveness) || Map.get(tab, "liveness") do
      nil ->
        nil

      %{state: state} = live ->
        normalize_liveness(state, live)

      %{"state" => state} = live ->
        normalize_liveness(state, live)

      state when state in [:active, :quiet, :unknown, "active", "quiet", "unknown"] ->
        normalize_liveness(state, %{})

      _ ->
        %{state: :unknown, reason: :malformed}
    end
  end

  defp normalize_liveness(state, live) do
    state = normalize_liveness_state(state)

    base = %{
      state: state,
      quiet_for_seconds: liveness_int(live, :quiet_for_seconds),
      last_write_at: liveness_time(live, :last_write_at),
      commit_count: liveness_int(live, :commit_count)
    }

    case state do
      :unknown ->
        Map.put(base, :reason, liveness_reason(live))

      _ ->
        base
    end
  end

  defp normalize_liveness_state(state) when state in [:active, :quiet, :unknown], do: state
  defp normalize_liveness_state("active"), do: :active
  defp normalize_liveness_state("quiet"), do: :quiet
  defp normalize_liveness_state("unknown"), do: :unknown
  defp normalize_liveness_state(_), do: :unknown

  defp liveness_int(live, key) when is_map(live) do
    case Map.get(live, key) || Map.get(live, Atom.to_string(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp liveness_time(live, key) when is_map(live) do
    case Map.get(live, key) || Map.get(live, Atom.to_string(key)) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp liveness_reason(live) when is_map(live) do
    case Map.get(live, :reason) || Map.get(live, "reason") do
      r when is_atom(r) -> r
      r when is_binary(r) and r != "" -> r
      _ -> :unscanned
    end
  end

  # Structured "blocked on what?" — report-only vs derived-only stay distinct.
  # Never invent a blocker for :working/:idle/:done without an attention reason.
  defp blocked_on_from(:blocked, message, _reason, _liveness) do
    %{kind: :report, reason: :blocked, detail: message}
  end

  defp blocked_on_from(:errored, message, _reason, _liveness) do
    %{kind: :report, reason: :errored, detail: message}
  end

  defp blocked_on_from(:stalled, message, _reason, liveness) do
    detail =
      message ||
        case liveness do
          %{quiet_for_seconds: s} when is_integer(s) and s > 0 ->
            "worktree quiet #{s}s while pane looks busy"

          _ ->
            "worktree quiet while pane looks busy"
        end

    %{kind: :derived, reason: :stalled, detail: detail}
  end

  defp blocked_on_from(_state, _message, :ready_no_task, _liveness) do
    %{kind: :derived, reason: :ready_no_task, detail: "idle capacity, no issue binding"}
  end

  defp blocked_on_from(_state, message, reason, _liveness)
       when reason in [:blocked, :errored, :stalled, :idle, :orphaned_claim] do
    kind = if reason in [:blocked, :errored], do: :report, else: :derived
    %{kind: kind, reason: reason, detail: message}
  end

  defp blocked_on_from(_state, _message, _reason, _liveness), do: nil

  defp fleet_row?(%{agent_state: state})
       when state in [:working, :blocked, :done, :idle, :errored, :stalled],
       do: true

  defp fleet_row?(%{fleet_role: role}) when role in [:manager, :worker], do: true
  defp fleet_row?(%{issue: n}) when is_integer(n), do: true
  defp fleet_row?(%{fleet_readiness: :ready_no_task}), do: true
  defp fleet_row?(%{quiet?: true}), do: true
  defp fleet_row?(_), do: false

  defp needs_you_projection(agent_state, quiet?, fleet_readiness) do
    cond do
      fleet_readiness == :ready_no_task ->
        {true, :ready_no_task}

      agent_state in [:blocked, :errored, :stalled] or
          (quiet? and agent_state in [:done, :idle, nil]) ->
        cls =
          %{
            windows: [
              %{
                agent_state: agent_state,
                quiet: quiet? and agent_state in [:done, :idle, nil]
              }
            ]
          }
          |> Salience.facts_from_session()
          |> Salience.compute()
          |> Delivery.session_classification()

        {cls.section == :needs_you, cls.reason}

      true ->
        {false, nil}
    end
  end

  defp bucket_for(true, _state, _readiness), do: :needs_you
  defp bucket_for(false, :working, _), do: :working
  defp bucket_for(false, _state, :ready_no_task), do: :ready_no_task
  defp bucket_for(false, :idle, _), do: :idle
  defp bucket_for(false, :done, _), do: :done
  defp bucket_for(false, _state, _), do: :unknown

  defp row_sort_key(row) do
    {
      bucket_rank(row.bucket),
      Delivery.session_reason_urgency(row.attention_reason || :recent),
      if(row.unseen_quiet?, do: 0, else: 1),
      -(row.ready_no_task_for_seconds || 0),
      row.display_name
    }
  end

  defp bucket_rank(:needs_you), do: 0
  defp bucket_rank(:working), do: 1
  defp bucket_rank(:ready_no_task), do: 2
  defp bucket_rank(:idle), do: 3
  defp bucket_rank(:done), do: 4
  defp bucket_rank(:unknown), do: 5
  defp bucket_rank(_), do: 6

  defp empty_counts do
    Map.new(@bucket_order, &{&1, 0})
  end

  defp resolve_orphaned_claims(rows, opts) do
    case Keyword.fetch(opts, :orphaned_claims) do
      {:ok, %{} = snap} ->
        snap

      :error ->
        bound = Enum.flat_map(rows, fn row -> if row.issue, do: [row.issue], else: [] end)

        observe_opts =
          opts
          |> Keyword.take([:claimed, :list_claimed, :tmux_session, :repo, :workspace_label, :now])
          |> Keyword.put_new(:bound, bound)

        # Without a claimed source, stay unknown — never invent "no orphans".
        if Keyword.has_key?(observe_opts, :claimed) or
             Keyword.has_key?(observe_opts, :list_claimed) do
          OrphanedClaims.observe(observe_opts)
        else
          OrphanedClaims.unknown(reason: :no_claimed_source)
          |> Map.put(:bound_issues, Enum.uniq(bound) |> Enum.sort())
          |> Map.put(:bound_count, length(Enum.uniq(bound)))
        end
    end
  end

  defp resolve_gate_queue(opts) do
    snap =
      case Keyword.fetch(opts, :gate_queue) do
        {:ok, %{} = snap} ->
          snap

        :error ->
          case GateQueue.observe() do
            {:ok, snap} -> snap
            {:error, _} -> GateQueue.unknown()
          end
      end

    GateQueue.with_positions(snap)
  end

  defp orphan_attention_count(%{observe_state: :ok, orphan_count: n})
       when is_integer(n) and n > 0,
       do: n

  defp orphan_attention_count(_), do: 0

  defp normalize_state(state)
       when state in [:working, :blocked, :done, :idle, :errored, :stalled],
       do: state

  defp normalize_state("working"), do: :working
  defp normalize_state("blocked"), do: :blocked
  defp normalize_state("done"), do: :done
  defp normalize_state("idle"), do: :idle
  defp normalize_state("errored"), do: :errored
  defp normalize_state("stalled"), do: :stalled
  defp normalize_state(_), do: nil

  defp normalize_role(role) when role in [:manager, :worker], do: role
  defp normalize_role("manager"), do: :manager
  defp normalize_role("worker"), do: :worker
  defp normalize_role(_), do: nil

  defp normalize_readiness(:ready_no_task), do: :ready_no_task
  defp normalize_readiness("ready_no_task"), do: :ready_no_task
  defp normalize_readiness(_), do: nil

  defp normalize_issue(n) when is_integer(n) and n > 0, do: n

  defp normalize_issue(n) when is_binary(n) do
    case Integer.parse(String.trim_leading(String.trim(n), "#")) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp normalize_issue(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end

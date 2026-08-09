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
  alias Casein.Terminals.FleetChrome

  @type bucket ::
          :needs_you | :working | :ready_no_task | :idle | :done | :unknown

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
          active?: boolean()
        }

  @type board :: %{
          rows: [row()],
          counts: %{optional(bucket()) => non_neg_integer()},
          attention_count: non_neg_integer(),
          total: non_neg_integer(),
          empty?: boolean()
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

    attention_count = Enum.count(rows, & &1.needs_you?)

    %{
      rows: rows,
      counts: counts,
      attention_count: attention_count,
      total: length(rows),
      empty?: rows == []
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
      empty?: true
    }
  end

  @doc "True when the board has any needs-you row."
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
      active?: Map.get(tab, :active?) == true or Map.get(tab, :active) == true
    }
  catch
    :skip -> nil
  end

  defp row_from_window_tab(_), do: nil

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

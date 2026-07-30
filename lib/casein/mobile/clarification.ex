defmodule Casein.Mobile.Clarification do
  @moduledoc """
  Durable, server-authoritative clarification requests for mobile.

  A request is accepted only after the exact workspace-owned pane is
  revalidated as `role=agent`. The durable event is the source of truth for a
  Needs Me card; clients cannot submit or synthesize this projection.
  """

  alias Casein.Agents.{AgentEvent, AgentEvents}
  alias Casein.Audit
  alias Casein.Export.Sanitizer
  alias Casein.Mobile.{Card, Intervention}
  alias Casein.Origin

  @topic_prefix "mobile:clarifications:"
  @request_type "agent.clarification_requested"
  @resolved_type "agent.clarification_resolved"
  @question_max 200
  @open_limit 250
  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{7,239}\z/

  @spec topic(String.t()) :: String.t()
  def topic(workspace_id), do: @topic_prefix <> workspace_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, topic(workspace_id))
  end

  @spec request(map()) ::
          {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, atom() | term()}
  def request(attrs) when is_map(attrs) do
    with {:ok, workspace_id} <- required(attrs, :workspace_id),
         {:ok, tmux_session} <- required(attrs, :tmux_session_id),
         {:ok, pane_id} <- required(attrs, :pane_id),
         {:ok, expected_agent_session_id} <- identifier(attrs, :agent_session_id),
         {:ok, request_id} <- identifier(attrs, :request_id),
         {:ok, question} <- validate_question(value(attrs, :question)),
         {:ok, target} <-
           Intervention.validate_agent_task_target(
             workspace_id,
             tmux_session,
             pane_id,
             expected_agent_session_id
           ) do
      agent_session_id = target.agent_session_id
      stream_id = "clarification:#{agent_session_id}"

      result =
        AgentEvents.append(%{
          workspace_id: workspace_id,
          stream_id: stream_id,
          producer: "agent",
          ingress: "terminal_mcp",
          source_event_id: "request:#{request_id}",
          event_type: @request_type,
          privacy_class: "operator_content",
          agent_session_id: agent_session_id,
          tmux_session_id: tmux_session,
          pane_id: pane_id,
          actor_id: optional(attrs, :actor_id),
          status: "open",
          summary: "Agent requested clarification",
          payload: %{
            "schema_version" => 1,
            "origin_id" => Origin.id(),
            "request_id" => request_id,
            "question" => question,
            "response_kind" => "short_text"
          }
        })

      case result do
        {:ok, event, :inserted} = inserted ->
          audit("mobile.clarification_requested", event)
          broadcast({:clarification_requested, event})
          inserted

        other ->
          other
      end
    end
  end

  def request(_attrs), do: {:error, :invalid_payload}

  @spec resolve(map(), map()) ::
          {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, atom() | term()}
  def resolve(card, attrs \\ %{}) when is_map(card) and is_map(attrs) do
    with {:ok, request_event_id} <- meta_identifier(card, :clarification_event_id),
         {:ok, request_id} <- meta_identifier(card, :clarification_request_id),
         {:ok, tmux_session} <- locator_identifier(card, :tmux_session),
         {:ok, pane_id} <- locator_identifier(card, :pane),
         {:ok, agent_session_id} <- task_identifier(card),
         {:ok, workspace_id} <- required(card, :workspace_id) do
      result =
        AgentEvents.append(%{
          workspace_id: workspace_id,
          stream_id: "clarification:#{agent_session_id}",
          producer: "casein",
          ingress: "mobile_action",
          source_event_id: "resolved:#{request_event_id}",
          event_type: @resolved_type,
          privacy_class: "metadata",
          agent_session_id: agent_session_id,
          tmux_session_id: tmux_session,
          pane_id: pane_id,
          actor_id: optional(attrs, :actor_id),
          status: "resolved",
          summary: "Clarification resolved",
          payload: %{
            "schema_version" => 1,
            "origin_id" => Origin.id(),
            "request_event_id" => request_event_id,
            "request_id" => request_id,
            "action_id" => optional(attrs, :action_id)
          }
        })

      case result do
        {:ok, event, :inserted} = inserted ->
          audit("mobile.clarification_resolved", event)
          broadcast({:clarification_resolved, request_event_id, event})
          inserted

        other ->
          other
      end
    end
  end

  @spec open_for_workspace(String.t()) :: [AgentEvent.t()]
  def open_for_workspace(workspace_id) when is_binary(workspace_id) do
    AgentEvents.list_open_clarifications(
      workspace_id,
      @request_type,
      @resolved_type,
      limit: @open_limit
    )
  end

  @spec card(AgentEvent.t(), String.t(), String.t()) :: Card.t()
  def card(%AgentEvent{} = event, user_id, workspace_name) do
    Card.clarification(
      %{
        id: "clarification:#{event.workspace_id}:#{event.id}",
        user_id: user_id,
        workspace_id: event.workspace_id,
        workspace_name: workspace_name,
        session_id: event.agent_session_id,
        question: payload(event, "question"),
        task_ref: %{type: "agent_task", id: event.agent_session_id},
        locator: %{
          tmux_session: event.tmux_session_id,
          pane: event.pane_id,
          tab: "terminal"
        },
        clarification_event_id: event.id,
        clarification_request_id: payload(event, "request_id"),
        last_activity_at: event.occurred_at || event.inserted_at
      },
      event.occurred_at || event.inserted_at
    )
  end

  def request_event_id(card) when is_map(card) do
    card |> map_value(:meta) |> map_value(:clarification_event_id)
  end

  defp validate_question(question) when is_binary(question) do
    question = question |> Sanitizer.redact_text() |> String.trim()

    cond do
      question == "" -> {:error, :question_required}
      not String.valid?(question) -> {:error, :question_invalid_characters}
      String.length(question) > @question_max -> {:error, :question_too_long}
      Regex.match?(~r/[\x00-\x1F\x7F]/u, question) -> {:error, :question_invalid_characters}
      true -> {:ok, question}
    end
  end

  defp validate_question(_question), do: {:error, :question_required}

  defp identifier(attrs, key) do
    case value(attrs, key) do
      id when is_binary(id) and byte_size(id) <= 240 ->
        if Regex.match?(@id_pattern, id),
          do: {:ok, id},
          else: {:error, identifier_error(key)}

      _ ->
        {:error, identifier_error(key)}
    end
  end

  defp required(attrs, key) do
    case value(attrs, key) do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, required_error(key)}
    end
  end

  defp identifier_error(:agent_session_id), do: :invalid_agent_session_id
  defp identifier_error(:request_id), do: :invalid_request_id
  defp identifier_error(:id), do: :invalid_id

  defp required_error(:workspace_id), do: :missing_workspace_id
  defp required_error(:tmux_session_id), do: :missing_tmux_session_id
  defp required_error(:tmux_session), do: :missing_tmux_session
  defp required_error(:pane_id), do: :missing_pane_id
  defp required_error(:pane), do: :missing_pane

  defp meta_identifier(card, key), do: card |> map_value(:meta) |> identifier(key)

  defp locator_identifier(card, key),
    do: card |> map_value(:context) |> map_value(:locator) |> required(key)

  defp task_identifier(card) do
    card
    |> map_value(:context)
    |> map_value(:task_ref)
    |> map_value(:id)
    |> then(fn id -> identifier(%{id: id}, :id) end)
  end

  defp audit(action, event) do
    Audit.emit!(%{
      action: action,
      workspace_id: event.workspace_id,
      actor_id: event.actor_id,
      target_type: "agent_clarification",
      target_ref: event.id,
      metadata: %{
        "agent_session_id" => event.agent_session_id,
        "tmux_session" => event.tmux_session_id,
        "pane" => event.pane_id,
        "target_role" => "agent",
        "origin_id" => Origin.id()
      }
    })
  end

  defp broadcast(message) do
    workspace_id =
      case message do
        {:clarification_requested, event} -> event.workspace_id
        {:clarification_resolved, _request_id, event} -> event.workspace_id
      end

    Phoenix.PubSub.broadcast(Casein.PubSub, topic(workspace_id), message)
  end

  defp payload(%AgentEvent{payload: payload}, key), do: map_value(payload, key)
  defp optional(attrs, key), do: value(attrs, key)
  defp value(map, key), do: map_value(map, key)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil
end

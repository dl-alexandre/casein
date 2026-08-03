defmodule Casein.Mobile.Intervention do
  @moduledoc """
  Fail-closed bridge from an authoritative mobile card to one role-marked pane.

  Feed projection is pure: it exposes only a typed agent-role candidate and
  server-declared actions. Dispatch validates the candidate without capturing
  terminal content before claiming a request, and delivery repeats the exact
  validation immediately before paste. For non-clarification cards, "exact"
  means the current non-focused pane at the typed locator still carries
  `role=agent`; clarification cards additionally bind the agent-session id.
  """

  alias Casein.Agents.TerminalOutputFormat
  alias Casein.Export.Sanitizer
  alias Casein.Mobile.ResumeCard
  alias Casein.Terminals
  alias Casein.Terminals.AgentState
  alias Casein.Workspaces

  @follow_up_max_length 280
  @choice_max_length 60
  @choice_limit 4
  @excerpt_lines 8
  # Full-screen agent TUIs commonly leave a block of blank rows below the last
  # rendered message. Capture enough bounded scrollback to reach meaningful
  # output, then trim those rows before taking the compact excerpt.
  @capture_lines 120
  @excerpt_max_chars 1_200
  @intent_messages %{
    "continue_task" => "Continue with the current task.",
    "address_review" => "Address the current review feedback, then report what changed.",
    "summarize_blocker" => "Summarize the blocker and the decision you need from me."
  }
  @delivery_action_ids ["follow_up" | Map.keys(@intent_messages)]
  @choice_action_prefix "choose_"

  @doc """
  Project the privacy-safe intervention contract from typed card metadata.

  This function intentionally performs no workspace lookup, pane listing,
  AgentState lookup, terminal capture, or mutation. The exact candidate is
  revalidated at dispatch and again immediately before delivery.
  """
  @spec project(map()) :: map() | nil
  def project(card) when is_map(card) do
    actions = action_specs(card)

    with [_ | _] <- actions,
         true <- complete_candidate?(card) do
      %{
        version: 2,
        target: %{role: "agent"},
        availability: "revalidated_on_submit",
        action: Enum.find(actions, &(&1.id == "follow_up")),
        actions: actions,
        pwa_path: pwa_path(card)
      }
    else
      _ -> nil
    end
  end

  @doc """
  Produce a bounded diagnostic descriptor for explicit desktop callers.

  Mobile feed rendering uses `project/1` and never calls this capture path.
  """
  @spec describe(map()) :: map() | nil
  def describe(card) when is_map(card) do
    with %{actions: actions} = projection <- project(card),
         {:ok, target} <- authoritative_target(card),
         {:ok, excerpt} <- capture_excerpt(target) do
      projection
      |> Map.put(:recent_output, excerpt)
      |> Map.put(:captured_at, DateTime.utc_now())
      |> Map.put(:actions, actions)
    else
      _ -> nil
    end
  end

  @spec action_spec(String.t() | nil) :: map()
  def action_spec(revision \\ nil) do
    %{
      id: "follow_up",
      label: "Send follow-up",
      style: "primary",
      destructive?: false,
      confirmation: nil,
      input: [
        %{
          name: :message,
          type: :text,
          required: true,
          max_length: @follow_up_max_length
        }
      ]
    }
    |> maybe_put_revision(revision)
  end

  @doc """
  Server-declared work intents for a fresh, exact agent target.

  The fixed messages never come from the client. The revision binds the button
  rendered on a device to the authoritative card locator that is reloaded at
  dispatch time.
  """
  @spec action_specs(map()) :: [map()]
  def action_specs(card) when is_map(card) do
    revision = action_revision(card)

    case map_value(card, :type) do
      type when type in [:clarification, "clarification"] ->
        needs_me_action_specs(card, revision)

      _other ->
        resume_action_specs(ResumeCard.project(card), revision)
    end
  end

  defp needs_me_action_specs(card, revision) do
    context = map_value(card, :context)
    request_kind = map_value(context, :request_kind) || "clarification"
    choices = map_value(context, :choices) || []

    case validated_declared_choices(request_kind, choices) do
      {:ok, []} ->
        [action_spec(revision)]

      {:ok, choices} ->
        choices
        |> Enum.with_index(1)
        |> Enum.map(fn {choice, index} ->
          %{
            id: @choice_action_prefix <> Integer.to_string(index),
            label: choice,
            style: "chip",
            destructive?: false,
            confirmation: nil,
            input: [],
            server_message: choice_message(request_kind, choice)
          }
          |> maybe_put_revision(revision)
        end)

      :error ->
        []
    end
  end

  defp resume_action_specs(resume, revision) do
    case {resume.state, resume.phase} do
      {"needs_attention", "review"} ->
        [
          intent_spec(
            "address_review",
            "Address review",
            "The exact agent will address the current review and report the result.",
            revision
          ),
          action_spec(revision)
        ]

      {"needs_attention", "waiting"} ->
        [
          intent_spec(
            "summarize_blocker",
            "Summarize blocker",
            "The exact agent will state the blocker and decision it needs.",
            revision
          ),
          action_spec(revision)
        ]

      {"working", phase} when phase in ["executing", "testing", "deploying", "unknown"] ->
        [
          intent_spec(
            "continue_task",
            "Continue task",
            "The exact agent will continue the current task.",
            revision
          ),
          action_spec(revision)
        ]

      _terminal_or_partial ->
        []
    end
  end

  @spec available_action(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def available_action(card, action_id) when action_id in @delivery_action_ids,
    do: fetch_available_action(card, action_id)

  def available_action(card, @choice_action_prefix <> _ = action_id),
    do: fetch_available_action(card, action_id)

  def available_action(_card, _action_id), do: {:error, :unsupported_action}

  defp fetch_available_action(card, action_id) do
    with true <- complete_candidate?(card),
         actions when actions != [] <- action_specs(card),
         action when not is_nil(action) <- Enum.find(actions, &(&1.id == action_id)) do
      {:ok, action}
    else
      _ -> {:error, :intervention_unavailable}
    end
  end

  @doc """
  Revalidate the current exact target without reading terminal content.

  `Casein.Mobile.Actions` calls this after origin, revision, params, and actor
  authorization but before claiming an intervention. Delivery performs the
  same authoritative check again and never reuses this preflight result.
  """
  @spec validate_action_target(map()) :: :ok | {:error, atom()}
  def validate_action_target(card) when is_map(card) do
    case authoritative_target(card) do
      {:ok, _target} -> :ok
      {:error, _reason} -> {:error, :intervention_unavailable}
    end
  end

  def validate_action_target(_card), do: {:error, :intervention_unavailable}

  @spec delivery_action?(map()) :: boolean()
  def delivery_action?(%{id: action_id}) when is_binary(action_id),
    do: delivery_action_id?(action_id)

  def delivery_action?(_spec), do: false

  @spec delivery_action_id?(String.t()) :: boolean()
  def delivery_action_id?(action_id) when is_binary(action_id),
    do: action_id in @delivery_action_ids or String.starts_with?(action_id, @choice_action_prefix)

  def delivery_action_id?(_action_id), do: false

  @spec requires_revision?(map()) :: boolean()
  def requires_revision?(%{revision: revision}) when is_binary(revision) and revision != "",
    do: true

  def requires_revision?(_spec), do: false

  defp maybe_put_revision(spec, revision) when is_binary(revision),
    do: Map.put(spec, :revision, revision)

  defp maybe_put_revision(spec, _revision), do: spec

  @spec deliver(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def deliver(card, %{id: "follow_up"}, %{message: message}), do: send_follow_up(card, message)

  def deliver(card, %{id: action_id}, _validated) when is_map_key(@intent_messages, action_id) do
    with {:ok, result} <- send_follow_up(card, Map.fetch!(@intent_messages, action_id)) do
      {:ok,
       result
       |> Map.put("action", action_id)
       |> Map.put("confirmation", confirmation(action_id))}
    end
  end

  def deliver(card, %{id: @choice_action_prefix <> _, server_message: message}, _validated)
      when is_binary(message),
      do: send_follow_up(card, message)

  def deliver(_card, _spec, _validated), do: {:error, :unsupported_action}

  @spec send_follow_up(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def send_follow_up(card, message) when is_binary(message) do
    with {:ok, message} <- validate_message(message),
         {:ok, target} <- authoritative_target(card),
         :ok <- paste(target, message) do
      {:ok,
       %{
         "action" => "follow_up",
         "workspace_id" => target.workspace_id,
         "target_role" => "agent"
       }}
    end
  end

  def send_follow_up(_card, _message), do: {:error, :invalid_payload}

  @doc """
  Revalidate an explicit terminal target against authoritative workspace
  ownership and the current pane role.

  Clarification requests use the same guard as intervention delivery so a
  client locator, focused pane, or stale topology can never manufacture an
  actionable mobile card.
  """
  @spec validate_agent_target(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def validate_agent_target(workspace_id, tmux_session, pane_id) do
    with true <- present?(workspace_id) or {:error, :invalid_card},
         true <- present?(tmux_session) or {:error, :intervention_target_missing},
         true <- present?(pane_id) or {:error, :intervention_target_missing},
         {:ok, workspace} <- normalize_workspace(Workspaces.get(workspace_id)),
         true <-
           Terminals.tmux_session_in_workspace?(tmux_session, workspace) or
             {:error, :workspace_scope_mismatch},
         {:ok, pane} <- exact_agent_pane(tmux_session, pane_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         tmux_session: tmux_session,
         pane_id: pane_id,
         pane: pane
       }}
    end
  rescue
    _ -> {:error, :intervention_unavailable}
  catch
    :exit, _ -> {:error, :intervention_unavailable}
  end

  @doc """
  Revalidate an exact agent pane and bind it to the agent session identity
  reported authoritatively for that pane.
  """
  @spec validate_agent_task_target(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  def validate_agent_task_target(workspace_id, tmux_session, pane_id, expected_agent_session_id) do
    with {:ok, target} <- validate_agent_target(workspace_id, tmux_session, pane_id),
         %{agent_session_id: agent_session_id} when is_binary(agent_session_id) <-
           AgentState.get(tmux_session, pane_id),
         true <-
           expected_agent_session_id in [nil, agent_session_id] or
             {:error, :agent_session_mismatch} do
      {:ok, Map.put(target, :agent_session_id, agent_session_id)}
    else
      nil -> {:error, :agent_session_unavailable}
      %{agent_session_id: _} -> {:error, :agent_session_unavailable}
      {:error, _reason} = error -> error
      false -> {:error, :agent_session_mismatch}
    end
  end

  @spec action_revision(map()) :: String.t()
  def action_revision(card) when is_map(card) do
    locator = locator(card)

    [
      map_value(card, :id),
      map_value(card, :workspace_id),
      map_value(card, :session_id),
      map_value(locator, :tmux_session),
      map_value(locator, :window),
      map_value(locator, :pane),
      map_value(card, :updated_at)
    ]
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Reject terminal control bytes and multiline payloads before they reach tmux.

  The intervention surface is one short natural-language reply, not a generic
  terminal input path. The action spec supplies the same length bound to clients;
  this check is the server-side defense in depth.
  """
  @spec validate_message(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_message(message) when is_binary(message) do
    message = String.trim(message)

    cond do
      message == "" -> {:error, :message_required}
      String.length(message) > @follow_up_max_length -> {:error, :message_too_long}
      not String.valid?(message) -> {:error, :message_invalid_characters}
      Regex.match?(~r/[\x00-\x1F\x7F]/u, message) -> {:error, :message_invalid_characters}
      true -> {:ok, message}
    end
  end

  def validate_message(_message), do: {:error, :invalid_payload}

  @spec pwa_path(map()) :: String.t()
  def pwa_path(card) do
    locator = locator(card)
    workspace_id = map_value(card, :workspace_id)

    query =
      %{
        "session" => map_value(locator, :session_id) || map_value(card, :session_id),
        "tmux_session" => map_value(locator, :tmux_session),
        "window" => map_value(locator, :window),
        "pane" => map_value(locator, :pane),
        "tab" => map_value(locator, :tab)
      }
      |> Enum.reject(fn {_key, value} -> not present?(value) end)
      |> URI.encode_query()

    base = "/workspaces/" <> URI.encode_www_form(to_string(workspace_id))
    if query == "", do: base, else: base <> "?" <> query
  end

  defp authoritative_target(card) do
    locator = locator(card)
    workspace_id = map_value(card, :workspace_id)
    tmux_session = map_value(locator, :tmux_session)
    pane_id = map_value(locator, :pane)

    if map_value(card, :type) in [:clarification, "clarification"] do
      expected_agent_session_id =
        card
        |> map_value(:context)
        |> map_value(:task_ref)
        |> map_value(:id)

      validate_agent_task_target(
        workspace_id,
        tmux_session,
        pane_id,
        expected_agent_session_id
      )
    else
      validate_agent_target(workspace_id, tmux_session, pane_id)
    end
  end

  defp normalize_workspace({:ok, workspace}), do: {:ok, workspace}
  defp normalize_workspace({:error, :not_found}), do: {:error, :workspace_not_found}
  defp normalize_workspace(_result), do: {:error, :workspace_unavailable}

  defp exact_agent_pane(tmux_session, pane_id) do
    panes = tmux().list_session_panes(tmux_session)

    case Enum.find(panes, &(map_value(&1, :id) == pane_id)) do
      nil ->
        {:error, :intervention_target_stale}

      pane ->
        cond do
          map_value(pane, :role) != "agent" ->
            {:error, :intervention_target_role_mismatch}

          map_value(pane, :active) == true ->
            {:error, :intervention_target_focused}

          true ->
            {:ok, pane}
        end
    end
  end

  defp capture_excerpt(target) do
    output =
      tmux().capture_scrollback(
        target.tmux_session,
        target: target.pane_id,
        lines: @capture_lines,
        ansi: false
      )

    excerpt =
      output
      |> TerminalOutputFormat.format(ansi: false)
      |> Sanitizer.redact_text()
      |> redact_structured_secrets()
      |> String.trim()
      |> String.split("\n")
      |> Enum.take(-@excerpt_lines)
      |> Enum.join("\n")
      |> String.slice(0, @excerpt_max_chars)

    if excerpt == "", do: {:error, :intervention_output_unavailable}, else: {:ok, excerpt}
  end

  defp paste(target, message) do
    case tmux().paste_text(
           target.tmux_session,
           message,
           target: target.pane_id,
           submit: true
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, :intervention_delivery_failed}
      {_output, 0} -> :ok
      {_output, _code} -> {:error, :intervention_delivery_failed}
      _ -> {:error, :intervention_delivery_failed}
    end
  rescue
    _ -> {:error, :intervention_delivery_failed}
  catch
    :exit, _ -> {:error, :intervention_delivery_failed}
  end

  defp intent_spec(id, label, description, revision) do
    %{
      id: id,
      label: label,
      description: description,
      revision: revision,
      style: "primary",
      destructive?: false,
      confirmation: nil,
      input: []
    }
  end

  defp choice_message("blocker", choice), do: "Use this recovery action: " <> choice
  defp choice_message(_request_kind, choice), do: "Selected direction: " <> choice

  defp validated_declared_choices("clarification", []), do: {:ok, []}

  defp validated_declared_choices(kind, choices)
       when kind in ["direction", "blocker"] and is_list(choices) do
    minimum = if(kind == "direction", do: 2, else: 1)

    if length(choices) in minimum..@choice_limit and
         Enum.uniq(choices) == choices and
         Enum.all?(choices, &valid_choice?/1),
       do: {:ok, choices},
       else: :error
  end

  defp validated_declared_choices(_request_kind, _choices), do: :error

  defp valid_choice?(choice) when is_binary(choice) do
    String.valid?(choice) and choice != "" and String.trim(choice) == choice and
      String.length(choice) <= @choice_max_length and
      not Regex.match?(~r/[\x00-\x1F\x7F]/u, choice)
  end

  defp valid_choice?(_choice), do: false

  defp confirmation("continue_task"), do: "Continue request delivered to the exact agent."
  defp confirmation("address_review"), do: "Review request delivered to the exact agent."

  defp confirmation("summarize_blocker"),
    do: "Blocker-summary request delivered to the exact agent."

  defp redact_structured_secrets(text) do
    text
    |> String.replace(
      ~r/(["']?(?:token|password|secret|api[_-]?key|authorization)["']?\s*:\s*)["'][^"']*["']/i,
      "\\1\"[REDACTED]\""
    )
    |> String.replace(
      ~r/\b(token|password|secret|api[_-]?key|authorization)\b(\s*[:=]\s*)[^\s,]+/i,
      "\\1\\2[REDACTED]"
    )
  end

  defp locator(card) do
    map_value(map_value(card, :context) || %{}, :locator) || %{}
  end

  defp complete_candidate?(card) do
    candidate = locator(card)

    present?(map_value(card, :workspace_id)) and
      present?(map_value(card, :session_id)) and
      present?(map_value(candidate, :tmux_session)) and
      present?(map_value(candidate, :pane)) and
      task_identity_complete?(card)
  end

  defp task_identity_complete?(card) do
    if map_value(card, :type) in [:clarification, "clarification"] do
      card
      |> map_value(:context)
      |> map_value(:task_ref)
      |> map_value(:id)
      |> present?()
    else
      true
    end
  end

  defp tmux, do: Terminals.tmux_adapter()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_value(_map, _key), do: nil
end

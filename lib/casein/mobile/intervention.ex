defmodule Casein.Mobile.Intervention do
  @moduledoc """
  Fail-closed bridge from an authoritative mobile card to one role-marked pane.

  The client never chooses a target. Both excerpt capture and follow-up delivery
  reload the card's bounded locator, verify that its tmux session belongs to the
  card workspace, and require the exact pane to still carry `role=agent`.
  """

  alias Casein.Agents.TerminalOutputFormat
  alias Casein.Export.Sanitizer
  alias Casein.Terminals
  alias Casein.Workspaces

  @follow_up_max_length 280
  @excerpt_lines 8
  # Full-screen agent TUIs commonly leave a block of blank rows below the last
  # rendered message. Capture enough bounded scrollback to reach meaningful
  # output, then trim those rows before taking the compact excerpt.
  @capture_lines 120
  @excerpt_max_chars 1_200

  @spec describe(map()) :: map() | nil
  def describe(card) when is_map(card) do
    with {:ok, target} <- authoritative_target(card),
         {:ok, excerpt} <- capture_excerpt(target) do
      %{
        version: 1,
        recent_output: excerpt,
        captured_at: DateTime.utc_now(),
        target: %{role: "agent"},
        action: action_spec(),
        pwa_path: pwa_path(card)
      }
    else
      _ -> nil
    end
  end

  @spec action_spec() :: map()
  def action_spec do
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
  end

  @spec available_action(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def available_action(card, "follow_up") do
    case describe(card) do
      %{action: action} -> {:ok, action}
      nil -> {:error, :intervention_unavailable}
    end
  end

  def available_action(_card, _action_id), do: {:error, :unsupported_action}

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

  defp normalize_workspace({:ok, workspace}), do: {:ok, workspace}
  defp normalize_workspace({:error, :not_found}), do: {:error, :workspace_not_found}
  defp normalize_workspace(_result), do: {:error, :workspace_unavailable}

  defp exact_agent_pane(tmux_session, pane_id) do
    panes = tmux().list_session_panes(tmux_session)

    case Enum.find(panes, &(map_value(&1, :id) == pane_id)) do
      nil ->
        {:error, :intervention_target_stale}

      pane ->
        if map_value(pane, :role) == "agent",
          do: {:ok, pane},
          else: {:error, :intervention_target_role_mismatch}
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

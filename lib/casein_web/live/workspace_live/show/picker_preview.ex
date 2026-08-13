defmodule CaseinWeb.WorkspaceLive.Show.PickerPreview do
  # Provenance for the picker preview column (#951).
  #
  # The preview is a confirmation step before jump. A capture without a named
  # source is indistinguishable from a live surface — the same visible-is-not-
  # true class as a stale preview pane. This module names the source explicitly
  # (`live` / `empty` / `forbidden`); the client may relabel a reused reply as
  # `cached`. It does not add a poller and does not capture more than
  # `@preview_lines` of scrollback.
  #
  # Agent chrome comes only from `AgentStateChrome.present/2`. A pane with no
  # live report paints identity only — never an invented idle/ready.
  @moduledoc false

  alias Casein.Terminals
  alias CaseinWeb.WorkspaceLive.Show.AgentStateChrome
  alias CaseinWeb.WorkspaceLive.Show.TerminalState

  @preview_lines 18

  @runtimes %{
    "claude" => "Claude",
    "clauded" => "Claude",
    "opencode" => "OpenCode",
    "grok" => "Grok",
    "codex" => "Codex"
  }

  @doc "Hard cap on picker preview scrollback — do not raise this in the event."
  def preview_lines, do: @preview_lines

  @doc false
  def prompt_line(text), do: prompt_line_index(text)

  @doc """
  Capture + provenance for `terminal:picker_preview`.

  Assigns-free reply: the client renders the header so an open picker is not
  patched. Session is validated against the workspace tmux prefix.
  """
  def reply(socket, params) when is_map(params) do
    case authorized_session(socket, params) do
      {:ok, session} ->
        text = capture_text(socket, session, params)
        build_reply(socket, params, session, text, source_for(text))

      :forbidden ->
        forbidden_reply()
    end
  end

  @doc "Pure identity/chrome projection for tests — no tmux capture."
  def provenance(socket, params) when is_map(params) do
    case authorized_session(socket, params) do
      {:ok, session} ->
        socket
        |> build_reply(params, session, "", "empty")
        |> Map.drop([:text, :source, :scroll_to_prompt, :prompt_line])

      :forbidden ->
        forbidden_reply() |> Map.drop([:text, :source, :scroll_to_prompt, :prompt_line])
    end
  end

  defp authorized_session(socket, params) do
    session =
      case Map.get(params, "tmux-session") do
        s when is_binary(s) and s != "" -> s
        _ -> socket.assigns[:tmux_session]
      end

    ws = socket.assigns.workspace
    prefix = Terminals.tmux_workspace_session_prefix(ws.name || ws.id)

    if is_binary(session) and String.starts_with?(session, prefix) do
      {:ok, session}
    else
      :forbidden
    end
  end

  defp capture_text(_socket, session, params) do
    adapter = TerminalState.tmux_adapter()
    target = capture_target(session, params)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :capture_scrollback, 2) do
      adapter.capture_scrollback(session, target: target, ansi: false, lines: @preview_lines)
    else
      ""
    end
  end

  defp capture_target(session, params) do
    cond do
      match?(%{"pane-id" => pane} when is_binary(pane) and pane != "", params) ->
        params["pane-id"]

      match?(%{"window-id" => window} when is_binary(window) and window != "", params) ->
        "#{session}:#{params["window-id"]}"

      true ->
        session
    end
  end

  defp source_for(""), do: "empty"
  defp source_for(_text), do: "live"

  defp build_reply(socket, params, session, text, source) do
    window = find_window(socket, params)
    pane = find_pane(window, socket, params)

    chrome =
      AgentStateChrome.present(resolved_state(pane, window), resolved_message(pane, window))

    text = String.trim_trailing(to_string(text))

    %{
      text: text,
      source: source,
      session: session_label(socket, session),
      window: window_label(window, params),
      pane: pane_label(pane, params),
      cwd: cwd(pane, socket),
      runtime: runtime(pane, window),
      chrome: chrome_payload(chrome),
      quiet_for_seconds: quiet_for_seconds(pane, window),
      scroll_to_prompt: chrome.known? and chrome.state == :blocked,
      prompt_line: prompt_line_index(text)
    }
  end

  defp forbidden_reply do
    %{
      text: "",
      source: "forbidden",
      session: nil,
      window: nil,
      pane: nil,
      cwd: nil,
      runtime: nil,
      chrome: %{known: false},
      quiet_for_seconds: nil,
      scroll_to_prompt: false,
      prompt_line: nil
    }
  end

  defp chrome_payload(%{known?: false}), do: %{known: false}

  defp chrome_payload(chrome) do
    %{
      known: true,
      state: Atom.to_string(chrome.state),
      chip_text: chrome.chip_text,
      chip_class: chrome.chip_class,
      dot_class: chrome.dot_class,
      label: chrome.label
    }
  end

  defp find_window(socket, params) do
    window_id = blank(Map.get(params, "window-id"))
    tabs = List.wrap(socket.assigns[:tmux_window_tabs])
    raw = List.wrap(socket.assigns[:tmux_windows])

    if is_binary(window_id) do
      Enum.find(tabs, &(to_string(&1.id) == window_id)) ||
        Enum.find(raw, fn w -> to_string(Map.get(w, :id) || Map.get(w, "id")) == window_id end)
    else
      Enum.find(tabs, & &1.active?) || Enum.find(raw, &window_active?/1)
    end
  end

  defp find_pane(window, socket, params) do
    pane_id = blank(Map.get(params, "pane-id"))
    panes = window_panes(window)

    if is_binary(pane_id) do
      Enum.find(panes, fn p -> pane_id(p) == pane_id end) || raw_pane(socket, pane_id)
    else
      Enum.find(panes, &pane_active?/1) || List.first(panes) || raw_active_pane(socket, window)
    end
  end

  defp window_panes(nil), do: []
  defp window_panes(%{panes: panes}) when is_list(panes), do: panes
  defp window_panes(%{pane_list: panes}) when is_list(panes), do: panes
  defp window_panes(%{"panes" => panes}) when is_list(panes), do: panes
  defp window_panes(_), do: []

  defp raw_pane(socket, pane_id) do
    socket.assigns
    |> Map.get(:tmux_windows, [])
    |> List.wrap()
    |> Enum.find_value(fn window ->
      Enum.find(raw_window_panes(window), &(pane_id(&1) == pane_id))
    end)
  end

  defp raw_active_pane(socket, window) do
    window_id = window && (Map.get(window, :id) || Map.get(window, "id"))

    socket.assigns
    |> Map.get(:tmux_windows, [])
    |> List.wrap()
    |> Enum.find_value(fn w ->
      if is_nil(window_id) or
           to_string(Map.get(w, :id) || Map.get(w, "id")) == to_string(window_id) do
        Enum.find(raw_window_panes(w), &pane_active?/1) || List.first(raw_window_panes(w))
      end
    end)
  end

  defp raw_window_panes(window) do
    Map.get(window, :pane_list) || Map.get(window, :panes) || Map.get(window, "pane_list") ||
      Map.get(window, "panes") || []
  end

  defp session_label(socket, session) do
    tab =
      socket.assigns
      |> Map.get(:session_tabs, [])
      |> List.wrap()
      |> Enum.find(&(Map.get(&1, :tmux_session) == session))

    cond do
      is_map(tab) and is_binary(tab[:label]) and tab.label != "" -> tab.label
      is_binary(session) -> session
      true -> nil
    end
  end

  defp window_label(nil, params), do: blank(Map.get(params, "window-id"))

  defp window_label(window, params) do
    blank(Map.get(window, :display_name)) ||
      blank(Map.get(window, :name)) ||
      blank(Map.get(window, "name")) ||
      blank(Map.get(params, "window-id")) ||
      blank(Map.get(window, :id) || Map.get(window, "id"))
  end

  defp pane_label(nil, params), do: blank(Map.get(params, "pane-id"))

  defp pane_label(pane, params) do
    blank(Map.get(pane, :label)) ||
      blank(Map.get(pane, :title)) ||
      pane_id(pane) ||
      blank(Map.get(params, "pane-id"))
  end

  defp cwd(pane, socket) do
    blank(pane && (Map.get(pane, :current_path) || Map.get(pane, "current_path"))) ||
      session_cwd(socket)
  end

  defp session_cwd(socket) do
    tab =
      socket.assigns
      |> Map.get(:session_tabs, [])
      |> List.wrap()
      |> Enum.find(&(Map.get(&1, :id) == socket.assigns[:terminal_sid]))

    blank(tab && Map.get(tab, :cwd))
  end

  defp runtime(pane, window) do
    runtime_name(pane) || runtime_name(window)
  end

  defp runtime_name(nil), do: nil

  defp runtime_name(map) when is_map(map) do
    explicit =
      blank(Map.get(map, :agent_runtime) || Map.get(map, "agent_runtime")) ||
        blank(Map.get(map, :runtime) || Map.get(map, "runtime"))

    case runtime_label(explicit) do
      {:ok, label} -> label
      :error -> command_runtime(map)
    end
  end

  defp command_runtime(map) do
    command =
      blank(Map.get(map, :current_command) || Map.get(map, "current_command")) ||
        blank(Map.get(map, :command) || Map.get(map, "command"))

    case runtime_from_command(command) do
      {:ok, label} -> label
      :error -> nil
    end
  end

  defp runtime_label(nil), do: :error

  defp runtime_label(value) when is_binary(value) do
    Map.fetch(@runtimes, value |> String.downcase() |> String.trim())
  end

  defp runtime_label(value) when is_atom(value), do: runtime_label(Atom.to_string(value))
  defp runtime_label(_), do: :error

  defp runtime_from_command(nil), do: :error

  defp runtime_from_command(command) do
    lowered = String.downcase(command)

    Enum.find_value(@runtimes, fn {key, label} ->
      if String.contains?(lowered, key), do: {:ok, label}
    end) || :error
  end

  defp resolved_state(pane, window) do
    (pane && (Map.get(pane, :agent_state) || Map.get(pane, "agent_state"))) ||
      (window && (Map.get(window, :agent_state) || Map.get(window, "agent_state")))
  end

  defp resolved_message(pane, window) do
    (pane && (Map.get(pane, :agent_state_message) || Map.get(pane, "agent_state_message"))) ||
      (window && (Map.get(window, :agent_state_message) || Map.get(window, "agent_state_message")))
  end

  defp quiet_for_seconds(pane, window) do
    liveness_quiet(pane) || liveness_quiet(window)
  end

  defp liveness_quiet(nil), do: nil

  defp liveness_quiet(map) when is_map(map) do
    live = Map.get(map, :liveness) || Map.get(map, "liveness")

    case live do
      %{quiet_for_seconds: n} when is_integer(n) and n >= 0 -> n
      %{"quiet_for_seconds" => n} when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp prompt_line_index(text) when is_binary(text) and text != "" do
    text
    |> String.split("\n")
    |> Enum.find_index(&blocked_prompt_line?/1)
  end

  defp prompt_line_index(_), do: nil

  defp blocked_prompt_line?(line) do
    trimmed = String.trim(line)

    String.ends_with?(trimmed, "?") or
      String.match?(trimmed, ~r/\b(allow|permission|y\/n|yes\/no|approve)\b/i)
  end

  defp pane_id(nil), do: nil
  defp pane_id(id) when is_binary(id), do: id
  defp pane_id(map) when is_map(map), do: blank(Map.get(map, :id) || Map.get(map, "id"))
  defp pane_id(_), do: nil

  defp window_active?(%{active: true}), do: true
  defp window_active?(%{active?: true}), do: true
  defp window_active?(%{"active" => true}), do: true
  defp window_active?(_), do: false

  defp pane_active?(%{active: true}), do: true
  defp pane_active?(%{active?: true}), do: true
  defp pane_active?(%{"active" => true}), do: true
  defp pane_active?(_), do: false

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_), do: nil
end

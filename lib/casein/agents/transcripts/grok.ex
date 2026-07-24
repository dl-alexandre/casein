defmodule Casein.Agents.Transcripts.Grok do
  @moduledoc false

  @summary_limit 200
  @text_preview_limit 500
  @cursor_prefix "grok:"
  @acp_method "session/update"
  @xai_method "_x.ai/session/update"

  @doc false
  @spec allowed_path?(String.t()) :: boolean()
  def allowed_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    root = matching_sessions_root(expanded)

    is_binary(root) and
      Path.basename(expanded) == "updates.jsonl" and
      expanded != root and
      String.starts_with?(expanded, root <> "/") and
      no_symlink_components?(expanded)
  end

  def allowed_path?(_path), do: false

  @doc false
  @spec allowed_pending_path?(String.t()) :: boolean()
  def allowed_pending_path?(path) when is_binary(path) do
    expanded = Path.expand(path)
    root = matching_sessions_root(expanded)

    expected_location? =
      is_binary(root) and
        Path.basename(expanded) == "updates.jsonl" and
        expanded != root and
        String.starts_with?(expanded, root <> "/")

    expected_location? and pending_path_components_safe?(expanded)
  end

  def allowed_pending_path?(_path), do: false

  @doc """
  Parse Grok's append-only ACP update stream into normalized transcript entries.

  Grok persists an envelope per line (`timestamp`, `method`, `params.update`).
  Older raw ACP notification lines are accepted as well. Rewind markers are
  applied before normalization so only the active conversation branch remains.
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) when is_binary(path) do
    with {:ok, lines} <- read_lines(path) do
      events = parse_lines(lines)
      active_events = active_branch(events)
      since = Keyword.get(opts, :since)
      tail = Keyword.get(opts, :tail, 30)
      full_text? = Keyword.get(opts, :full_text, false) == true

      all_entries = normalize_events(active_events, full_text?)

      {new_events, seen_tool_ids} = split_since(active_events, events, since)

      entries =
        new_events
        |> normalize_events(full_text?, seen_tool_ids)
        |> Enum.take(-max(1, tail))

      {:ok,
       %{
         entries: entries,
         cursor: stream_cursor(events),
         total_on_branch: length(all_entries)
       }}
    end
  end

  # Path is validated by Casein.Agents.Transcripts before read/1 is called.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_lines(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, String.split(body, "\n", trim: false)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_lines(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {line, index}, events ->
      case parse_line(line, index) do
        nil -> events
        event -> [event | events]
      end
    end)
    |> Enum.reverse()
  end

  defp parse_line(line, index) do
    with trimmed when trimmed != "" <- String.trim(line),
         {:ok, raw} when is_map(raw) <- Jason.decode(trimmed),
         {method, params, envelope_timestamp} <- unwrap_envelope(raw),
         update when is_map(update) <- unwrap_update(params),
         tag when is_binary(tag) <- string_field(update, "sessionUpdate") do
      %{
        line: index,
        cursor: @cursor_prefix <> Integer.to_string(index),
        method: method,
        tag: tag,
        update: update,
        timestamp: event_timestamp(params, update, envelope_timestamp),
        event_id: event_id(params, update),
        prompt_index: integer_field(Map.get(update, "_meta", %{}), "promptIndex")
      }
    else
      _ -> nil
    end
  end

  defp unwrap_envelope(%{"params" => params} = raw) when is_map(params) do
    {string_field(raw, "method") || @acp_method, params, Map.get(raw, "timestamp")}
  end

  defp unwrap_envelope(raw), do: {@acp_method, raw, Map.get(raw, "timestamp")}

  defp unwrap_update(%{"update" => update}) when is_map(update), do: update
  defp unwrap_update(%{"sessionUpdate" => _tag} = update), do: update
  defp unwrap_update(_params), do: nil

  # Grok's canonical rewind filtering follows prompt boundaries. Once modern
  # promptIndex metadata appears, unmarked user chunks are mid-turn phantoms
  # and do not open a counted prompt.
  defp active_branch(events) do
    initial = %{
      result_rev: [],
      count: 0,
      prompt_starts: [],
      seen_prompt_marker?: false,
      in_user?: false,
      current_prompt_index: nil
    }

    events
    |> Enum.reduce(initial, &reduce_active_event/2)
    |> Map.fetch!(:result_rev)
    |> Enum.reverse()
  end

  defp reduce_active_event(%{method: @xai_method, tag: "rewind_marker"} = event, state) do
    target =
      integer_field(event.update, "target_prompt_index") ||
        integer_field(event.update, "targetPromptIndex")

    if is_integer(target) and target >= 0 do
      truncate_to_prompt(state, target)
    else
      append_non_user(state, event)
    end
  end

  defp reduce_active_event(%{method: method, tag: "user_message_chunk"} = event, state)
       when method != @xai_method do
    state
    |> track_user_prompt(event.prompt_index)
    |> append_event(event)
  end

  defp reduce_active_event(event, state), do: append_non_user(state, event)

  defp truncate_to_prompt(state, target) do
    truncate_at = Enum.at(state.prompt_starts, target, state.count)

    kept_rev =
      state.result_rev
      |> Enum.reverse()
      |> Enum.take(truncate_at)
      |> Enum.reverse()

    %{
      state
      | result_rev: kept_rev,
        count: truncate_at,
        prompt_starts: Enum.take(state.prompt_starts, target),
        in_user?: false,
        current_prompt_index: nil
    }
  end

  defp track_user_prompt(state, prompt_index) do
    seen_prompt_marker? = state.seen_prompt_marker? or is_integer(prompt_index)
    counts? = not seen_prompt_marker? or is_integer(prompt_index)

    new_run? =
      not state.in_user? or
        ((seen_prompt_marker? or is_integer(prompt_index)) and
           prompt_index != state.current_prompt_index)

    prompt_starts =
      if new_run? and counts? do
        state.prompt_starts ++ [state.count]
      else
        state.prompt_starts
      end

    %{
      state
      | prompt_starts: prompt_starts,
        seen_prompt_marker?: seen_prompt_marker?,
        in_user?: true,
        current_prompt_index: prompt_index
    }
  end

  defp append_non_user(state, event) do
    state
    |> Map.put(:in_user?, false)
    |> Map.put(:current_prompt_index, nil)
    |> append_event(event)
  end

  defp append_event(state, event) do
    %{state | result_rev: [event | state.result_rev], count: state.count + 1}
  end

  defp split_since(active_events, all_events, since) when is_binary(since) and since != "" do
    case cursor_line(all_events, since) do
      nil ->
        {active_events, MapSet.new()}

      line ->
        {seen_events, new_events} = Enum.split_with(active_events, &(&1.line <= line))
        {new_events, seen_tool_ids(seen_events)}
    end
  end

  defp split_since(active_events, _all_events, _since), do: {active_events, MapSet.new()}

  # ToolCallUpdate may immediately follow a ToolCall with a richer title/input.
  # Seed already-observed IDs across incremental pulls so that refinement and
  # completion events never surface as duplicate tool calls.
  defp seen_tool_ids(events) do
    events
    |> Enum.filter(&(&1.tag in ["tool_call", "tool_call_update"]))
    |> Enum.reduce(MapSet.new(), fn event, ids ->
      case string_field(event.update, "toolCallId") do
        nil -> ids
        tool_id -> MapSet.put(ids, tool_id)
      end
    end)
  end

  defp cursor_line(events, @cursor_prefix <> raw_line) do
    with {line, ""} <- Integer.parse(raw_line),
         true <- Enum.any?(events, &(&1.line == line)) do
      line
    else
      _ -> nil
    end
  end

  # Accept eventId as a compatibility cursor for callers that captured Grok's
  # native ACP metadata before Casein introduced its line cursor.
  defp cursor_line(events, event_id) do
    case Enum.find(events, &(&1.event_id == event_id)) do
      nil -> nil
      event -> event.line
    end
  end

  defp stream_cursor([]), do: nil
  defp stream_cursor(events), do: events |> List.last() |> Map.fetch!(:cursor)

  defp normalize_events(events, full_text?, seen_tool_ids \\ MapSet.new()) do
    initial = %{entries_rev: [], text_run: nil, seen_tool_ids: seen_tool_ids}

    events
    |> Enum.reduce(initial, &reduce_normalized_event/2)
    |> flush_text_run()
    |> Map.fetch!(:entries_rev)
    |> Enum.reverse()
    |> Enum.map(&truncate_entry(&1, full_text?))
  end

  defp reduce_normalized_event(%{tag: tag} = event, state)
       when tag in ["user_message_chunk", "agent_message_chunk"] do
    role = if tag == "user_message_chunk", do: "user", else: "assistant"

    case content_text(event.update) do
      text when is_binary(text) and text != "" -> append_text_chunk(state, role, text, event)
      _ -> flush_text_run(state)
    end
  end

  defp reduce_normalized_event(%{tag: tag} = event, state)
       when tag in ["tool_call", "tool_call_update"] do
    state = flush_text_run(state)
    tool_id = string_field(event.update, "toolCallId") || event.cursor

    if MapSet.member?(state.seen_tool_ids, tool_id) or not descriptive_tool_event?(event) do
      state
    else
      entry = %{
        role: "assistant",
        tool_calls: [normalize_tool(event.update)],
        timestamp: event.timestamp,
        cursor: event.cursor
      }

      %{
        state
        | entries_rev: [compact_entry(entry) | state.entries_rev],
          seen_tool_ids: MapSet.put(state.seen_tool_ids, tool_id)
      }
    end
  end

  defp reduce_normalized_event(_event, state), do: flush_text_run(state)

  defp append_text_chunk(%{text_run: %{role: role} = run} = state, role, text, event) do
    separator = if role == "assistant", do: text_separator(run.text, text), else: ""

    %{
      state
      | text_run: %{
          run
          | text: run.text <> separator <> text,
            cursor: event.cursor
        }
    }
  end

  defp append_text_chunk(state, role, text, event) do
    state = flush_text_run(state)

    %{
      state
      | text_run: %{
          role: role,
          text: text,
          timestamp: event.timestamp,
          cursor: event.cursor
        }
    }
  end

  defp flush_text_run(%{text_run: nil} = state), do: state

  defp flush_text_run(%{text_run: run} = state) do
    text = String.trim(run.text)

    entries_rev =
      if text == "" do
        state.entries_rev
      else
        [
          compact_entry(%{
            role: run.role,
            text: text,
            timestamp: run.timestamp,
            cursor: run.cursor
          })
          | state.entries_rev
        ]
      end

    %{state | entries_rev: entries_rev, text_run: nil}
  end

  defp text_separator(left, right) do
    if whitespace_suffix?(left) or whitespace_prefix?(right), do: "", else: " "
  end

  defp whitespace_suffix?(""), do: true
  defp whitespace_suffix?(text), do: String.match?(text, ~r/\s$/u)
  defp whitespace_prefix?(""), do: true
  defp whitespace_prefix?(text), do: String.match?(text, ~r/^\s/u)

  defp content_text(%{"content" => %{"type" => "text", "text" => text}})
       when is_binary(text),
       do: text

  defp content_text(%{"content" => text}) when is_binary(text), do: text
  defp content_text(_update), do: nil

  defp descriptive_tool_event?(%{tag: "tool_call"}), do: true

  defp descriptive_tool_event?(%{update: update}) do
    is_binary(string_field(update, "title")) or is_map(Map.get(update, "rawInput")) or
      is_map(get_in(update, ["_meta", "x.ai/tool"]))
  end

  defp normalize_tool(update) do
    tool_meta = get_in(update, ["_meta", "x.ai/tool"]) || %{}

    name =
      string_field(tool_meta, "name") || string_field(update, "title") ||
        string_field(update, "kind") || "tool"

    input =
      Map.get(update, "rawInput") || Map.get(tool_meta, "input") ||
        locations_input(Map.get(update, "locations"))

    %{name: name, input_summary: summarize_input(input)}
  end

  defp locations_input(locations) when is_list(locations), do: %{"locations" => locations}
  defp locations_input(_locations), do: nil

  defp summarize_input(input) when is_map(input) do
    input
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{inspect_value(value)}" end)
    |> String.slice(0, @summary_limit)
  end

  defp summarize_input(input) when is_binary(input), do: String.slice(input, 0, @summary_limit)
  defp summarize_input(nil), do: ""
  defp summarize_input(input), do: input |> inspect() |> String.slice(0, @summary_limit)

  defp inspect_value(value) when is_binary(value) do
    if String.length(value) > 80, do: String.slice(value, 0, 77) <> "...", else: value
  end

  defp inspect_value(value) when is_map(value) or is_list(value),
    do: value |> Jason.encode!() |> String.slice(0, 80)

  defp inspect_value(value), do: to_string(value)

  defp truncate_entry(%{text: text} = entry, false) when is_binary(text) do
    if String.length(text) > @text_preview_limit do
      %{entry | text: String.slice(text, 0, @text_preview_limit - 3) <> "..."}
    else
      entry
    end
  end

  defp truncate_entry(entry, _full_text?), do: entry

  defp compact_entry(entry) do
    entry
    |> maybe_delete(:timestamp, nil)
    |> maybe_delete(:text, nil)
  end

  defp maybe_delete(map, key, value) do
    if Map.get(map, key) == value, do: Map.delete(map, key), else: map
  end

  @doc false
  @spec activity_hint(String.t(), keyword()) :: String.t() | nil
  def activity_hint(path, opts \\ []) when is_binary(path) do
    tail = Keyword.get(opts, :tail, 10)

    case read(path, Keyword.merge(opts, tail: tail)) do
      {:ok, %{entries: entries}} -> entries |> Enum.reverse() |> pick_activity_hint()
      _ -> nil
    end
  end

  @doc false
  @spec final_assistant_message(String.t()) :: String.t() | nil
  def final_assistant_message(path) when is_binary(path) do
    case read(path, tail: 50) do
      {:ok, %{entries: entries}} ->
        entries
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "assistant", text: text} when is_binary(text) and text != "" -> text
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp pick_activity_hint(entries) do
    Enum.find_value(entries, fn
      %{role: "assistant", tool_calls: [tool | _]} -> hint_from_tool(tool)
      _ -> nil
    end) ||
      Enum.find_value(entries, fn
        %{role: "assistant", text: text} when is_binary(text) and text != "" ->
          String.slice(text, 0, 80)

        %{role: "user", text: text} when is_binary(text) and text != "" ->
          "on: " <> String.slice(text, 0, 60)

        _ ->
          nil
      end)
  end

  defp hint_from_tool(%{name: name, input_summary: input}) do
    case name do
      "Edit" -> file_hint("editing", input)
      "Write" -> file_hint("writing", input)
      "Read" -> file_hint("reading", input)
      _ -> "#{name}#{short_tool_input(input)}"
    end
  end

  defp file_hint(verb, input) do
    case Regex.run(~r/(?:file_path|path)=([^,]+)/, input) do
      [_, path] -> "#{verb} #{Path.basename(path)}"
      _ -> verb
    end
  end

  defp short_tool_input(input) when is_binary(input) and input != "",
    do: " " <> String.slice(input, 0, 40)

  defp short_tool_input(_input), do: ""

  defp event_timestamp(params, update, envelope_timestamp) do
    params_meta = Map.get(params, "_meta", %{})
    update_meta = Map.get(update, "_meta", %{})

    integer_field(params_meta, "agentTimestampMs")
    |> then(&(&1 || integer_field(update_meta, "agentTimestampMs")))
    |> timestamp_from_milliseconds()
    |> then(&(&1 || timestamp_from_envelope(envelope_timestamp)))
  end

  defp timestamp_from_milliseconds(nil), do: nil

  defp timestamp_from_milliseconds(milliseconds) when is_integer(milliseconds) do
    case DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp timestamp_from_envelope(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds, :second) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> nil
    end
  end

  defp timestamp_from_envelope(timestamp) when is_binary(timestamp), do: timestamp
  defp timestamp_from_envelope(_timestamp), do: nil

  defp event_id(params, update) do
    string_field(Map.get(params, "_meta", %{}), "eventId") ||
      string_field(Map.get(update, "_meta", %{}), "eventId")
  end

  defp string_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp string_field(_map, _key), do: nil

  defp integer_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _ -> nil
    end
  end

  defp integer_field(_map, _key), do: nil

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp global_sessions_root do
    home = System.get_env("HOME") || "/home/devbox"
    Path.expand(Path.join([home, ".grok", "sessions"]))
  end

  defp matching_sessions_root(path) do
    global = global_sessions_root()

    cond do
      path != global and String.starts_with?(path, global <> "/") ->
        global

      true ->
        managed_sessions_root(path)
    end
  end

  defp managed_sessions_root(path) do
    home = Path.expand(System.get_env("HOME") || "/home/devbox")
    base = Path.join([home, ".casein", "grok-homes"])
    relative = Path.relative_to(path, base)

    case Path.split(relative) do
      [leader_id, "sessions" | rest] when rest != [] ->
        if Regex.match?(~r/\A[0-9a-f]{24}\z/, leader_id) do
          Path.join([base, leader_id, "sessions"])
        end

      _other ->
        nil
    end
  end

  defp no_symlink_components?(path) do
    home = Path.expand(System.get_env("HOME") || "/home/devbox")
    relative = Path.relative_to(path, home)

    if relative == path or relative == ".." or String.starts_with?(relative, "../") do
      false
    else
      relative
      |> Path.split()
      |> Enum.scan(home, &Path.join(&2, &1))
      |> Enum.all?(fn component ->
        case File.lstat(component) do
          {:ok, %{type: :symlink}} -> false
          {:ok, _stat} -> true
          {:error, _reason} -> false
        end
      end)
    end
  end

  defp pending_path_components_safe?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> no_symlink_components?(path)
      {:error, :enoent} -> no_symlink_components?(Path.dirname(path))
      _other -> false
    end
  end
end

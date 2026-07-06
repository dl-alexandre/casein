defmodule DevIDE.Agents.Transcripts.Claude do
  @moduledoc false

  @summary_limit 200
  @text_preview_limit 500

  @type raw_entry :: map()

  @doc """
  Parse a Claude Code JSONL transcript and return normalized conversation entries
  on the active branch (latest leaf, walking `parentUuid` back to the root).
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) when is_binary(path) do
    with {:ok, lines} <- read_lines(path) do
      entries = parse_lines(lines)
      branch = active_branch(entries)
      since = Keyword.get(opts, :since)
      tail = Keyword.get(opts, :tail, 30)
      full_text? = Keyword.get(opts, :full_text, false) == true

      filtered =
        branch
        |> filter_since(since)
        |> Enum.take(-max(1, tail))

      normalized = Enum.map(filtered, &normalize_entry(&1, full_text?: full_text?))
      cursor = branch_cursor(branch)

      {:ok,
       %{
         entries: normalized,
         cursor: cursor,
         total_on_branch: length(branch)
       }}
    end
  end

  # Path is validated by DevIDE.Agents.Transcripts before read/1 is called.
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
    |> Enum.reduce([], fn {line, index}, acc ->
      case parse_line(line, index) do
        nil -> acc
        entry -> [entry | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp parse_line(line, index) do
    trimmed = String.trim(line)

    if trimmed == "" do
      nil
    else
      case Jason.decode(trimmed) do
        {:ok, map} when is_map(map) ->
          uuid = string_field(map, "uuid")

          if is_binary(uuid) and uuid != "" do
            %{
              uuid: uuid,
              parent_uuid: string_field(map, "parentUuid"),
              type: string_field(map, "type"),
              message: Map.get(map, "message"),
              timestamp: string_field(map, "timestamp"),
              line: index,
              raw: map
            }
          end

        _ ->
          nil
      end
    end
  end

  defp active_branch(entries) do
    by_uuid = Map.new(entries, &{&1.uuid, &1})
    parent_ids = entries |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> MapSet.new()

    leaves =
      entries
      |> Enum.reject(fn entry -> MapSet.member?(parent_ids, entry.uuid) end)
      |> Enum.filter(&conversation_entry?/1)

    case pick_latest_leaf(leaves) do
      nil ->
        entries |> Enum.filter(&conversation_entry?/1) |> Enum.sort_by(& &1.line)

      leaf ->
        walk_branch(leaf, by_uuid)
        |> Enum.filter(&conversation_entry?/1)
    end
  end

  defp pick_latest_leaf([]), do: nil

  defp pick_latest_leaf(leaves) do
    Enum.max_by(leaves, &entry_sort_key/1, fn -> nil end)
  end

  defp walk_branch(entry, by_uuid, acc \\ []) do
    acc = [entry | acc]

    case entry.parent_uuid do
      parent when is_binary(parent) ->
        case Map.get(by_uuid, parent) do
          nil -> acc
          parent_entry -> walk_branch(parent_entry, by_uuid, acc)
        end

      _ ->
        acc
    end
  end

  defp conversation_entry?(entry) do
    entry.type in ["user", "assistant"]
  end

  defp entry_sort_key(entry) do
    {timestamp_sort(entry.timestamp), entry.line}
  end

  defp timestamp_sort(nil), do: 0

  defp timestamp_sort(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp filter_since(branch, since) when is_binary(since) and since != "" do
    case Enum.find_index(branch, &(&1.uuid == since)) do
      nil -> branch
      index -> Enum.drop(branch, index + 1)
    end
  end

  defp filter_since(branch, _), do: branch

  defp branch_cursor([]), do: nil

  defp branch_cursor(branch) do
    branch |> List.last() |> Map.get(:uuid)
  end

  defp normalize_entry(entry, opts) do
    role = entry.type
    {text, tool_calls} = content_parts(entry.message, Keyword.get(opts, :full_text?, false))

    %{
      role: role,
      text: text,
      tool_calls: tool_calls,
      timestamp: entry.timestamp,
      cursor: entry.uuid
    }
    |> compact_entry()
  end

  defp content_parts(%{"role" => _role, "content" => content}, full_text?)
       when is_list(content) do
    {texts, tools} = Enum.reduce(content, {[], []}, &reduce_content_block/2)
    text = join_texts(texts, full_text?)
    {text, summarize_tools(tools)}
  end

  defp content_parts(%{"role" => _role, "content" => content}, full_text?)
       when is_binary(content) do
    {maybe_truncate(content, full_text?), []}
  end

  defp content_parts(_, _), do: {nil, []}

  defp reduce_content_block(%{"type" => "text", "text" => text}, {texts, tools})
       when is_binary(text) do
    {[text | texts], tools}
  end

  defp reduce_content_block(%{"type" => "tool_use", "name" => name} = block, {texts, tools})
       when is_binary(name) do
    input = Map.get(block, "input")
    {texts, [%{name: name, input: input} | tools]}
  end

  defp reduce_content_block(%{"type" => "tool_result", "content" => _}, acc), do: acc

  defp reduce_content_block(_, acc), do: acc

  defp join_texts(texts, full_text?) do
    texts
    |> Enum.reverse()
    |> Enum.map_join("\n", &String.trim/1)
    |> String.trim()
    |> case do
      "" -> nil
      joined -> maybe_truncate(joined, full_text?)
    end
  end

  defp summarize_tools(tools) do
    tools
    |> Enum.reverse()
    |> Enum.map(fn %{name: name, input: input} ->
      %{name: name, input_summary: summarize_input(input)}
    end)
  end

  defp summarize_input(input) when is_map(input) do
    input
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect_value(v)}" end)
    |> String.slice(0, @summary_limit)
  end

  defp summarize_input(input) when is_binary(input), do: String.slice(input, 0, @summary_limit)
  defp summarize_input(input), do: inspect(input) |> String.slice(0, @summary_limit)

  defp inspect_value(value) when is_binary(value) do
    if String.length(value) > 80, do: String.slice(value, 0, 77) <> "...", else: value
  end

  defp inspect_value(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value) |> String.slice(0, 80)

  defp inspect_value(value), do: to_string(value)

  defp maybe_truncate(text, true), do: text

  defp maybe_truncate(text, false) do
    if String.length(text) > @text_preview_limit do
      String.slice(text, 0, @text_preview_limit - 3) <> "..."
    else
      text
    end
  end

  defp compact_entry(%{text: nil, tool_calls: []} = entry) do
    Map.delete(entry, :text)
  end

  defp compact_entry(%{tool_calls: []} = entry), do: Map.delete(entry, :tool_calls)
  defp compact_entry(entry), do: entry

  @doc false
  @spec activity_hint(String.t(), keyword()) :: String.t() | nil
  def activity_hint(path, opts \\ []) when is_binary(path) do
    tail = Keyword.get(opts, :tail, 10)

    case read(path, Keyword.merge(opts, tail: tail)) do
      {:ok, %{entries: entries}} ->
        entries |> Enum.reverse() |> pick_activity_hint()

      _ ->
        nil
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
      %{role: "assistant", tool_calls: [_ | _]} = entry -> hint_from_entry(entry)
      _ -> nil
    end) || Enum.find_value(entries, &hint_from_entry/1)
  end

  defp hint_from_entry(%{role: "assistant", tool_calls: [tool | _]}) do
    hint_from_tool(tool)
  end

  defp hint_from_entry(%{role: "assistant", text: text}) when is_binary(text) and text != "" do
    String.slice(text, 0, 80)
  end

  defp hint_from_entry(%{role: "user", text: text}) when is_binary(text) and text != "" do
    "on: " <> String.slice(text, 0, 60)
  end

  defp hint_from_entry(_entry), do: nil

  defp hint_from_tool(%{name: name, input_summary: input}) when is_binary(name) do
    case name do
      "Edit" -> file_hint("editing", input)
      "Write" -> file_hint("writing", input)
      "Read" -> file_hint("reading", input)
      _ -> "#{name}#{short_tool_input(input)}"
    end
  end

  defp hint_from_tool(_tool), do: nil

  defp file_hint(verb, input) when is_binary(input) do
    case Regex.run(~r/file_path=([^,]+)/, input) do
      [_, path] -> "#{verb} #{Path.basename(path)}"
      _ -> verb
    end
  end

  defp short_tool_input(input) when is_binary(input) and input != "" do
    " " <> String.slice(input, 0, 40)
  end

  defp short_tool_input(_input), do: ""

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end

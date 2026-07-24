defmodule Casein.Codex.ExecProtocol do
  @moduledoc "Normalizes `codex exec --json` JSONL records into canonical events."

  alias Casein.Codex.Event

  @spec normalize(map(), map()) :: {:ok, [Event.t()]} | :ignore | {:error, term()}
  def normalize(%{"type" => "thread.started", "thread_id" => thread_id}, context)
      when is_binary(thread_id) and thread_id != "" do
    {:ok,
     [
       Event.new!(:thread_started, context,
         thread_id: thread_id,
         session_id: thread_id,
         payload: %{status: :active, source: :exec},
         metadata: %{exec_type: "thread.started"}
       )
     ]}
  end

  def normalize(%{"type" => "turn.started"} = record, context) do
    {:ok,
     [
       Event.new!(:turn_started, context,
         thread_id: context[:thread_id],
         turn_id: record["turn_id"] || context[:turn_id],
         payload: %{status: :in_progress},
         metadata: %{exec_type: "turn.started"}
       )
     ]}
  end

  def normalize(%{"type" => type, "item" => item}, context)
      when type in ["item.started", "item.completed"] and is_map(item) do
    item_id = item["id"] || Ecto.UUID.generate()
    event_type = if type == "item.started", do: :item_started, else: :item_completed

    {:ok,
     [
       Event.new!(event_type, context,
         thread_id: context[:thread_id],
         turn_id: context[:turn_id],
         item_id: item_id,
         tool_call_id: item["tool_call_id"],
         payload: bounded_item(item),
         metadata: %{exec_type: type}
       )
     ]}
  end

  def normalize(%{"type" => "turn.completed"} = record, context) do
    usage = normalize_usage(record["usage"])

    completed =
      Event.new!(:turn_completed, context,
        thread_id: context[:thread_id],
        turn_id: record["turn_id"] || context[:turn_id],
        payload: %{status: :completed, usage: usage},
        metadata: %{exec_type: "turn.completed"}
      )

    usage_event =
      Event.new!(:usage_updated, context,
        thread_id: context[:thread_id],
        turn_id: record["turn_id"] || context[:turn_id],
        payload: %{last: usage, total: usage},
        metadata: %{exec_type: "turn.completed"}
      )

    {:ok, [completed, usage_event]}
  end

  def normalize(%{"type" => "turn.failed"} = record, context) do
    {:ok,
     [
       Event.new!(:turn_failed, context,
         thread_id: context[:thread_id],
         turn_id: record["turn_id"] || context[:turn_id],
         payload: %{status: :failed, error: bounded_value(record["error"])},
         metadata: %{exec_type: "turn.failed"}
       )
     ]}
  end

  def normalize(%{"type" => "error"} = record, context) do
    {:ok,
     [
       Event.new!(:error, context,
         thread_id: context[:thread_id],
         turn_id: context[:turn_id],
         payload: %{message: bounded_value(record["message"] || record["error"])},
         metadata: %{exec_type: "error"}
       )
     ]}
  end

  def normalize(%{"type" => _unknown}, _context), do: :ignore
  def normalize(_record, _context), do: {:error, :invalid_exec_record}

  defp bounded_item(item) do
    item
    |> Map.take([
      "type",
      "status",
      "text",
      "command",
      "aggregated_output",
      "exit_code",
      "changes",
      "server",
      "tool",
      "arguments",
      "result",
      "query",
      "items"
    ])
    |> bounded_value()
  end

  defp normalize_usage(usage) when is_map(usage) do
    input_tokens = integer(usage["input_tokens"])
    output_tokens = integer(usage["output_tokens"])
    total_tokens = usage["total_tokens"]

    %{
      input_tokens: input_tokens,
      cached_input_tokens: integer(usage["cached_input_tokens"]),
      output_tokens: output_tokens,
      reasoning_output_tokens: integer(usage["reasoning_output_tokens"]),
      total_tokens:
        if(is_integer(total_tokens), do: total_tokens, else: input_tokens + output_tokens)
    }
  end

  defp normalize_usage(_usage),
    do: %{
      input_tokens: 0,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_output_tokens: 0,
      total_tokens: 0
    }

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0
  defp bounded_value(nil), do: nil
  defp bounded_value(value) when is_binary(value), do: String.slice(value, 0, 32_000)

  defp bounded_value(value) when is_list(value),
    do: value |> Enum.take(100) |> Enum.map(&bounded_value/1)

  defp bounded_value(value) when is_map(value) do
    value
    |> Enum.take(100)
    |> Map.new(fn {key, inner} -> {key, bounded_value(inner)} end)
  end

  defp bounded_value(value), do: value
end

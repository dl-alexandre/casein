defmodule Casein.Terminals.CommandTracker do
  @moduledoc """
  Accumulates OSC 133 tokens into command records for one terminal session.
  """

  alias Casein.Terminals.{CommandLog, CommandRedactor, Osc133, PaneCommand}

  @default_output_limit 64 * 1024

  defstruct [
    :workspace_id,
    :sid,
    :current,
    cwd: nil,
    next_seq: 1,
    osc: Osc133.new()
  ]

  @type t :: %__MODULE__{}

  @spec new(String.t() | nil, String.t() | nil) :: t()
  def new(workspace_id, sid), do: %__MODULE__{workspace_id: workspace_id, sid: sid}

  @spec ingest(t(), binary(), pos_integer()) :: t()
  def ingest(%__MODULE__{} = tracker, data, gen) when is_binary(data) and is_integer(gen) do
    {tokens, osc} = Osc133.scan(tracker.osc, data)

    tokens
    |> Enum.reduce(%{tracker | osc: osc}, fn token, acc -> apply_token(acc, token, gen) end)
  end

  defp apply_token(tracker, {:data, data}, gen), do: append_output(tracker, data, gen)
  defp apply_token(tracker, {:prompt_start}, _gen), do: tracker
  defp apply_token(tracker, {:cwd, cwd}, _gen), do: %{tracker | cwd: cwd || tracker.cwd}

  defp apply_token(tracker, {:command_start, command}, gen),
    do: start_command(tracker, command, gen)

  defp apply_token(tracker, {:output_start, command}, gen),
    do: output_start(tracker, command, gen)

  defp apply_token(tracker, {:command_end, status}, gen), do: finish_command(tracker, status, gen)

  # C (command executed / output begins). The B→C span is the echoed input
  # line, not command output — drop it and start capturing fresh. C with no
  # live command happens with integrations that emit only C/D; treat it as
  # the command start so those still produce records.
  defp output_start(%__MODULE__{current: nil} = tracker, command, gen),
    do: start_command(tracker, command, gen)

  defp output_start(%__MODULE__{current: %PaneCommand{} = command} = tracker, cmd, gen) do
    %{
      tracker
      | current: %{
          command
          | command: command.command || cmd,
            output: "",
            output_truncated?: false,
            gen_range: {elem(command.gen_range, 0), gen}
        }
    }
  end

  defp start_command(%__MODULE__{} = tracker, command, gen) do
    tracker = finish_command(tracker, nil, gen)
    seq = tracker.next_seq

    current = %PaneCommand{
      id: command_id(tracker.workspace_id, tracker.sid, seq),
      workspace_id: tracker.workspace_id,
      sid: tracker.sid,
      seq: seq,
      command: command,
      cwd: tracker.cwd,
      started_at: DateTime.utc_now(),
      gen_range: {gen, gen}
    }

    %{tracker | current: current, next_seq: seq + 1}
  end

  defp append_output(%__MODULE__{current: nil} = tracker, _data, _gen), do: tracker
  defp append_output(tracker, "", _gen), do: tracker

  defp append_output(%__MODULE__{current: %PaneCommand{} = command} = tracker, data, gen) do
    limit = output_limit()
    existing = command.output || ""
    truncated? = command.output_truncated? or byte_size(existing) + byte_size(data) > limit
    output = TerminalCtl.Replay.append(existing, data, limit)

    %{
      tracker
      | current: %{
          command
          | output: output,
            output_truncated?: truncated?,
            gen_range: {elem(command.gen_range, 0), gen}
        }
    }
  end

  defp finish_command(%__MODULE__{current: nil} = tracker, _status, _gen), do: tracker

  defp finish_command(%__MODULE__{current: %PaneCommand{} = command} = tracker, status, gen) do
    command =
      command
      |> Map.put(:ended_at, DateTime.utc_now())
      |> Map.put(:exit_status, status)
      |> Map.put(:gen_range, {elem(command.gen_range, 0), gen})
      |> redact()

    :ok = CommandLog.append(command)
    %{tracker | current: nil}
  end

  defp redact(%PaneCommand{} = command) do
    metadata = %{
      workspace_id: command.workspace_id,
      sid: command.sid,
      seq: command.seq
    }

    %{
      command
      | command: CommandRedactor.redact(command.command, metadata),
        output: CommandRedactor.redact(command.output || "", metadata)
    }
  end

  defp command_id(workspace_id, sid, seq) do
    "cmd:#{workspace_id || "unknown"}:#{sid || "unknown"}:#{seq}"
  end

  defp output_limit do
    Application.get_env(:casein, :terminal_command_output_bytes, @default_output_limit)
  end
end

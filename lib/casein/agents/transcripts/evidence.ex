defmodule Casein.Agents.Transcripts.Evidence do
  @moduledoc """
  Conversation-shape evidence about what an agent is doing, read from its own
  session transcript rather than from anything the agent tells us.

  `Casein.Terminals.AgentLiveness` answers "is this agent doing work?" from the
  worktree. It cannot answer the question the operator actually asks — *is it
  waiting for me?* — because a worktree looks identical whether the agent
  finished, asked a question, or hit a permission prompt.

  The pane title cannot answer it either. Claude's heavy-asterisk marker means
  "ready **or** waiting for input" (see `Casein.Terminals.PaneState`), which is
  why `Casein.Terminals.AgentState` refuses to promote it to `:done`. So a pane
  whose agent is blocked on a question, with hooks absent, is indistinguishable
  from an idle one.

  The transcript distinguishes them. The last conversational turn on the file
  has a *shape*, and the shapes mean different things once the file goes quiet:

    * `:tool_result`, `:tool_call`, `:user` — the agent is mid-exchange. Work is
      outstanding whether or not the process is currently emitting anything.
    * `:sidechain` — the tail belongs to a subagent (`isSidechain`), so the main
      agent is inside a `Task` and is by definition working.
    * `:assistant_prose` — the agent said something and stopped. Nothing is
      outstanding on its side. It is waiting for a human.

  ## Silence gates the verdict, shape decides it

  A transcript written to within `default_silence_seconds/0` says nothing about
  waiting — the agent is mid-turn and the tail is a snapshot of a moving file.
  Only once the file has been quiet for that long does the last shape become a
  verdict.

  ## Absence is not evidence

  Same discipline as `Casein.Terminals.AgentLiveness`, for the same reason: a
  silent zero reads as a confident answer.

    * `{:error, reason}` — the transcript could not be read. Says nothing.
    * `{:ok, %{last_shape: nil}}` — the tail was read and held no conversational
      turn (a fresh or truncated file).
    * `{:ok, %{last_shape: shape}}` — this is the newest turn.

  `classify/2` never returns `:awaiting_input` from an absence, and callers
  holding an `{:error, _}` must render unknown rather than "waiting".

  ## Cost

  One `stat` per call. The tail read happens only when the file is already quiet
  enough for the shape to matter, and reads at most `tail_bytes/0` from the end
  — transcripts of a long session run to tens of megabytes and are never parsed
  whole on this path.
  """

  # Enough to hold a final assistant turn with a long text body plus the turns
  # before it. Larger reads buy nothing: only the tail-most conversational line
  # is consulted.
  @tail_bytes 65_536

  # Below this the file is still being written and the tail is mid-turn. Long
  # enough to sit out an in-flight write, short enough that an operator asking
  # "who needs me" gets an answer inside one glance.
  @default_silence_seconds 30

  @type shape :: :user | :tool_result | :tool_call | :assistant_prose | :sidechain

  @type observation :: %{
          transcript_path: String.t(),
          observed_at: DateTime.t(),
          last_write_at: DateTime.t(),
          silent_for_seconds: non_neg_integer(),
          last_shape: shape() | nil,
          lines_scanned: non_neg_integer(),
          truncated?: boolean()
        }

  @type error_reason :: :enoent | :not_a_file | :unreadable

  @doc "Seconds of transcript silence before the last turn's shape is a verdict."
  @spec default_silence_seconds() :: pos_integer()
  def default_silence_seconds, do: @default_silence_seconds

  @doc "Bytes read from the end of a transcript when shape is needed."
  @spec tail_bytes() :: pos_integer()
  def tail_bytes, do: @tail_bytes

  @doc """
  Observe a Claude Code JSONL transcript's tail.

  The caller must have already resolved and authorized the path — this module
  never discovers transcripts. Options:

    * `:now` — reference time (defaults to `DateTime.utc_now/0`)
    * `:silence_seconds` — below this, the tail is not read at all and
      `last_shape` is `nil` with a `:working` classification
  """
  @spec observe(String.t(), keyword()) :: {:ok, observation()} | {:error, error_reason()}
  def observe(path, opts \\ []) when is_binary(path) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    silence_seconds = Keyword.get(opts, :silence_seconds, @default_silence_seconds)

    with {:ok, size, mtime} <- stat(path) do
      silent_for = max(DateTime.diff(now, mtime, :second), 0)

      {shape, lines, truncated?} =
        if silent_for >= silence_seconds do
          read_shape(path, size)
        else
          # Still moving. Reading the tail would describe a half-written turn.
          {nil, 0, false}
        end

      {:ok,
       %{
         transcript_path: path,
         observed_at: now,
         last_write_at: mtime,
         silent_for_seconds: silent_for,
         last_shape: shape,
         lines_scanned: lines,
         truncated?: truncated?
       }}
    end
  end

  @doc """
  Collapse an observation into `:working | :awaiting_input | :unknown`.

  `:awaiting_input` requires positive evidence: a transcript quiet for at least
  `:silence_seconds` whose last conversational turn is assistant prose. Every
  other readable outcome is `:working`; a tail that held no turn at all is
  `:unknown`, because an empty read is not a finished agent.
  """
  @spec classify(observation(), keyword()) :: :working | :awaiting_input | :unknown
  def classify(%{silent_for_seconds: silent_for} = observation, opts \\ []) do
    silence_seconds = Keyword.get(opts, :silence_seconds, @default_silence_seconds)

    cond do
      silent_for < silence_seconds -> :working
      observation.last_shape == :assistant_prose -> :awaiting_input
      is_nil(observation.last_shape) -> :unknown
      true -> :working
    end
  end

  ## Reading

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        {:ok, size, DateTime.from_unix!(mtime)}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_file}

      {:error, _reason} ->
        {:error, :enoent}
    end
  end

  # Path is authorized by Casein.Agents.Transcripts before this is reached.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_shape(path, size) do
    offset = max(size - @tail_bytes, 0)

    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          case :file.pread(fd, offset, @tail_bytes) do
            {:ok, chunk} -> shape_from_chunk(chunk, offset > 0)
            _other -> {nil, 0, offset > 0}
          end
        after
          File.close(fd)
        end

      {:error, _reason} ->
        {nil, 0, offset > 0}
    end
  end

  defp shape_from_chunk(chunk, truncated?) do
    lines =
      chunk
      |> String.split("\n")
      # A mid-file read almost always starts inside a line; that fragment is not
      # parseable JSON and must not be mistaken for a malformed record.
      |> then(fn lines -> if truncated?, do: tl_or_empty(lines), else: lines end)
      |> Enum.reject(&(String.trim(&1) == ""))

    {shape, scanned} = last_shape(Enum.reverse(lines), 0)
    {shape, scanned, truncated?}
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_partial | rest]), do: rest

  # Walks backwards past bookkeeping lines (summaries, meta, hook records) to the
  # newest line that is actually a conversational turn.
  defp last_shape([], scanned), do: {nil, scanned}

  defp last_shape([line | rest], scanned) do
    case decode_shape(line) do
      nil -> last_shape(rest, scanned + 1)
      shape -> {shape, scanned + 1}
    end
  end

  defp decode_shape(line) do
    case Jason.decode(line) do
      {:ok, entry} when is_map(entry) -> entry_shape(entry)
      _other -> nil
    end
  end

  defp entry_shape(%{"isSidechain" => true}), do: :sidechain

  defp entry_shape(%{"type" => "user"} = entry) do
    # A tool result is recorded as a user turn. It means the agent is mid-tool,
    # which is the opposite of what a genuine user turn at the tail would mean.
    if Map.has_key?(entry, "toolUseResult") or content_has?(entry, "tool_result") do
      :tool_result
    else
      :user
    end
  end

  defp entry_shape(%{"type" => "assistant"} = entry) do
    cond do
      content_has?(entry, "tool_use") -> :tool_call
      content_has?(entry, "text") -> :assistant_prose
      # An assistant turn with neither (e.g. thinking-only) is still mid-turn.
      true -> :tool_call
    end
  end

  # `system`, `summary`, meta and hook records are not turns.
  defp entry_shape(_entry), do: nil

  defp content_has?(%{"message" => %{"content" => content}}, type) when is_list(content) do
    Enum.any?(content, &match?(%{"type" => ^type}, &1))
  end

  defp content_has?(%{"message" => %{"content" => content}}, type) when is_binary(content) do
    type == "text" and String.trim(content) != ""
  end

  defp content_has?(_entry, _type), do: false
end

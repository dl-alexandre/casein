defmodule Casein.Terminals.PaneSubmit do
  @moduledoc """
  Presses Enter in an agent pane and *confirms* the submit actually landed.

  Casein's send paths have always been fire-and-forget: `tmux send-keys … Enter`
  or `paste-buffer` followed by a separate `Enter`, both of which return `:ok`
  as soon as tmux accepts the write to the pty. Whether the agent TUI on the
  other side *consumed* that Enter is a different question, and in practice it
  often does not:

    * a paste buffer is still draining when the Enter arrives, so the TUI folds
      the keypress into the pasted block instead of submitting it;
    * the TUI is in a transient mode (permission prompt, mode picker, resize
      reflow) where Enter means something else, or nothing at all.

  The observable failure is identical in both cases and is the reason this
  module exists: the operator's text sits visibly in the composer, the tool call
  reported `status: "sent"`, and nobody finds out until someone looks at the
  pane. A send that silently did not submit is worse than a send that errored,
  because the caller believes the message was delivered.

  ## What counts as confirmation

  Three independent signals, in priority order:

    * **`:hook`** — a fresh `AgentState` report of `:working` sourced from an
      installed runtime hook. Claude/Grok fire `UserPromptSubmit` the instant a
      prompt is accepted, so this is a direct statement from the runtime that it
      took the input. Authoritative when available.

    * **`:transcript`** — the pane's reported CLI transcript grew after Enter.
      This is the runtime's own session log, not a screen heuristic, and is
      what hook-less-but-logged runtimes (and Claude/Grok when the hook is
      late) can prove consumption with. Absence of a transcript is not a
      failure; the next signal still runs.

    * **`:screen`** — the pane's captured tail changed. At delivery time the
      pane is quiescent by construction (we only inject on `idle`/`done`/
      `blocked`), so a static screen after Enter means the keypress did nothing.
      Weaker than hook/transcript, but runtime-agnostic.

  When the capture comes back blank both times — no tmux capture available, a
  stubbed adapter, a dead pane — and no hook/transcript signal landed, the
  result is `:unavailable`. That is reported honestly rather than being rounded
  up to success or down to failure.

  Unconfirmed submits do **not** auto-retry Enter (`max_enter_presses`, default
  1). A second Enter against a TUI that already accepted the first press can
  submit a placeholder, a partial line, or interrupt the new turn (OpenCode
  "esc interrupt"). The call returns `submit_not_confirmed` and the caller
  decides whether to resend. Callers that still want the old one-retry race
  can pass `max_enter_presses: 2` explicitly.

  ## OpenCode / hook-less TUIs (#886)

  OpenCode does not fire `UserPromptSubmit` hooks. Confirmation is screen-only.
  Two failure modes showed up after paste_text was restored:

    * **Early Enter** while the composer is still draining a large paste is
      folded into the buffer as a newline rather than a submit. Two early
      Enters yield two newlines and `submit_not_confirmed` with the text still
      sitting unsent — exactly the fleet symptom. Settle scales with paste
      size and retries wait longer between presses.
    * **Busy footer** (`esc interrupt`, Braille spinner) is a successful
      submit for OpenCode even when the pasted marker remains visible in the
      transcript. Treating only whole-screen diffs as success missed this and
      encouraged a second Enter that interrupted the turn.

  Busy-footer confirmation is reported as `:screen` (still a capture signal,
  not a hook) so callers do not need a new enum.
  ## Strict vs. reporting

  `strict: true` turns an unconfirmed submit into an error. That is right for
  `Casein.Terminals.NextPrompt`, whose whole contract is "this message reached
  the agent", and which can retry on the pane's next edge.

  The send/paste tools pass `strict: true`: an unconfirmed submit is a tool
  error (`submit_not_confirmed`), not `status: "sent"`. Callers that only need
  the keystroke pass `confirm: false`. The confirmation signals are still
  heuristics, but a silent "sent" while text sits in a composer is worse than
  a false negative the caller can retry.
  """

  alias Casein.Agents.Transcripts
  alias Casein.Terminals.AgentPromptSender
  alias Casein.Terminals.AgentState

  @default_settle_ms 250
  # Extra wait before a *retry* Enter — OpenCode folds an early second press
  # into the composer; giving the first press time to become a submit (or the
  # busy footer to appear) avoids interrupt-on-false-negative (#886).
  @default_retry_settle_ms 400
  @default_poll_ms 100
  @default_attempt_timeout_ms 1_200
  @default_max_enter_presses 1
  @default_capture_lines 40
  # Large pastes need longer drain time before Enter means "submit".
  @settle_bytes_per_ms 8
  @max_settle_ms 2_000

  # Footer / chrome tokens that mean the TUI accepted a turn (OpenCode, etc.).
  # Matched case-insensitively on the captured tail.
  @busy_footer_needles [
    "esc interrupt",
    "esc to interrupt",
    "ctrl+c to stop"
  ]
  @type confirmation :: :hook | :transcript | :screen | :unavailable | :unconfirmed

  @type delivery :: :delivered | :not_confirmed | :uncertain | :skipped

  @type result :: %{
          submitted: boolean() | nil,
          delivery: delivery(),
          confirmation: confirmation(),
          enter_presses: non_neg_integer()
        }

  @doc """
  Paste `text` into `pane` and submit it, confirming the submit landed.

  The paste itself goes through `AgentPromptSender.send_prompt/4` with
  `submit: false`, so chunking, labelling, and audit stay exactly as they are on
  every other prompt path; this module owns only the Enter and its
  confirmation. Options are forwarded to the sender, so `:workspace_id`,
  `:name_session`, `:name_window`, and `:name_pane` all apply.

  Confirmation options: `:confirm` (default `true`), `:max_enter_presses`,
  `:settle_ms`, `:retry_settle_ms`, `:attempt_timeout_ms`, `:poll_ms`,
  `:capture_lines`, `:paste_bytes` (scales settle when set — `deliver/4` sets
  it from the text), and `:capture` (a 0-arity function returning the pane
  tail, for tests).
  Returns `{:ok, sender_result_with_submit_fields}` or `{:error, map}`. A submit
  that could not be confirmed is an **error**, not a warning: the caller asked
  for text to reach an agent, and reporting success for text parked in a
  composer is the bug this module exists to close.
  """
  @spec deliver(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def deliver(session, pane, text, opts \\ [])
      when is_binary(session) and is_binary(pane) and is_binary(text) and is_list(opts) do
    # Whitespace-only input is nothing to say. The sender would happily paste it
    # and this module would then press Enter, submitting a blank turn — a real
    # cost for an agent, from a caller that meant to send nothing.
    text = if String.trim(text) == "", do: "", else: text

    case AgentPromptSender.send_prompt(session, pane, text, Keyword.put(opts, :submit, false)) do
      {:ok, %{chunks_sent: 0} = result} ->
        # Empty prompt: the sender deliberately sends nothing, so there is
        # nothing to submit and pressing Enter would fire a bare newline.
        {:ok,
         Map.merge(result, %{
           submitted: false,
           delivery: :skipped,
           confirmation: :unavailable,
           enter_presses: 0
         })}

      {:ok, result} ->
        confirm_opts =
          opts
          |> Keyword.put_new(:strict, true)
          |> Keyword.put_new(:paste_bytes, byte_size(text))
          |> Keyword.put_new(:written, text)

        case confirm_submit(session, pane, confirm_opts) do
          {:ok, confirmation} -> {:ok, Map.merge(result, confirmation)}
          {:error, error} -> {:error, Map.merge(result, error)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Press Enter in `pane` until the submit is confirmed, or give up with an error.

  Pass `enter_already_sent: true` when the caller's own send path has already
  pressed Enter (`tmux send-keys … Enter`); the first attempt then only waits
  and observes instead of pressing again.
  """
  @spec confirm_submit(String.t(), String.t(), keyword()) :: {:ok, result()} | {:error, map()}
  def confirm_submit(session, pane, opts \\ [])
      when is_binary(session) and is_binary(pane) and is_list(opts) do
    if Keyword.get(opts, :confirm, confirm_by_default?()) do
      session
      |> run_confirm(pane, opts)
      |> apply_strictness(Keyword.get(opts, :strict, false))
    else
      {:ok, %{submitted: nil, delivery: :skipped, confirmation: :unavailable, enter_presses: 0}}
    end
  end

  defp apply_strictness({:unconfirmed, result}, true), do: {:error, result}
  defp apply_strictness({:unconfirmed, result}, _strict), do: {:ok, result}
  defp apply_strictness(other, _strict), do: other

  defp run_confirm(session, pane, opts) when is_binary(pane) do
    capture = capture_fun(session, pane, opts)
    already_sent? = Keyword.get(opts, :enter_already_sent, false)

    # Drain paste / TUI reflow *before* stamping the baseline. An early baseline
    # that still changes during settle would look like a false "screen" confirm
    # before Enter, or hide a real Enter behind reflow noise (#886).
    settle(settle_ms(opts))
    baseline = capture.()
    since = DateTime.utc_now()
    transcript_baseline = transcript_baseline(session, pane, opts)

    attempt(session, pane, %{
      capture: capture,
      baseline: baseline,
      transcript_baseline: transcript_baseline,
      since: since,
      opts: opts,
      presses: if(already_sent?, do: 1, else: 0),
      pending_press?: not already_sent?,
      remaining: max_enter_presses(opts)
    })
  end

  defp attempt(session, pane, %{remaining: remaining} = ctx) when remaining > 0 do
    ctx =
      if ctx.pending_press? do
        # Retry presses wait longer so an early first Enter that became a
        # newline can settle, and so a successful-but-unconfirmed first press
        # has time to show the busy footer before we risk interrupting it.
        if ctx.presses > 0, do: settle(retry_settle_ms(ctx.opts))
        press_enter(session, pane, ctx.opts)
        %{ctx | presses: ctx.presses + 1}
      else
        ctx
      end

    case poll(session, pane, ctx) do
      :hook ->
        {:ok,
         %{submitted: true, delivery: :delivered, confirmation: :hook, enter_presses: ctx.presses}}

      :transcript ->
        {:ok,
         %{
           submitted: true,
           delivery: :delivered,
           confirmation: :transcript,
           enter_presses: ctx.presses
         }}

      :screen ->
        {:ok,
         %{
           submitted: true,
           delivery: :delivered,
           confirmation: :screen,
           enter_presses: ctx.presses
         }}

      :unavailable ->
        # No capture and no hook to read: pressing Enter again would be a blind
        # guess against a pane we cannot observe. Say so instead.
        {:ok,
         %{
           submitted: nil,
           delivery: :uncertain,
           confirmation: :unavailable,
           enter_presses: ctx.presses
         }}

      :unconfirmed ->
        attempt(session, pane, %{
          ctx
          | remaining: ctx.remaining - 1,
            pending_press?: true
        })
    end
  end

  defp attempt(_session, _pane, ctx) do
    {:unconfirmed,
     %{
       error: :submit_not_confirmed,
       submitted: false,
       delivery: :not_confirmed,
       confirmation: :unconfirmed,
       enter_presses: ctx.presses,
       message:
         "Text was written to the pane but the agent never acknowledged the submit after " <>
           "#{ctx.presses} Enter press(es): no runtime hook, transcript advance, or screen " <>
           "change was observed. Enter was not retried. The text may be sitting unsent in " <>
           "the agent's input box. Capture the pane (terminal_capture_agent) to check " <>
           "before resending, and use terminal_set_next_prompt when the agent is mid-turn."
     }}
  end

  # One polling window per Enter press. Both signals are cheap to re-read, so
  # the loop checks them together and returns on whichever lands first.
  defp poll(session, pane, ctx) do
    deadline = System.monotonic_time(:millisecond) + attempt_timeout_ms(ctx.opts)
    poll_ms = poll_ms(ctx.opts)
    do_poll(session, pane, ctx, deadline, poll_ms)
  end

  defp do_poll(session, pane, ctx, deadline, poll_ms) do
    current = ctx.capture.()

    cond do
      hook_confirmed?(session, pane, ctx.since) ->
        :hook

      transcript_confirmed?(session, pane, ctx) ->
        :transcript

      # Busy footer / spinner means the TUI accepted a turn even when the
      # pasted text is still visible in the transcript (OpenCode #886).
      busy_footer?(current) and not busy_footer?(ctx.baseline) ->
        :screen

      screen_changed_text?(current, ctx.baseline) ->
        :screen

      System.monotonic_time(:millisecond) >= deadline ->
        if blank?(ctx.baseline) and blank?(current),
          do: :unavailable,
          else: :unconfirmed

      true ->
        settle(min(poll_ms, max(deadline - System.monotonic_time(:millisecond), 0)))
        do_poll(session, pane, ctx, deadline, poll_ms)
    end
  end

  defp transcript_confirmed?(_session, _pane, ctx) do
    case Keyword.get(ctx.opts, :transcript) do
      fun when is_function(fun, 0) ->
        case fun.() do
          true -> true
          :transcript -> true
          _ -> false
        end

      _ ->
        transcript_advanced?(ctx.transcript_baseline)
    end
  end

  defp transcript_baseline(session, pane, opts) do
    if is_function(Keyword.get(opts, :transcript), 0) do
      nil
    else
      path = Keyword.get(opts, :transcript_path) || reported_transcript_path(session, pane)
      transcript_stat(path)
    end
  end

  defp reported_transcript_path(session, pane) do
    case AgentState.get(session, pane) do
      %{transcript_path: path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp transcript_advanced?(%{path: path, size: size, mtime: mtime}) do
    case transcript_stat(path) do
      %{size: new_size, mtime: new_mtime} when new_size > size or new_mtime > mtime ->
        true

      _ ->
        false
    end
  end

  defp transcript_advanced?(_baseline), do: false

  # path is Transcripts.allowed_path?/1 gated before any stat.
  # sobelow_skip ["Traversal.FileModule"]
  defp transcript_stat(path) when is_binary(path) and path != "" do
    if Transcripts.allowed_path?(path) do
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
          %{path: path, size: size, mtime: mtime}

        _ ->
          nil
      end
    end
  end

  defp transcript_stat(_path), do: nil

  # `UserPromptSubmit` is the runtime saying "I accepted a prompt". Only
  # hook-sourced reports count: the `:dispatch` report Casein writes for its own
  # sends would otherwise confirm every submit trivially.
  defp hook_confirmed?(session, pane, since) do
    case AgentState.get(session, pane) do
      %{state: :working, source: :hook, reported_at: at} ->
        DateTime.compare(at, since) != :lt

      _ ->
        false
    end
  end

  defp screen_changed_text?(current, baseline) do
    not blank?(current) and normalize(current) != normalize(baseline)
  end

  # OpenCode (and similar hook-less TUIs) flip the footer to a cancel/interrupt
  # affordance the moment a turn is accepted. That is a stronger "submitted"
  # signal than a generic redraw, and it stays true while the prompt text is
  # still painted above the spinner.
  defp busy_footer?(text) when is_binary(text) do
    down = String.downcase(text)

    Enum.any?(@busy_footer_needles, &String.contains?(down, &1)) or
      braille_spinner_line?(text)
  end

  defp busy_footer?(_), do: false

  # Braille spinner glyphs in the footer (OpenCode / Claude title spinners).
  defp braille_spinner_line?(text) do
    text
    |> String.split("\n")
    |> Enum.take(-6)
    |> Enum.any?(fn line ->
      String.match?(line, ~r/[\x{2800}-\x{28FF}]{2,}/u)
    end)
  end

  defp press_enter(session, pane, opts) do
    tmux(opts).send_keys(session, "Enter", target: pane)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp capture_fun(session, pane, opts) do
    case Keyword.get(opts, :capture) do
      fun when is_function(fun, 0) ->
        fun

      _ ->
        tmux = tmux(opts)
        lines = Keyword.get(opts, :capture_lines, @default_capture_lines)
        fn -> capture_tail(tmux, session, pane, lines) end
    end
  end

  defp capture_tail(tmux, session, pane, lines) do
    case tmux.capture_scrollback(session, target: pane, ansi: false, lines: lines) do
      output when is_binary(output) -> output
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  # Trailing whitespace differs run to run on a redrawn TUI without the content
  # having changed, so it is stripped before comparison. A moving spinner *is* a
  # content change and is deliberately still counted: it means the pane is alive
  # and reacting, which is the question being asked.
  defp normalize(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.trim()
  end

  defp normalize(_text), do: ""

  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_text), do: true

  defp settle(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp settle(_ms), do: :ok

  defp tmux(opts) do
    Keyword.get(opts, :tmux) || Casein.Terminals.tmux_adapter()
  end

  defp settle_ms(opts) do
    base = config(opts, :settle_ms, @default_settle_ms)
    bytes = Keyword.get(opts, :paste_bytes, 0)

    scaled =
      if is_integer(bytes) and bytes > 0 do
        base + div(bytes, @settle_bytes_per_ms)
      else
        base
      end

    min(scaled, @max_settle_ms)
  end

  defp retry_settle_ms(opts), do: config(opts, :retry_settle_ms, @default_retry_settle_ms)
  defp poll_ms(opts), do: config(opts, :poll_ms, @default_poll_ms)

  defp attempt_timeout_ms(opts),
    do: config(opts, :attempt_timeout_ms, @default_attempt_timeout_ms)

  defp max_enter_presses(opts) do
    opts
    |> config(:max_enter_presses, @default_max_enter_presses)
    |> max(1)
  end

  defp confirm_by_default? do
    Keyword.get(app_config(), :confirm, true)
  end

  defp config(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> Keyword.get(app_config(), key, default)
    end
  end

  defp app_config, do: Application.get_env(:casein, :pane_submit, [])
end

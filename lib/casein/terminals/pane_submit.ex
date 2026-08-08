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

  Two independent signals, in priority order:

    * **`:hook`** — a fresh `AgentState` report of `:working` sourced from an
      installed runtime hook. Claude/Grok fire `UserPromptSubmit` the instant a
      prompt is accepted, so this is a direct statement from the runtime that it
      took the input. Authoritative when available.

    * **`:screen`** — the pane's captured tail changed. At delivery time the
      pane is quiescent by construction (we only inject on `idle`/`done`/
      `blocked`), so a static screen after Enter means the keypress did nothing.
      Weaker than the hook signal, but runtime-agnostic.

  When the capture comes back blank both times — no tmux capture available, a
  stubbed adapter, a dead pane — neither signal can be evaluated and the result
  is `:unavailable`. That is reported honestly rather than being rounded up to
  success or down to failure.

  Unconfirmed submits get **one** extra Enter (`max_enter_presses`, default 2)
  before the call gives up: the recurring cause is a race, and a second press
  after the buffer has drained resolves it. A second Enter on a TUI that already
  submitted lands on an empty composer and is a no-op, which is what makes the
  retry safe to attempt blind. It is never issued when the capture is
  unavailable, because there is nothing to distinguish "did not land" from
  "cannot tell".

  ## Strict vs. reporting

  `strict: true` turns an unconfirmed submit into an error. That is right for
  `Casein.Terminals.NextPrompt`, whose whole contract is "this message reached
  the agent", and which can retry on the pane's next edge.

  The pre-existing send tools default to `strict: false`: they still get the
  retry and now report `submitted: false` with a warning, but an unconfirmed
  result does not become a failed tool call. The confirmation signals are
  heuristics over a screen we do not control, and turning every false negative
  into a hard error would break working orchestration to fix a silent one.
  Callers that need the guarantee ask for it.
  """

  alias Casein.Terminals.AgentPromptSender
  alias Casein.Terminals.AgentState

  @default_settle_ms 250
  @default_poll_ms 100
  @default_attempt_timeout_ms 1_200
  @default_max_enter_presses 2
  @default_capture_lines 40

  @type confirmation :: :hook | :screen | :unavailable | :unconfirmed

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
  `:settle_ms`, `:attempt_timeout_ms`, `:poll_ms`, `:capture_lines`, and
  `:capture` (a 0-arity function returning the pane tail, for tests).

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
        case confirm_submit(session, pane, Keyword.put_new(opts, :strict, true)) do
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
    baseline = capture.()
    since = DateTime.utc_now()
    already_sent? = Keyword.get(opts, :enter_already_sent, false)

    settle(settle_ms(opts))

    attempt(session, pane, %{
      capture: capture,
      baseline: baseline,
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
        press_enter(session, pane, ctx.opts)
        %{ctx | presses: ctx.presses + 1}
      else
        ctx
      end

    case poll(session, pane, ctx) do
      :hook ->
        {:ok,
         %{submitted: true, delivery: :delivered, confirmation: :hook, enter_presses: ctx.presses}}

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
           "#{ctx.presses} Enter press(es): the pane's screen did not change and no runtime " <>
           "hook reported a new turn. The text may be sitting unsent in the agent's input " <>
           "box. Capture the pane (terminal_capture_agent) to check before resending, and " <>
           "use terminal_set_next_prompt when the agent is mid-turn."
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
    cond do
      hook_confirmed?(session, pane, ctx.since) ->
        :hook

      screen_changed?(ctx.capture, ctx.baseline) ->
        :screen

      System.monotonic_time(:millisecond) >= deadline ->
        if blank?(ctx.baseline) and blank?(ctx.capture.()),
          do: :unavailable,
          else: :unconfirmed

      true ->
        settle(min(poll_ms, max(deadline - System.monotonic_time(:millisecond), 0)))
        do_poll(session, pane, ctx, deadline, poll_ms)
    end
  end

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

  defp screen_changed?(capture, baseline) do
    current = capture.()
    not blank?(current) and normalize(current) != normalize(baseline)
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
    Keyword.get(opts, :tmux) || Application.get_env(:casein, :tmux_adapter, Casein.Terminals.Tmux)
  end

  defp settle_ms(opts), do: config(opts, :settle_ms, @default_settle_ms)
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

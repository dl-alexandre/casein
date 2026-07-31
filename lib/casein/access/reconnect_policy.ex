defmodule Casein.Access.ReconnectPolicy do
  @moduledoc """
  One named home for reconnect semantics, shared by every client surface.

  Casein already had these rules, but scattered and re-derived per surface: the
  90s auto-reconnect nudge with a typing guard, the mobile cold-start
  saved-profile reconnect, and the drain/reload coupling. Three
  implementations of one policy drift. This module is the policy; the transports
  call it.

  Pure functions only — no processes, no timers. Callers own their state and
  ask this module what to do next, which is what makes the rules testable
  without wall-clock waiting.

  ## The rules

  * Retry forever with exponential backoff, capped at #{16_000}ms. A transient
    failure must never become permanent.
  * Connectivity change, application activation, credential change, and an
    explicit user retry all **interrupt the current wait** — they do not queue
    behind it.
  * While the device is offline, release the active session and wait **without
    consuming a retry attempt**. Burning the backoff budget against a known-down
    network just means a slow reconnect once it returns.
  * An involuntary close keeps the registration and cache, then retries. Only a
    deliberate teardown discards them.
  * An endpoint counts as `:connected` after the socket opens **and** an initial
    config request succeeds — never on socket open alone.

  That last rule is not pedantry. This box has repeatedly produced
  registrations that outlived their servers, where a port answered but the
  application behind it was gone. "Listening" is not "responsive".
  """

  @base_delay_ms 500
  @max_delay_ms 16_000

  @interrupts [:connectivity_change, :app_activation, :credential_change, :user_retry]

  @type interrupt :: :connectivity_change | :app_activation | :credential_change | :user_retry
  @type close_reason :: :involuntary | :deliberate

  @doc """
  Backoff for `attempt` (1-based), exponential and capped at #{@max_delay_ms}ms.

  Attempt 0 or negative is treated as the first attempt so a caller that has not
  incremented yet still gets a sane delay rather than a crash.
  """
  @spec next_delay_ms(integer()) :: pos_integer()
  def next_delay_ms(attempt) when is_integer(attempt) do
    exponent = max(attempt, 1) - 1

    @base_delay_ms
    |> Kernel.*(2 ** exponent)
    |> trunc()
    |> min(@max_delay_ms)
  end

  @doc "Ceiling for `next_delay_ms/1`."
  @spec max_delay_ms() :: pos_integer()
  def max_delay_ms, do: @max_delay_ms

  @doc "Events that interrupt an in-progress backoff wait."
  @spec interrupts() :: [interrupt()]
  def interrupts, do: @interrupts

  @doc "True when `event` should cut the current wait short."
  @spec interrupt?(atom()) :: boolean()
  def interrupt?(event) when is_atom(event), do: event in @interrupts

  @doc """
  Whether a wait consumes a retry attempt.

  Offline waits do not: the network being down is not evidence that this
  endpoint is bad, so it must not push the backoff toward its ceiling.
  """
  @spec consumes_attempt?(online? :: boolean()) :: boolean()
  def consumes_attempt?(true), do: true
  def consumes_attempt?(false), do: false

  @doc """
  What to do with a session on a given close.

  An involuntary close keeps registration and cache so a reconnect resumes
  rather than rebuilds; a deliberate teardown discards both.
  """
  @spec on_close(close_reason()) :: %{retry?: boolean(), keep_registration?: boolean()}
  def on_close(:involuntary), do: %{retry?: true, keep_registration?: true}
  def on_close(:deliberate), do: %{retry?: false, keep_registration?: false}

  @doc """
  Connection state from the two facts that matter.

  `:connected` requires both an open socket and a successful initial config
  request. A socket that opened but whose config request has not succeeded is
  `:connecting`, never `:connected`.
  """
  @spec connection_state(socket_open? :: boolean(), config_ok? :: boolean()) ::
          :connected | :connecting | :disconnected
  def connection_state(true, true), do: :connected
  def connection_state(true, false), do: :connecting
  def connection_state(false, _config_ok?), do: :disconnected

  @doc """
  Next wait, given attempt count and connectivity.

  Returns the delay plus the attempt number the caller should store. Offline
  waits return the same attempt number they were given.
  """
  @spec next_wait(non_neg_integer(), online? :: boolean()) ::
          %{delay_ms: pos_integer(), attempt: non_neg_integer()}
  def next_wait(attempt, online?) when is_integer(attempt) and is_boolean(online?) do
    if consumes_attempt?(online?) do
      next = attempt + 1
      %{delay_ms: next_delay_ms(next), attempt: next}
    else
      %{delay_ms: next_delay_ms(max(attempt, 1)), attempt: attempt}
    end
  end
end

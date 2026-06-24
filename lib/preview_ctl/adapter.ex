defmodule PreviewCtl.Adapter do
  @moduledoc """
  Behaviour for controllable preview sessions.

  Adapters own browser/runtime state. Callers enforce workspace URL
  boundaries before delegating navigation and fetches.
  """

  @type state :: map()
  @type observation :: map()
  @type target :: %{
          optional(:selector) => String.t(),
          optional(:nth) => non_neg_integer(),
          optional(:x) => integer(),
          optional(:y) => integer()
        }
  @type type_opts :: %{optional(:nth) => non_neg_integer()}

  @callback start_session(session :: map()) :: {:ok, state()} | {:error, term()}
  @callback navigate(state(), url :: String.t()) ::
              {:ok, state(), observation()} | {:error, term()}
  @callback go_back(state()) :: {:ok, state(), observation()} | {:error, term()}
  @callback go_forward(state()) :: {:ok, state(), observation()} | {:error, term()}
  @callback reload(state()) :: {:ok, state(), observation()} | {:error, term()}
  @callback observe(state()) :: {:ok, observation()} | {:error, term()}
  @callback observe_live(state()) :: {:ok, state(), observation()} | {:error, term()}
  @callback click(state(), target()) :: {:ok, state(), observation()} | {:error, term()}
  @callback type(state(), selector :: String.t(), text :: String.t(), type_opts()) ::
              {:ok, state()} | {:error, term()}
  @callback press(state(), key :: String.t()) :: {:ok, state()} | {:error, term()}
  @callback screenshot(state()) ::
              {:ok, state(), observation(), String.t() | nil} | {:error, term()}
  @callback get_storage(state()) :: {:ok, state(), map()} | {:error, term()}
  @callback clear_storage(state()) :: {:ok, state(), map()} | {:error, term()}
  @callback close(state()) :: :ok

  @doc "Start server-side video recording (adapters that support it)."
  @callback record_start(state(), opts :: keyword()) ::
              {:ok, state(), map()} | {:error, term()}
  @doc "Stop recording and return the harvested video path."
  @callback record_stop(state()) :: {:ok, state(), map()} | {:error, term()}

  # Recording is Playwright-only; other adapters (test/memory) need not implement.
  @optional_callbacks record_start: 2, record_stop: 1
end

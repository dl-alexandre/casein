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
          optional(:x) => integer(),
          optional(:y) => integer()
        }

  @callback start_session(session :: map()) :: {:ok, state()} | {:error, term()}
  @callback navigate(state(), url :: String.t()) ::
              {:ok, state(), observation()} | {:error, term()}
  @callback observe(state()) :: {:ok, observation()} | {:error, term()}
  @callback observe_live(state()) :: {:ok, state(), observation()} | {:error, term()}
  @callback click(state(), target()) :: {:ok, state(), observation()} | {:error, term()}
  @callback type(state(), selector :: String.t(), text :: String.t()) ::
              {:ok, state()} | {:error, term()}
  @callback press(state(), key :: String.t()) :: {:ok, state()} | {:error, term()}
  @callback screenshot(state()) ::
              {:ok, state(), observation(), String.t() | nil} | {:error, term()}
  @callback get_storage(state()) :: {:ok, state(), map()} | {:error, term()}
  @callback close(state()) :: :ok
end

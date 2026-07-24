defmodule CaseinPreviewBrowser.Backend do
  @moduledoc """
  Behaviour implemented by browser runtime backends.

  Backends own runtime-specific resources. They should keep this surface narrow
  and return plain Elixir data to the session process.
  """

  alias CaseinPreviewBrowser.Screenshot

  @type runtime_state :: term()
  @type browser_ref :: term()
  @type browser_id :: String.t()
  @type observation :: map()
  @type cdp_result :: map()

  @callback start_runtime(keyword()) :: {:ok, runtime_state()} | {:error, term()}

  @callback open_browser(runtime_state(), browser_id(), keyword()) ::
              {:ok, runtime_state(), browser_ref()} | {:error, term()}

  @callback navigate(runtime_state(), browser_ref(), url :: String.t()) ::
              {:ok, runtime_state(), observation()} | {:error, term()}

  @callback observe(runtime_state(), browser_ref()) ::
              {:ok, observation()} | {:error, term()}

  @callback cdp(runtime_state(), browser_ref(), method :: String.t(), params :: map()) ::
              {:ok, runtime_state(), cdp_result()} | {:error, term()}

  @callback screenshot(runtime_state(), browser_ref(), keyword()) ::
              {:ok, runtime_state(), Screenshot.t()} | {:error, term()}

  @callback close_browser(runtime_state(), browser_ref()) ::
              {:ok, runtime_state()} | {:error, term()}

  @callback stop_runtime(runtime_state()) :: :ok

  @optional_callbacks stop_runtime: 1
end

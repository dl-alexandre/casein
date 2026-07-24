defmodule Casein.Push.Provider do
  @moduledoc """
  Behaviour for an OS push transport. Implementations map a delivery-agnostic
  notification (from audit alerts or mobile cards) onto a concrete provider —
  APNs, FCM, or the default `Casein.Push.LogProvider` stub.

  `platform` is the device-reported string (e.g. `"ios"`, `"android"`) and must
  be treated as untrusted (never atomized). Implementations should be
  non-blocking or fast; the dispatcher calls them inline per token.
  """

  @callback push(token :: String.t(), platform :: String.t(), notification :: map()) ::
              :ok | {:error, term()}

  @callback configured_for?(platform :: String.t()) :: :ok | {:error, term()}
  @callback configured?() :: :ok | {:error, term()}

  @optional_callbacks configured_for?: 1, configured?: 0
end

defmodule DevIDE.Push.WebPush do
  @moduledoc """
  Shared Web Push helpers for the provider and the HTTP surface. Reads the
  VAPID config written in `config/runtime.exs`; everything is nil/false when
  Web Push is not configured.
  """
  alias DevIDE.Push.WebPush.Vapid

  @doc "The base64url VAPID public key the browser needs as `applicationServerKey`, or nil."
  @spec public_key_b64() :: String.t() | nil
  def public_key_b64 do
    case Application.get_env(:dev_ide, DevIDE.Push.WebPushProvider) do
      %{public_key: pub} = cfg when is_binary(pub) -> Vapid.public_key_b64(cfg)
      _ -> nil
    end
  end

  @doc "Whether Web Push is configured (VAPID keys present)."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(public_key_b64())
end

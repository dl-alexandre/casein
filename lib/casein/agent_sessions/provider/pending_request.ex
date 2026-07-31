defmodule Casein.AgentSessions.Provider.PendingRequest do
  @moduledoc """
  One approval/permission request, normalized across providers.

  This exists so a single component can render both shapes Casein already has:

    * **Option-list providers** (Grok/ACP) supply their own choices; the operator
      picks one by opaque `option_id`. Today `grok_permission_events.ex` renders
      these, defaulting a missing title to "Grok needs permission to continue".
    * **Policy providers** (Codex) have no option list. `ApprovalBroker` accepts
      `:accept`, `:accept_for_session`, `:decline`, `:cancel`, plus
      `{:accept_with_execpolicy_amendment, [String.t()]}` and
      `{:apply_network_policy_amendment, map()}`.

  `options` is `nil` for policy providers and a list for option-list providers.
  That single nullable field is what lets one component branch instead of two
  components diverging — which is what happened: `codex_events.ex` accepts only
  `:accept | :decline` while `grok_permission_events.ex` speaks `option_id`, so
  Codex's amendments are currently unreachable from the UI.

  ## First response wins

  `GrokACP` broadcasts a permission request to every subscriber and the **first
  response wins**; `Attachments` mediates. Multi-viewer is normal in Casein, so a
  second responder legitimately gets `{:error, :permission_not_found}`. Consumers
  must treat that as "someone else answered", not as a failure to surface.
  """

  @enforce_keys [:provider_id, :request_id, :title]
  defstruct [
    :provider_id,
    :session_ref,
    :request_id,
    :title,
    :detail,
    :options,
    :requested_at,
    metadata: %{}
  ]

  @type option :: %{id: String.t(), label: String.t(), kind: atom() | nil}

  @type t :: %__MODULE__{
          provider_id: atom(),
          session_ref: term(),
          request_id: term(),
          title: String.t(),
          detail: String.t() | nil,
          options: [option()] | nil,
          requested_at: DateTime.t() | nil,
          metadata: map()
        }

  @default_title "Agent needs permission to continue"

  @doc """
  Build a normalized request.

  A blank or missing title falls back to a generic prompt rather than rendering
  an empty row — an approval the operator cannot read is an approval they cannot
  grant.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    %__MODULE__{
      provider_id: Map.fetch!(attrs, :provider_id),
      session_ref: Map.get(attrs, :session_ref),
      # @enforce_keys only requires the key to be present, so a nil id would
      # pass and produce a row the operator can see but never resolve. Reject it
      # at construction instead.
      request_id: require_request_id(Map.fetch!(attrs, :request_id)),
      title: present_string(Map.get(attrs, :title), @default_title),
      detail: presence(Map.get(attrs, :detail)),
      options: normalize_options(Map.get(attrs, :options)),
      requested_at: Map.get(attrs, :requested_at),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @doc """
  True when the operator picks from a provider-supplied list.

  Drives which affordance the UI renders; do not branch on `provider_id`.
  """
  @spec option_list?(t()) :: boolean()
  def option_list?(%__MODULE__{options: options}), do: is_list(options) and options != []

  @doc "Default title used when a provider supplies none."
  @spec default_title() :: String.t()
  def default_title, do: @default_title

  defp require_request_id(nil) do
    raise ArgumentError,
          "request_id is required — a pending request with no id renders a row " <>
            "the operator can see but never resolve"
  end

  defp require_request_id(id), do: id

  defp normalize_options(nil), do: nil
  defp normalize_options([]), do: nil

  defp normalize_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        id: to_string(fetch_option(option, :id)),
        label: present_string(fetch_option(option, :label), to_string(fetch_option(option, :id))),
        kind: fetch_option(option, :kind)
      }
    end)
  end

  defp fetch_option(option, key) when is_map(option),
    do: Map.get(option, key) || Map.get(option, to_string(key))

  defp present_string(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp present_string(_value, fallback), do: fallback

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end

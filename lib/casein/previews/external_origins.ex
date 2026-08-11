defmodule Casein.Previews.ExternalOrigins do
  @moduledoc """
  Operator-controlled allowlist for preview origins that are **not** a workspace
  surface.

  Every other preview lane resolves its URL from the workspace itself (a manager
  domain, a declared port, a terminal-detected dev server). That makes the
  workspace the security boundary: an agent can only ever point a browser at
  something the workspace already owns.

  A sibling product on its own host — a shared staging deployment an agent is
  asked to smoke-walk — has no workspace surface here, so it is unreachable
  through those lanes. This module is the deliberate, narrow exception: an
  operator names the external origins that preview may open, and nothing else
  passes.

  Fail-closed by construction:

    * The allowlist is empty unless an operator populates it. No default host,
      no "same apex as the workspace" inference.
    * Only the deployment (`CASEIN_PREVIEW_EXTERNAL_ORIGINS`) or workspace
      metadata (`external_preview_origins`, operator-managed) can add an origin.
      Nothing an agent passes at call time widens it.
    * Matching is scheme + port exact, host exact-or-subdomain — the same
      semantics as every other preview allowlist (`PreviewCtl.Origin`), so
      `https://example.com` covers `https://dev.example.com` but never
      `http://example.com` or `https://example.com.evil.test`.

  Opening an external origin still preserves that origin end to end: the browser
  navigates to the real URL, so an app's own router, CSRF token, cookies, and
  LiveView `wss://` join all see the host they were built for. This is why the
  lane is an allowlist rather than a proxy — a path-prefixed proxy origin is
  exactly what reconnect-loops a LiveView app (see
  `docs/preview-external-origins.md`).
  """

  alias Casein.Previews.Url
  alias PreviewCtl.Origin

  @env_var "CASEIN_PREVIEW_EXTERNAL_ORIGINS"
  @metadata_key :external_preview_origins

  @doc """
  Origins this workspace may open as an external preview.

  The union of the deployment allowlist and the workspace's own
  operator-managed metadata list. Empty means the lane is off.
  """
  @spec allowlist(map() | nil) :: [String.t()]
  def allowlist(workspace \\ nil) do
    (configured_origins() ++ workspace_origins(workspace))
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Deployment-wide allowlist from application config (set from `#{@env_var}`)."
  @spec configured_origins() :: [String.t()]
  def configured_origins do
    :casein
    |> Application.get_env(:preview_external_origins, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @doc "Per-workspace allowlist from operator-managed workspace metadata."
  @spec workspace_origins(map() | nil) :: [String.t()]
  def workspace_origins(workspace) when is_map(workspace) do
    workspace
    |> metadata()
    |> metadata_value(@metadata_key)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  def workspace_origins(_workspace), do: []

  @doc "The env var an operator sets to enable this lane."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  Validate a caller-supplied external preview URL against the allowlist.

  Returns the URL unchanged on success. Every failure is a structured,
  actionable error map — an agent that hits one should be able to tell the
  operator exactly what to configure without reading this source.
  """
  @spec validate(term(), map() | nil) :: {:ok, String.t()} | {:error, map()}
  def validate(url, workspace \\ nil)

  def validate(url, workspace) when is_binary(url) do
    allowed = allowlist(workspace)

    cond do
      not Url.http_url?(url) ->
        {:error,
         %{
           error: :invalid_external_url,
           url: url,
           message:
             "preview_open mode=external needs an absolute http(s) URL, " <>
               "for example https://staging.example.com/login."
         }}

      allowed == [] ->
        {:error,
         %{
           error: :external_previews_not_configured,
           url: url,
           env_var: @env_var,
           workspace_metadata_key: to_string(@metadata_key),
           message:
             "External-origin previews are not enabled on this deployment. An operator must " <>
               "set #{@env_var} (comma-separated origins, e.g. https://staging.example.com) " <>
               "or add external_preview_origins to the workspace metadata. No preview pane was opened."
         }}

      not Origin.trusted_embed?(url, allowed) ->
        {:error,
         %{
           error: :external_origin_not_allowed,
           url: url,
           origin: Url.origin_of(url),
           allowed_origins: allowed,
           env_var: @env_var,
           message:
             "#{Url.origin_of(url)} is not in the external preview allowlist. " <>
               "Allowed: #{Enum.join(allowed, ", ")}. No preview pane was opened."
         }}

      true ->
        {:ok, url}
    end
  end

  def validate(url, _workspace) do
    {:error,
     %{
       error: :invalid_external_url,
       url: inspect(url),
       message: "preview_open mode=external requires a url string."
     }}
  end

  defp normalize(origin) when is_binary(origin) do
    case Origin.origin_of(origin) do
      resolved when is_binary(resolved) ->
        resolved

      # A bare host ("staging.example.com") is a common operator typo for an
      # origin. Read it as https rather than silently dropping the entry.
      _ ->
        if String.contains?(origin, "://"), do: nil, else: Origin.origin_of("https://" <> origin)
    end
  end

  defp normalize(_), do: nil

  defp metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(workspace) when is_map(workspace), do: workspace

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil
end

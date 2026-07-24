defmodule CaseinWeb.PairingController do
  @moduledoc """
  Mobile companion pairing page. Renders, for an authenticated cockpit user, a
  QR + copyable credentials the Casein mobile app uses to connect its
  `DevideMob.SessionClient` to `session:<workspace_id>`.

  The token is minted with `CaseinWeb.ChannelAuth.sign_pairing_token/2`: a
  short-lived, workspace-scoped token accepted only by `session:<workspace_id>`.
  The session channel still re-checks workspace ownership before exposing state.
  """
  use CaseinWeb, :controller

  alias CaseinWeb.ChannelAuth
  alias Casein.Origin
  alias Casein.Workspaces

  # Every interpolation in page/4 is Plug.HTML.html_escape'd (workspace_id, base,
  # code); qr_svg is derived from a Base64url string (safe charset) rendered as
  # the intended SVG markup. Sobelow can't see through the string-built HTML.
  # sobelow_skip ["XSS.HTML"]
  def show(conn, %{"workspace_id" => workspace_id}) do
    user = conn.assigns[:current_user] || %{}
    user_id = user[:id]

    with true <- is_binary(user_id),
         {:ok, workspace} <- Workspaces.get(workspace_id),
         true <- Workspaces.viewer_terminal_owner?(workspace, user) do
      token = ChannelAuth.sign_pairing_token(user, workspace_id)
      base = base_url(conn)

      # One opaque pairing code carries everything the device needs. The QR
      # encodes it (scan path) and it's shown as copyable text (paste path), so
      # both device-input methods consume the same string.
      code =
        %{
          url: base,
          token: token,
          token_type: "mobile_pairing",
          expires_in: ChannelAuth.pairing_token_max_age_seconds(),
          workspace_id: workspace_id,
          token_exchange_url: base <> "/api/device-links/exchange",
          origin: Origin.pairing_descriptor(base),
          resources: [
            %{
              kind: "workspace",
              id: workspace_id,
              label: workspace_label(workspace, workspace_id)
            }
          ],
          capabilities: [
            "phoenix_socket",
            "dev_ide.session",
            "dev_ide.mobile_cards"
          ]
        }
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      qr_svg = code |> EQRCode.encode() |> EQRCode.svg(width: 280)

      html(conn, page(workspace_id, base, code, qr_svg))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> html("<p>Workspace not found.</p>")

      _ ->
        conn
        |> put_status(:forbidden)
        |> html("<p>You are not allowed to pair this workspace.</p>")
    end
  end

  # The address the device must reach — reflects how the cockpit was loaded, so
  # pairing from a LAN/public hostname embeds that host (not localhost).
  defp base_url(conn) do
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end

  defp workspace_label(workspace, fallback) when is_map(workspace) do
    Map.get(workspace, :name) || Map.get(workspace, "name") || fallback
  end

  defp page(workspace_id, base, code, qr_svg) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Pair mobile companion — #{Plug.HTML.html_escape(workspace_id)}</title>
      <style>
        body { font-family: system-ui, sans-serif; background:#0f1115; color:#e6e6e6;
               margin:0; display:flex; min-height:100vh; align-items:center; justify-content:center; }
        .card { background:#181b22; border:1px solid #262b35; border-radius:12px;
                padding:28px 32px; max-width:420px; text-align:center; }
        h1 { font-size:18px; margin:0 0 4px; }
        .sub { color:#8b93a2; font-size:13px; margin:0 0 20px; }
        .qr { background:#fff; border-radius:8px; padding:12px; display:inline-block; }
        .field { text-align:left; margin-top:18px; }
        .field label { display:block; font-size:11px; color:#8b93a2; margin-bottom:4px; text-transform:uppercase; letter-spacing:.04em; }
        .field code { display:block; background:#0f1115; border:1px solid #262b35; border-radius:6px;
                      padding:8px 10px; font-size:12px; word-break:break-all; color:#cdd3dd; }
        .hint { color:#8b93a2; font-size:12px; margin-top:18px; line-height:1.5; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Pair mobile companion</h1>
        <p class="sub">Workspace <strong>#{Plug.HTML.html_escape(workspace_id)}</strong></p>
        <div class="qr">#{qr_svg}</div>
        <div class="field"><label>Host</label><code>#{Plug.HTML.html_escape(base)}</code></div>
        <div class="field"><label>Workspace</label><code>#{Plug.HTML.html_escape(workspace_id)}</code></div>
        <div class="field"><label>Pairing code</label><code>#{Plug.HTML.html_escape(code)}</code></div>
        <p class="hint">In the Casein app, open <strong>Sessions → Pair</strong> and scan this code,
        or paste the pairing code above. The device will join this workspace's live session feed.</p>
      </div>
    </body>
    </html>
    """
  end
end

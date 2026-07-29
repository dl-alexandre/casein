defmodule CaseinWeb.PairingController do
  @moduledoc """
  Mobile companion pairing page. Renders, for an authenticated cockpit user, a
  QR + copyable one-time handle the Casein mobile app exchanges for a durable,
  workspace-scoped device link.

  The compact QR contains only the canonical origin and an opaque handle. User,
  workspace, capabilities, audience, origin binding, expiry, and consumption
  state remain in a server-side pending record.
  """
  use CaseinWeb, :controller

  alias Casein.DeviceLinks
  alias Casein.Origin
  alias Casein.Workspaces

  @max_pairing_code_bytes 220
  @pairing_refresh_margin_seconds 15

  def show(conn, %{"workspace_id" => workspace_id}) do
    request_base = base_url(conn)

    with :ok <- Origin.authorize_request_base(request_base) do
      show_pairing(conn, workspace_id, Origin.public_base_url(request_base))
    else
      {:error, :origin_mismatch} ->
        redirect(conn,
          external: Origin.canonical_base_url() <> ~p"/pair/#{workspace_id}"
        )
    end
  end

  # Every interpolation in page/4 is Plug.HTML.html_escape'd (workspace_id, base,
  # code); qr_svg is derived from a Base64url string (safe charset) rendered as
  # the intended SVG markup. Sobelow can't see through the string-built HTML.
  # sobelow_skip ["XSS.HTML"]
  defp show_pairing(conn, workspace_id, base) do
    user = conn.assigns[:current_user] || %{}
    user_id = user[:id]

    with true <- is_binary(user_id),
         {:ok, workspace} <- Workspaces.get(workspace_id),
         true <- Workspaces.viewer_terminal_owner?(workspace, user) do
      with {:ok, pending} <- DeviceLinks.issue_pairing_handle(user, workspace_id, base),
           {:ok, code} <- compact_pairing_code(base, pending.handle) do
        qr_svg = code |> EQRCode.encode() |> EQRCode.svg(width: 360)

        conn
        |> put_resp_header("cache-control", "no-store, max-age=0")
        |> put_resp_header("pragma", "no-cache")
        |> html(
          page(
            workspace_id,
            base,
            code,
            qr_svg,
            pending.expires_in,
            refresh_in(pending.expires_in)
          )
        )
      else
        {:error, %Ecto.Changeset{}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> html("<p>Could not create a pairing code.</p>")

        {:error, :pairing_code_too_large} ->
          conn
          |> put_status(:unprocessable_entity)
          |> html("<p>This host address is too long for compact camera pairing.</p>")

        {:error, :rate_limited} ->
          conn
          |> put_status(:too_many_requests)
          |> html("<p>Too many pairing codes were requested. Wait a moment and try again.</p>")

        _ ->
          conn
          |> put_status(:forbidden)
          |> html("<p>You are not allowed to pair this workspace.</p>")
      end
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

  defp compact_pairing_code(base, handle) do
    encoded =
      %{"v" => 1, "o" => base, "h" => handle}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    code = "casein://pair/" <> encoded

    if byte_size(code) <= @max_pairing_code_bytes,
      do: {:ok, code},
      else: {:error, :pairing_code_too_large}
  end

  defp refresh_in(expires_in) when is_integer(expires_in) do
    max(expires_in - @pairing_refresh_margin_seconds, 1)
  end

  defp page(workspace_id, base, code, qr_svg, expires_in, refresh_in) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <meta http-equiv="refresh" content="#{refresh_in}" />
      <title>Pair mobile companion — #{Plug.HTML.html_escape(workspace_id)}</title>
      <style>
        body { font-family: system-ui, sans-serif; background:#0f1115; color:#e6e6e6;
               margin:0; display:flex; min-height:100vh; align-items:center; justify-content:center; }
        .card { background:#181b22; border:1px solid #262b35; border-radius:12px;
                padding:28px 32px; max-width:480px; text-align:center; }
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
        <div class="field"><label>Compact pairing code</label><code>#{Plug.HTML.html_escape(code)}</code></div>
        <p class="hint">In the Casein app, open <strong>Sessions → Pair</strong> and scan this code,
        or paste the pairing code above. It expires in #{expires_in} seconds and works once.
        This page replaces it automatically before it expires.
        The device will join this workspace's live session feed.</p>
      </div>
    </body>
    </html>
    """
  end
end

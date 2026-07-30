defmodule CaseinWeb.Plugs.NormalizeLegacyTmuxSession do
  @moduledoc """
  Rewrites pre-rename `devide_`-prefixed `tmux_session` params to the canonical
  `casein_` name.

  Agent MCP configs bake the tmux session name into their endpoint URL at launch
  and never re-read it. The DevIDE→Casein rename renamed every live tmux session
  `devide_* -> casein_*`, so an agent started before the rename keeps sending a
  session name that no longer resolves — its terminal and preview tool calls fail
  `invalid_tmux_session_scope` even though the session is alive under its new
  name.

  This plug runs ahead of `AgentCapabilityAuthz`, `McpRateLimit`, and every
  workspace scope check, so the rest of the stack only ever sees canonical names
  and needs no legacy handling of its own. Capability claims are deliberately
  *not* normalized: a pre-rename claim naming a `devide_` session now fails the
  session-match check, which fails closed.

  The rewrite is conservative — it applies only when the legacy session does not
  exist and its canonical twin does — so it can never point a request at a
  different live session than the one it named.

  Delete this plug once no pre-rename agent processes remain.
  """

  import Plug.Conn

  alias Casein.Terminals

  @legacy_prefix "devide_"
  @canonical_prefix "casein_"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case conn.query_params["tmux_session"] do
      @legacy_prefix <> rest when rest != "" ->
        maybe_rewrite(conn, @legacy_prefix <> rest, @canonical_prefix <> rest)

      _ ->
        conn
    end
  end

  defp maybe_rewrite(conn, legacy, canonical) do
    if session_exists?(canonical) and not session_exists?(legacy) do
      conn
      |> put_param(:query_params, canonical)
      |> put_param(:params, canonical)
    else
      conn
    end
  end

  defp put_param(conn, key, value) do
    case Map.get(conn, key) do
      %{"tmux_session" => _} = params ->
        Map.put(conn, key, Map.put(params, "tmux_session", value))

      _ ->
        conn
    end
  end

  # A backend that cannot answer (tmux down, adapter raising) must not turn a
  # legacy name into a canonical one on a guess — treat it as "exists" so the
  # conservative check below fails and the request passes through untouched.
  defp session_exists?(session) do
    Terminals.backend().session_exists?(session)
  rescue
    _ -> true
  catch
    _, _ -> true
  end
end

defmodule Casein.Terminals.TmuxPolicy do
  @moduledoc """
  Casein-specific tmux session naming and sanitization rules.
  """

  @session_prefix "casein"

  @doc """
  Build a managed tmux session name for a workspace and session id.
  """
  @spec session_name(String.t(), String.t()) :: String.t()
  def session_name(workspace_name, sid) do
    "#{@session_prefix}_#{sanitize(workspace_name)}_#{sanitize_sid(sid)}"
  end

  @doc """
  Prefix shared by every Casein tmux session for a workspace name or id.

  Used to scope agent terminal MCP tools to one workspace.
  """
  @spec workspace_session_prefix(String.t()) :: String.t()
  def workspace_session_prefix(workspace_name) do
    session_name(workspace_name, "")
  end

  @doc """
  True when `session` belongs to the namespace identified by `prefix`.

  Plain `String.starts_with?/2` is **not** a safe workspace boundary: session
  names are `casein_<name>_<sid>` and `_` is legal inside a sanitized workspace
  name, so `casein_acme_` is a genuine prefix of workspace `acme_prod`'s session
  `casein_acme_prod_1`. A token scoped to `acme` would match `acme_prod`.

  The session id segment is underscore-free by construction (`sanitize_sid/1`),
  so the boundary is exact: after stripping `prefix`, what remains must be a
  single non-empty underscore-free segment. `casein_acme_prod_1` leaves
  `prod_1` for prefix `casein_acme_` and is rejected, while prefix
  `casein_acme_prod_` leaves `1` and is accepted.

  Fails closed — an unrecognised shape is rejected, never admitted.
  """
  @spec session_in_namespace?(term(), term()) :: boolean()
  def session_in_namespace?(session, prefix) when is_binary(session) and is_binary(prefix) do
    if String.starts_with?(session, prefix) do
      session
      |> binary_part(byte_size(prefix), byte_size(session) - byte_size(prefix))
      |> sid_segment?()
    else
      false
    end
  end

  def session_in_namespace?(_session, _prefix), do: false

  defp sid_segment?(""), do: false
  defp sid_segment?(sid), do: not String.contains?(sid, "_")

  @doc """
  Sanitize user-provided segments for tmux session names.
  """
  @spec sanitize(term()) :: String.t()
  def sanitize(s) do
    s
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "_")
    |> String.slice(0, 64)
  end

  @doc """
  Sanitize a session id segment.

  Same rules as `sanitize/1`, except `_` is also folded to `-` so the sid can
  never contain the separator. That makes `session_in_namespace?/2`'s parse
  unambiguous *by construction* rather than by assumption — without it, a
  workspace/user id that sanitized into an `_` would silently reintroduce the
  cross-workspace prefix collision this guards against.

  This is a no-op for every session id the app generates today (`wt-<uuid>`,
  `u-<user>-<tab>`, `art-<uuid>`, `main`), so it does not rename live sessions.
  """
  @spec sanitize_sid(term()) :: String.t()
  def sanitize_sid(s) do
    s
    |> sanitize()
    |> String.replace("_", "-")
  end
end

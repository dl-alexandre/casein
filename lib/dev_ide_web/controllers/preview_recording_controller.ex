defmodule DevIdeWeb.PreviewRecordingController do
  @moduledoc """
  Receives client-streamed screen recordings of a workspace preview.

  The browser records with `MediaRecorder` and POSTs the webm as ordered raw
  octet-stream chunks to `:chunk`, then calls `:finalize` to assemble and store
  the file. Like `PreviewArtifactController`, every request re-verifies the
  viewer owns the workspace — ForwardAuth establishes identity but not
  authorization.
  """
  use DevIdeWeb, :controller

  alias DevIDE.Previews.Recordings
  alias DevIDE.Workspaces

  # Per read_body call; the loop accumulates until the full chunk is read.
  @read_length 1_000_000

  def chunk(conn, %{"workspace_id" => workspace_id, "recording_id" => recording_id} = params) do
    with {:ok, _workspace} <- authorize(conn, workspace_id),
         {:ok, seq} <- parse_seq(params["seq"]),
         {:ok, body, conn} <- read_full_body(conn),
         :ok <- Recordings.append_chunk(workspace_id, recording_id, seq, body) do
      json(conn, %{ok: true, seq: seq})
    else
      :forbidden -> not_found(conn)
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def finalize(conn, %{"workspace_id" => workspace_id, "recording_id" => recording_id}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id),
         {:ok, ref} <- Recordings.finalize(workspace_id, recording_id) do
      json(conn, %{ok: true, recording_id: recording_id, url: ref})
    else
      :forbidden -> not_found(conn)
      {:error, reason} -> unprocessable(conn, reason)
    end
  end

  def abort(conn, %{"workspace_id" => workspace_id, "recording_id" => recording_id}) do
    with {:ok, _workspace} <- authorize(conn, workspace_id) do
      Recordings.cleanup(workspace_id, recording_id)
      json(conn, %{ok: true})
    else
      :forbidden -> not_found(conn)
    end
  end

  defp parse_seq(seq) when is_binary(seq) do
    case Integer.parse(seq) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_seq}
    end
  end

  defp parse_seq(_), do: {:error, :invalid_seq}

  # read_body returns one buffered slice per call; loop until the body is fully
  # drained so a chunk larger than @read_length still assembles intact.
  defp read_full_body(conn, acc \\ []) do
    case read_body(conn, length: @read_length) do
      {:ok, body, conn} -> {:ok, IO.iodata_to_binary([acc | [body]]), conn}
      {:more, partial, conn} -> read_full_body(conn, [acc | [partial]])
      {:error, reason} -> {:error, reason}
    end
  end

  defp not_found(conn), do: conn |> put_status(404) |> json(%{error: "not found"})

  defp unprocessable(conn, reason),
    do: conn |> put_status(422) |> json(%{error: reason_string(reason)})

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  # Mirrors PreviewArtifactController.authorize/2: 404 (never 403) so we don't
  # leak which workspace ids exist.
  defp authorize(conn, workspace_id) do
    viewer = conn.assigns[:current_user]
    auth = viewer && Map.get(viewer, :email)

    case Workspaces.get(workspace_id, auth) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, viewer || %{}),
          do: {:ok, workspace},
          else: :forbidden

      _ ->
        :forbidden
    end
  end
end

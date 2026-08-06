defmodule CaseinWeb.DesktopDownloadController do
  @moduledoc """
  Serves only the exact desktop binaries configured by the operator.

  `Casein.DesktopDownloads` has already verified the file against its
  configured SHA-256, so these actions stream from disk rather than re-reading
  and re-hashing the installer on every request.
  """

  use CaseinWeb, :controller

  def windows(conn, _params) do
    case Casein.DesktopDownloads.fetch(:windows) do
      {:ok, download} -> send_installer(conn, download)
      :error -> send_resp(conn, 404, "Not found")
    end
  end

  def windows_sha256(conn, _params) do
    case Casein.DesktopDownloads.fetch(:windows) do
      {:ok, download} ->
        conn
        |> put_resp_content_type("text/plain")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, "#{download.sha256}  #{download.filename}\n")

      :error ->
        send_resp(conn, 404, "Not found")
    end
  end

  # The path is absolute operator runtime configuration, never request input.
  # sobelow_skip ["Traversal.SendFile"]
  defp send_installer(conn, download) do
    conn =
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{download.filename}"))
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("etag", etag(download))

    case requested_range(conn, download) do
      :none ->
        send_file(conn, 200, download.path)

      {:range, first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{download.size}")
        |> send_file(206, download.path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{download.size}")
        |> send_resp(416, "")
    end
  end

  # The verified SHA-256 doubles as a strong validator: a resumed download that
  # spans two different builds is rejected rather than silently spliced.
  defp etag(download), do: ~s("#{download.sha256}")

  defp requested_range(conn, download) do
    with [range] <- get_req_header(conn, "range"),
         true <- if_range_matches?(conn, download) do
      parse_range(range, download.size)
    else
      _ -> :none
    end
  end

  defp if_range_matches?(conn, download) do
    case get_req_header(conn, "if-range") do
      [] -> true
      [validator] -> validator == etag(download)
      _ -> false
    end
  end

  # A malformed range is ignored (RFC 9110) and answered with the full body; a
  # well-formed range that cannot be met is answered 416.
  defp parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] -> suffix_range(suffix, size)
      [first, last] -> explicit_range(first, last, size)
      _ -> :none
    end
  end

  defp parse_range(_range, _size), do: :none

  # "bytes=-500" means the final 500 bytes.
  defp suffix_range(_text, 0), do: :unsatisfiable

  defp suffix_range(text, size) do
    case Integer.parse(text) do
      {0, ""} -> :unsatisfiable
      {count, ""} when count > 0 -> {:range, max(size - count, 0), size - 1}
      _ -> :none
    end
  end

  defp explicit_range(first_text, last_text, size) do
    with {first, ""} <- Integer.parse(first_text),
         true <- first >= 0,
         {:ok, last} <- requested_last(last_text, size),
         true <- last >= first do
      if first < size, do: {:range, first, min(last, size - 1)}, else: :unsatisfiable
    else
      _ -> :none
    end
  end

  defp requested_last("", size), do: {:ok, size - 1}

  defp requested_last(text, _size) do
    case Integer.parse(text) do
      {last, ""} when last >= 0 -> {:ok, last}
      _ -> :error
    end
  end
end

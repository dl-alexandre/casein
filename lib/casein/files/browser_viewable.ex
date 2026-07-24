defmodule Casein.Files.BrowserViewable do
  @moduledoc """
  Surface routing for opening a workspace path in a `:file` editor pane vs a
  `:preview` (browser) pane.

  Single source of truth for:
    * which file types render natively in a browser (`surface/1`)
    * the Content-Type the per-workspace static file server emits (`content_type/1`)
    * the Shift-flip pairing (`other/1`)
  """

  @preview_exts MapSet.new(~w(
    .html .htm .svg .pdf
    .png .jpg .jpeg .gif .webp .avif .bmp .ico
  ))

  @content_types %{
    ".html" => "text/html",
    ".htm" => "text/html",
    ".svg" => "image/svg+xml",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".avif" => "image/avif",
    ".bmp" => "image/bmp",
    ".ico" => "image/x-icon"
  }

  @doc """
  Best default surface for a workspace-relative path.

  Returns `:preview` for HTML, SVG, PDF, and raster images; `:file` otherwise.
  """
  @spec surface(String.t()) :: :file | :preview
  def surface(path) when is_binary(path) do
    if MapSet.member?(@preview_exts, ext(path)), do: :preview, else: :file
  end

  def surface(_), do: :file

  @doc """
  Real MIME type for the static file server to emit, or
  `application/octet-stream` when unknown.
  """
  @spec content_type(String.t()) :: String.t()
  def content_type(path) when is_binary(path) do
    Map.get(@content_types, ext(path), "application/octet-stream")
  end

  def content_type(_), do: "application/octet-stream"

  @doc "Flip surface for the Cmd/Ctrl+Shift gesture."
  @spec other(:file | :preview) :: :file | :preview
  def other(:file), do: :preview
  def other(:preview), do: :file

  defp ext(path), do: path |> Path.extname() |> String.downcase()
end

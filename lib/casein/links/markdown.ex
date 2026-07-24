defmodule Casein.Links.Markdown do
  @moduledoc """
  Renders workspace Markdown for the file viewer.

  Markdown is parsed to an MDEx document first so link and image destinations
  can be resolved through `Casein.Links.Resolver` before HTML is emitted. The
  final HTML is sanitized and is intended to be inserted by the file-viewer JS
  hook.
  """

  alias Casein.Links.Resolver
  alias Casein.Links.Resolver.Ctx

  @markdown_exts [".md", ".markdown"]
  @extension_options [
    autolink: true,
    strikethrough: true,
    table: true,
    tasklist: true
  ]
  @render_options [unsafe: false]

  @doc "True when `path` is a Markdown source file the viewer can render."
  @spec markdown_path?(String.t() | nil) :: boolean()
  def markdown_path?(path) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @markdown_exts
  end

  def markdown_path?(_), do: false

  @doc """
  Render Markdown to sanitized HTML, rewriting verified workspace-relative file
  URLs to the authenticated workspace file route.
  """
  @spec render_html(String.t(), Ctx.t()) :: {:ok, String.t()} | {:error, term()}
  def render_html(markdown, %Ctx{} = ctx) when is_binary(markdown) do
    with {:ok, document} <- MDEx.parse_document(markdown, extension: @extension_options) do
      document
      |> rewrite_document_urls(ctx)
      |> MDEx.to_html(
        render: @render_options,
        sanitize: MDEx.Document.default_sanitize_options()
      )
    end
  rescue
    error -> {:error, error}
  end

  def render_html(_, %Ctx{}), do: {:error, :invalid_markdown}

  @doc "Build the browser-authenticated file URL for a workspace-relative path."
  @spec file_url(map(), String.t(), String.t() | nil) :: String.t()
  def file_url(workspace, rel_path, fragment \\ nil) do
    path =
      rel_path
      |> Path.split()
      |> Enum.reject(&(&1 in ["", "."]))
      |> Enum.map_join("/", &encode_path_segment/1)

    url = "/api/workspaces/#{workspace_id(workspace)}/files/#{path}"

    if is_binary(fragment) and fragment != "" do
      url <> "#" <> URI.encode(fragment, &URI.char_unreserved?/1)
    else
      url
    end
  end

  defp rewrite_document_urls(%MDEx.Link{} = link, ctx) do
    %{link | url: rewrite_url(link.url, ctx), nodes: rewrite_child_nodes(link.nodes, ctx)}
  end

  defp rewrite_document_urls(%MDEx.Image{} = image, ctx) do
    %{image | url: rewrite_url(image.url, ctx), nodes: rewrite_child_nodes(image.nodes, ctx)}
  end

  defp rewrite_document_urls(%{nodes: nodes} = node, ctx) when is_list(nodes) do
    %{node | nodes: rewrite_child_nodes(nodes, ctx)}
  end

  defp rewrite_document_urls(node, _ctx), do: node

  defp rewrite_child_nodes(nodes, ctx), do: Enum.map(nodes, &rewrite_document_urls(&1, ctx))

  defp rewrite_url("#" <> _ = anchor, _ctx), do: anchor
  defp rewrite_url("", _ctx), do: ""

  defp rewrite_url(url, %Ctx{} = ctx) when is_binary(url) do
    case Resolver.resolve(url, ctx) do
      {:ok, {:file, %{path: path}}} ->
        file_url(ctx.workspace, path)

      {:ok, {:markdown, %{path: path, anchor: anchor}}} ->
        file_url(ctx.workspace, path, anchor)

      {:ok, {:external, %{url: resolved}}} ->
        resolved

      {:ok, {:localhost, %{url: resolved}}} ->
        resolved

      _ ->
        url
    end
  end

  defp rewrite_url(url, _ctx), do: url

  defp workspace_id(%{id: id}) when is_binary(id), do: encode_path_segment(id)
  defp workspace_id(%{"id" => id}) when is_binary(id), do: encode_path_segment(id)

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end

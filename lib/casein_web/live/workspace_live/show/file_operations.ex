defmodule CaseinWeb.WorkspaceLive.Show.FileOperations do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  require Phoenix.LiveView

  alias Casein.Elixir, as: ElixirNav
  alias Casein.Files
  alias Casein.Links.Markdown
  alias Casein.Links.Resolver.Ctx
  alias Casein.Workspaces.FileAccess
  alias CaseinWeb.WorkspaceLive.Show.Context

  def open_annotation_file(socket, loc, path, line) do
    case FileAccess.read_text(loc, path) do
      {:ok, file} ->
        mode = annotation_render_mode(socket, file)
        payload = annotation_file_payload(socket, loc, file, mode)
        payload = if line, do: Map.put(payload, :line, line), else: payload

        socket
        |> assign(:tab, "files")
        |> assign_open_file(file)
        |> assign(:file_render_mode, mode)
        |> assign(:file_error, nil)
        |> assign(:save_error, nil)
        |> load_diff(file.path)
        |> Phoenix.LiveView.push_event("file:loaded", payload)

      {:error, reason} ->
        assign(socket, :file_error, Context.format_file_error(reason))
    end
  end

  def assign_open_file(socket, nil) do
    socket
    |> assign(:open_file, nil)
    |> assign(:file_symbols, [])
  end

  def assign_open_file(socket, %{path: path, content: content} = file)
      when is_binary(path) and is_binary(content) do
    socket
    |> assign(:open_file, file)
    |> assign(:file_symbols, ElixirNav.symbols(content, path))
  end

  def assign_open_file(socket, file) when is_map(file) do
    socket
    |> assign(:open_file, file)
    |> assign(:file_symbols, [])
  end

  def load_tree(socket, path) do
    show_hidden? = show_hidden_files?(socket)

    case socket.assigns[:host_loc] do
      {:ok, {:remote, _host, _root} = loc} ->
        case FileAccess.ls(loc, path) do
          {:ok, raw_entries} ->
            entries =
              raw_entries
              |> Enum.map(&remote_entry_to_files_shape(&1, path))
              |> reject_hidden_entries(show_hidden?)

            assign(socket, :tree, Map.put(socket.assigns.tree, path, {:expanded, entries}))

          _ ->
            socket
        end

      _ ->
        with {:ok, root} <- Context.context_host_path(socket),
             {:ok, entries} <- Files.list(root, path, show_hidden: show_hidden?) do
          assign(socket, :tree, Map.put(socket.assigns.tree, path, {:expanded, entries}))
        else
          _ -> socket
        end
    end
  end

  def refresh_git_status(socket) do
    case Context.context_host_loc(socket) do
      {:ok, loc} ->
        socket
        |> assign(:git_status_ready?, false)
        |> Phoenix.LiveView.start_async(:refresh_git_status, fn ->
          git_status({:ok, loc})
        end)

      _ ->
        socket
        |> assign(:git_status, [])
        |> assign(:git_status_ready?, true)
    end
  end

  def git_status({:ok, loc}) do
    case FileAccess.git_status_short(loc) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  def git_status(_), do: []

  def root_tree(tree, host_loc, host_path, opts \\ [])

  def root_tree(tree, {:ok, {:remote, _host, _root} = loc}, _host_path, opts) do
    show_hidden? = Keyword.get(opts, :show_hidden, true)

    case FileAccess.ls(loc, "") do
      {:ok, raw_entries} ->
        entries =
          raw_entries
          |> Enum.map(&remote_entry_to_files_shape(&1, ""))
          |> reject_hidden_entries(show_hidden?)

        Map.put(tree, "", {:expanded, entries})

      _ ->
        tree
    end
  end

  def root_tree(tree, _host_loc, {:ok, root}, opts) do
    show_hidden? = Keyword.get(opts, :show_hidden, true)

    case Files.list(root, "", show_hidden: show_hidden?) do
      {:ok, entries} -> Map.put(tree, "", {:expanded, entries})
      _ -> tree
    end
  end

  def root_tree(tree, _host_loc, _host_path, _opts), do: tree

  def do_create(:file, root, rel) do
    case Files.create_file(root, rel) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  def do_create(:dir, root, rel), do: Files.create_dir(root, rel)

  def refresh_tree(socket) do
    expanded =
      socket.assigns.tree
      |> Enum.filter(fn {_, {state, _}} -> state == :expanded end)
      |> Enum.map(fn {path, _} -> path end)

    Enum.reduce(expanded, assign(socket, :tree, %{}), fn path, acc ->
      load_tree(acc, path)
    end)
  end

  def load_diff(socket, path) do
    case Context.context_host_loc(socket) do
      {:ok, loc} ->
        case FileAccess.git_diff(loc, path) do
          {:ok, ""} -> assign(socket, :file_diff, nil)
          {:ok, diff} -> assign(socket, :file_diff, diff)
          _ -> assign(socket, :file_diff, nil)
        end

      _ ->
        assign(socket, :file_diff, nil)
    end
  end

  defp annotation_file_payload(socket, loc, file, mode) do
    payload = %{
      path: file.path,
      content: file.content,
      version: file.version,
      markdown: Markdown.markdown_path?(file.path),
      render_mode: mode
    }

    if Markdown.markdown_path?(file.path) do
      Map.put(payload, :rendered_html, annotation_rendered_html(socket, loc, file))
    else
      payload
    end
  end

  defp annotation_render_mode(socket, file) do
    case socket.assigns[:file_render_mode] do
      "rendered" -> if(Markdown.markdown_path?(file.path), do: "rendered", else: "source")
      "source" -> "source"
      _ -> if(Markdown.markdown_path?(file.path), do: "rendered", else: "source")
    end
  end

  defp annotation_rendered_html(socket, loc, file) do
    ctx = %Ctx{
      workspace: socket.assigns.workspace,
      base_dir: annotation_markdown_base_dir(loc, file.path),
      source: :doc
    }

    case Markdown.render_html(file.content, ctx) do
      {:ok, html} -> html
      {:error, _reason} -> ~s(<p class="casein-markdown-error">Markdown render failed.</p>)
    end
  end

  defp annotation_markdown_base_dir(loc, rel_path) do
    root =
      case loc do
        {:local, root} -> root
        {:remote, _host, root} -> root
      end

    case Path.dirname(rel_path) do
      "." -> root
      dir -> Path.join(root, dir)
    end
  end

  defp remote_entry_to_files_shape(%{name: name, dir?: dir?, size: size}, parent) do
    %Casein.Files.Entry{
      name: name,
      rel_path: Path.join(parent, name),
      kind: if(dir?, do: :dir, else: :file),
      size: size,
      mtime: nil
    }
  end

  defp show_hidden_files?(socket), do: Map.get(socket.assigns, :show_hidden_files, true) != false

  defp reject_hidden_entries(entries, true), do: entries

  defp reject_hidden_entries(entries, false) do
    Enum.reject(entries, fn
      %{name: name} when is_binary(name) -> Files.hidden_name?(name)
      _ -> false
    end)
  end
end

defmodule DevIdeWeb.WorkspaceLive.Show.FileEvents do
  # File-tree / editor handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change). Show
  # delegates "tree:*" and "file:*" events here. Cross-cutting helpers come from
  # Show.Context (gate/policy_ctx/host_*/format_file_error); tree/diff/git
  # helpers that drive Show's async callbacks (handle_async lives in Show) stay
  # in Show and are called via Show.* — load_tree, do_create, refresh_tree,
  # refresh_git_status, load_diff.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView
  import DevIdeWeb.WorkspaceLive.Show.Context

  alias DevIDE.Files
  alias DevIDE.Policy
  alias DevIDE.Workspaces.FileAccess
  alias DevIdeWeb.WorkspaceLive.Show

  def handle_event("tree:toggle", %{"path" => path}, socket) do
    case Map.get(socket.assigns.tree, path) do
      {:expanded, _} ->
        {:noreply, update(socket, :tree, &Map.put(&1, path, {:collapsed, []}))}

      _ ->
        {:noreply, Show.load_tree(socket, path)}
    end
  end

  def handle_event("tree:select_dir", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_dir, path)}
  end

  def handle_event("tree:new_form", %{"kind" => kind}, socket) when kind in ["file", "dir"] do
    {:noreply,
     assign(socket, :new_input, {String.to_existing_atom(kind), socket.assigns.selected_dir})}
  end

  def handle_event("tree:cancel_new", _, socket), do: {:noreply, assign(socket, :new_input, nil)}

  def handle_event("tree:create", %{"name" => name}, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.create",
        target_type: "tree_node",
        target_ref: String.trim(name)
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {kind, dir} when kind in [:file, :dir] <- socket.assigns.new_input,
         {:ok, root} <- context_host_path(socket),
         rel = Path.join(dir, String.trim(name)),
         :ok <- Show.do_create(kind, root, rel) do
      {:noreply,
       socket
       |> assign(:new_input, nil)
       |> assign(:tree_error, nil)
       |> Show.refresh_tree()
       |> Show.refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :tree_error, "Create failed: #{inspect(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:refresh", _, socket) do
    {:noreply, socket |> Show.refresh_tree() |> Show.refresh_git_status()}
  end

  # Context-menu entry point: select the target dir and open the new-file/dir
  # input in one event (the header buttons do this as two clicks).
  def handle_event("tree:new_form_at", %{"dir" => dir, "kind" => kind}, socket)
      when is_binary(dir) and kind in ["file", "dir"] do
    {:noreply,
     socket
     |> assign(:selected_dir, dir)
     |> assign(:new_input, {String.to_existing_atom(kind), dir})}
  end

  def handle_event("tree:rename_form_node", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, assign(socket, :node_rename, path)}
  end

  def handle_event("tree:rename_node_cancel", _, socket),
    do: {:noreply, assign(socket, :node_rename, nil)}

  def handle_event("tree:rename_node", %{"to" => to}, socket) do
    to = String.trim(to)

    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.renamed",
        target_type: "tree_node",
        target_ref: to
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         from when is_binary(from) <- socket.assigns.node_rename,
         {:ok, root} <- context_host_path(socket),
         :ok <- Files.rename(root, from, to) do
      {:noreply,
       socket
       |> assign(:node_rename, nil)
       |> assign(:tree_error, nil)
       |> repoint_open_file(from, to, root)
       |> Show.refresh_tree()
       |> Show.refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :tree_error, "Rename failed: #{format_file_error(reason)}")}

      _ ->
        {:noreply, assign(socket, :node_rename, nil)}
    end
  end

  def handle_event("tree:delete_node_request", %{"path" => path}, socket)
      when is_binary(path) do
    {:noreply, assign(socket, :node_delete, path)}
  end

  def handle_event("tree:delete_node_cancel", _, socket),
    do: {:noreply, assign(socket, :node_delete, nil)}

  def handle_event("tree:delete_node_confirm", _, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.deleted",
        target_type: "tree_node",
        target_ref: socket.assigns.node_delete
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         rel when is_binary(rel) <- socket.assigns.node_delete,
         {:ok, root} <- context_host_path(socket),
         :ok <- Files.delete(root, rel, recursive: true) do
      {:noreply,
       socket
       |> assign(:node_delete, nil)
       |> assign(:tree_error, nil)
       |> clear_open_file_under(rel)
       |> Show.refresh_tree()
       |> Show.refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:tree_error, "Delete failed: #{format_file_error(reason)}")
         |> assign(:node_delete, nil)}

      _ ->
        {:noreply, assign(socket, :node_delete, nil)}
    end
  end

  def handle_event("tree:duplicate", %{"path" => path}, socket) when is_binary(path) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.create",
        target_type: "tree_node",
        target_ref: path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- context_host_path(socket),
         {:ok, _dest} <- duplicate_node(root, path) do
      {:noreply,
       socket
       |> assign(:tree_error, nil)
       |> Show.refresh_tree()
       |> Show.refresh_git_status()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :tree_error, "Duplicate failed: #{format_file_error(reason)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("file:rename_form", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :rename_input, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:rename_cancel", _, socket),
    do: {:noreply, assign(socket, :rename_input, nil)}

  def handle_event("file:rename_submit", %{"new_path" => new_path}, socket) do
    new_path = String.trim(new_path)

    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.renamed",
        target_type: "file",
        target_ref: new_path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, root} <- context_host_path(socket),
         %{path: from} = _open <- socket.assigns.open_file,
         :ok <- Files.rename(root, from, new_path) do
      case Files.read_text(root, new_path) do
        {:ok, file} ->
          {:noreply,
           socket
           |> assign(:open_file, file)
           |> assign(:rename_input, nil)
           |> Show.refresh_tree()
           |> Show.refresh_git_status()
           |> push_event("file:loaded", %{
             path: file.path,
             content: file.content,
             version: file.version
           })}

        _ ->
          {:noreply,
           socket
           |> assign(:open_file, nil)
           |> assign(:rename_input, nil)
           |> Show.refresh_tree()
           |> push_event("file:cleared", %{})}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("file:delete_request", _, socket) do
    case socket.assigns.open_file do
      %{path: path} -> {:noreply, assign(socket, :delete_confirm, path)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("file:delete_cancel", _, socket),
    do: {:noreply, assign(socket, :delete_confirm, nil)}

  def handle_event("file:delete_confirm", _, socket) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.deleted",
        target_type: "file",
        target_ref: socket.assigns.delete_confirm
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         rel when is_binary(rel) <- socket.assigns.delete_confirm,
         {:ok, root} <- context_host_path(socket),
         :ok <- Files.delete(root, rel) do
      {:noreply,
       socket
       |> assign(:open_file, nil)
       |> assign(:delete_confirm, nil)
       |> assign(:file_diff, nil)
       |> Show.refresh_tree()
       |> Show.refresh_git_status()
       |> push_event("file:cleared", %{})}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:save_error, "Delete failed: #{inspect(reason)}")
         |> assign(:delete_confirm, nil)}

      _ ->
        {:noreply, assign(socket, :delete_confirm, nil)}
    end
  end

  def handle_event("file:refresh", _, socket) do
    case {socket.assigns.open_file, context_host_path(socket)} do
      {%{path: path}, {:ok, root}} ->
        case Files.read_text(root, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("tree:open", %{"path" => path}, socket) do
    case context_host_loc(socket) do
      {:ok, loc} ->
        case FileAccess.read_text(loc, path) do
          {:ok, file} ->
            {:noreply,
             socket
             |> assign(:open_file, file)
             |> assign(:file_error, nil)
             |> assign(:save_error, nil)
             |> Show.load_diff(file.path)
             |> push_event("file:loaded", %{
               path: file.path,
               content: file.content,
               version: file.version
             })}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:open_file, nil)
             |> assign(:file_error, format_file_error(reason))
             |> assign(:file_diff, nil)
             |> push_event("file:cleared", %{})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "file:save",
        %{"path" => path, "content" => content, "version" => version},
        socket
      ) do
    {decision, socket} =
      gate(socket, fn -> Policy.can_edit_file?(policy_ctx(socket)) end, %{
        action: "file.save",
        target_type: "file",
        target_ref: path
      })

    with true <- DevIDE.Policy.Decision.allow?(decision),
         {:ok, loc} <- context_host_loc(socket),
         %{path: ^path, version: ^version} = open <- socket.assigns.open_file,
         {:ok, %{version: new_version}} <-
           FileAccess.write_text(loc, path, content, open.version) do
      updated = %{open | content: content, size: byte_size(content), version: new_version}

      {:noreply,
       socket
       |> assign(:open_file, updated)
       |> assign(:save_error, nil)
       |> Show.refresh_git_status()
       |> Show.load_diff(path)
       |> push_event("save:ok", %{version: new_version})}
    else
      {:error, :conflict} ->
        {:noreply,
         assign(socket, :save_error, "Conflict: file changed on disk. Reopen to reload.")}

      {:error, reason} ->
        {:noreply, assign(socket, :save_error, format_file_error(reason))}

      _ ->
        {:noreply, assign(socket, :save_error, "Save aborted: open file changed.")}
    end
  end

  # After a tree-node rename, follow the open file to its new path — whether
  # the renamed node was the file itself or an ancestor directory.
  defp repoint_open_file(socket, from, to, root) do
    case socket.assigns.open_file do
      %{path: ^from} ->
        reload_open_file(socket, root, to)

      %{path: p} ->
        if String.starts_with?(p, from <> "/") do
          reload_open_file(
            socket,
            root,
            to <> binary_part(p, byte_size(from), byte_size(p) - byte_size(from))
          )
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp reload_open_file(socket, root, path) do
    case Files.read_text(root, path) do
      {:ok, file} ->
        socket
        |> assign(:open_file, file)
        |> push_event("file:loaded", %{
          path: file.path,
          content: file.content,
          version: file.version
        })

      _ ->
        socket
        |> assign(:open_file, nil)
        |> push_event("file:cleared", %{})
    end
  end

  defp clear_open_file_under(socket, rel) do
    under? = fn p -> is_binary(p) and (p == rel or String.starts_with?(p, rel <> "/")) end

    socket =
      case socket.assigns.open_file do
        %{path: p} ->
          if under?.(p) do
            socket
            |> assign(:open_file, nil)
            |> assign(:file_diff, nil)
            |> push_event("file:cleared", %{})
          else
            socket
          end

        _ ->
          socket
      end

    if under?.(socket.assigns.selected_dir),
      do: assign(socket, :selected_dir, ""),
      else: socket
  end

  @duplicate_attempts 20

  defp duplicate_node(root, rel) do
    Enum.reduce_while(1..@duplicate_attempts, {:error, :exists}, fn n, _acc ->
      dest = duplicate_dest(rel, n)

      case Files.copy(root, rel, dest) do
        :ok -> {:halt, {:ok, dest}}
        {:error, :exists} -> {:cont, {:error, :exists}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp duplicate_dest(rel, n) do
    ext = Path.extname(rel)
    base = Path.basename(rel, ext)
    suffix = if n == 1, do: " copy", else: " copy #{n}"
    name = base <> suffix <> ext

    case Path.dirname(rel) do
      "." -> name
      dir -> Path.join(dir, name)
    end
  end
end

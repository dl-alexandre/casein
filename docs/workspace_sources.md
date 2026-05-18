# Implementing a WorkspaceSource

`DevIDE.WorkspaceSource` is the pluggable backend responsible for workspace discovery and lifecycle.

## Core Idea

- The public `%DevIDE.Workspace{}` struct is source-agnostic.
- All source-specific details (HTTP payloads, ports, special paths, auth quirks) live in `metadata`.
- Generic code (LiveViews, commands, terminals, agents, policy) talks to `DevIDE.Workspaces` (the facade) or calls `DevIDE.WorkspaceSource.*` helper functions.

## The Behaviour

Implement the callbacks in `DevIDE.WorkspaceSource`:

- `list/2`, `get/2`, `create/2`, `start/2`, `stop/2`, `delete/3`, `stream_logs/3`
- `safe_host_path/1`, `safe_host_loc/1`
- Optional: `prepare_local_argv/1`, `local_tmux_pane_shell/0`, `default_log_service/1`, `detect_capabilities/2` (future)

## Recommended Structure

```
lib/my_app/workspace_source/
  my_source.ex          # the behaviour implementation
  my_workspace.ex       # internal normalized shape (if complex)
```

Register it via config:

```elixir
config :dev_ide, :workspace_source, MyApp.WorkspaceSource.MySource
```

## Example: Minimal Read-Only Source

```elixir
defmodule MyApp.WorkspaceSource.Static do
  @behaviour DevIDE.WorkspaceSource

  alias DevIDE.Workspace

  @impl true
  def list(_opts, _auth), do: {:ok, [build("demo", "/tmp/demo")]}

  @impl true
  def get("demo", _auth), do: {:ok, build("demo", "/tmp/demo")}
  def get(_, _), do: {:error, :not_found}

  # All mutations not supported
  def create(_, _), do: {:error, :not_supported}
  # ... other lifecycle callbacks return {:error, :not_supported}

  defp build(id, path) do
    %Workspace{id: id, name: id, path: path, status: :running, metadata: %{}}
  end
end
```

## Best Practices

1. **Never leak source concepts** into public modules (`lib/dev_ide/` outside `integrations/`).
2. Put rich data in `metadata`. Generic code should only read well-known keys (see "Metadata Contract" in architecture docs).
3. Use the optional callbacks (`prepare_local_argv`, `default_log_service`, etc.) instead of adding `if source == X` branches in generic code.
4. Keep heavy dependencies (HTTP clients, special auth, etc.) inside your integration directory.

## Testing

- Test your source in isolation.
- Add a small conformance test that exercises the public facade with your source selected.

For the reference MILC implementation, see `lib/dev_ide/integrations/manager/`.

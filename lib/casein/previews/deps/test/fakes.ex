defmodule Casein.Previews.Deps.Test.Fakes do
  @moduledoc """
  In-memory fakes for preview-domain outbound seams.

  Optional unit-test helpers (prior art: `TmuxCtl.Test.FakeEventSource`,
  `PreviewCtl.Test.FakeAdapter`). Production and the main suite resolve real
  core impls via config.
  """

  defmodule Workspaces do
    @moduledoc false
    @behaviour Casein.Previews.Deps.Workspaces

    @impl true
    def get(_id), do: {:error, :not_found}

    @impl true
    def attach_folder(_path), do: {:error, :not_a_directory}

    @impl true
    def safe_host_path(_workspace), do: {:error, :not_found}

    @impl true
    def safe_host_loc(_workspace), do: {:error, :not_found}

    @impl true
    def forward_auth_headers(_workspace), do: nil

    @impl true
    def viewer_ids(workspace_id) when is_binary(workspace_id), do: [workspace_id]
    def viewer_ids(_), do: []

    @impl true
    def viewer_ids(workspace_id, _opts) when is_binary(workspace_id), do: [workspace_id]
    def viewer_ids(_, _), do: []

    @impl true
    def linked?(left, right), do: left == right

    @impl true
    def viewer_route_id(workspace_id) when is_binary(workspace_id),
      do: "/workspaces/" <> workspace_id

    def viewer_route_id(_), do: "/workspaces"
  end

  defmodule Terminals do
    @moduledoc false
    @behaviour Casein.Previews.Deps.Terminals

    @impl true
    def list_sessions, do: []

    @impl true
    def list_session_panes(_session), do: []

    @impl true
    def capture_scrollback(_session, _opts), do: ""

    @impl true
    def workspace_session_prefix(name), do: "casein_" <> to_string(name) <> "_"

    @impl true
    def session_name(name, sid), do: workspace_session_prefix(name) <> to_string(sid)

    @impl true
    def topology_subscribe(_session), do: :ok

    @impl true
    def topology_refresh(_session), do: :ok

    @impl true
    def topology_get(_session, _opts), do: %{windows: [], panes: []}

    @impl true
    def kill_pane(_session, _pane_id), do: :ok

    @impl true
    def split_pane(_session, _pane_id, _direction, _opts), do: {:ok, "%fake"}

    @impl true
    def select_pane(_session, _pane_id), do: :ok

    @impl true
    def adapter, do: __MODULE__
  end

  defmodule Runtimes do
    @moduledoc false
    @behaviour Casein.Previews.Deps.Runtimes

    @impl true
    def list_runtimes(_filters), do: []

    @impl true
    def runtime_preview_surfaces(_runtime), do: []

    @impl true
    def runtime_preview_server(_runtime), do: nil

    @impl true
    def ensure_preview_server_started(_runtime), do: :ok
  end

  defmodule PaneSink do
    @moduledoc false
    @behaviour Casein.Previews.Deps.PaneSink

    @impl true
    def broadcast(_event), do: :ok
  end

  defmodule Urls do
    @moduledoc false
    @behaviour Casein.Previews.Deps.Urls

    @impl true
    def base_url, do: "http://127.0.0.1:4000"

    @impl true
    def api_base_url, do: "http://127.0.0.1:4000"

    @impl true
    def preview_url, do: "http://127.0.0.1:4000/api/preview/mcp"
  end
end

defmodule Casein.Workspaces.IdentityTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.Tmux
  alias Casein.Workspace
  alias Casein.Workspaces.Identity
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    on_exit(fn -> MemoryAdapter.clear() end)
  end

  test "kind distinguishes uuid, slug, folder, and missing" do
    assert Identity.kind("69ab354b-0157-4344-88db-40b751773eec") == :uuid
    assert Identity.kind("mbaldin-v3-design-c") == :slug
    assert Identity.kind("folder:L2RhdGEvd28") == :folder
    assert Identity.kind(nil) == :missing
    assert Identity.kind("") == :slug
  end

  test "resolve is missing for blank input" do
    assert Identity.resolve(nil) == {:error, :missing_workspace_id}
    assert Identity.resolve("  ") == {:error, :missing_workspace_id}
  end

  test "uuid and slug share prefixes once the workspace is persisted" do
    uuid = "69ab354b-0157-4344-88db-40b751773eec"
    slug = "mbaldin-v3-design-c"

    {:ok, _} =
      Casein.Workspaces.State.sync(%Workspace{
        id: uuid,
        name: slug,
        path: "/workspace",
        status: :running
      })

    assert {:ok, by_uuid} = Identity.resolve(uuid)
    assert {:ok, by_slug} = Identity.resolve(slug)

    assert by_uuid.kind == :uuid
    assert by_slug.kind == :slug
    assert by_uuid.id == uuid
    assert by_slug.id == uuid
    assert by_uuid.name == slug
    assert by_slug.name == slug
    assert Tmux.workspace_session_prefix(slug) in by_uuid.prefixes
    assert by_uuid.prefixes == by_slug.prefixes
  end

  test "unknown slug still prefixes from the raw argument" do
    assert {:ok, identity} = Identity.resolve("mbaldin-v3-design-c")
    assert identity.kind == :slug
    assert identity.prefixes == [Tmux.workspace_session_prefix("mbaldin-v3-design-c")]
  end

  test "session_workspace parses the casein_<ws>_<sid> name" do
    assert Identity.session_workspace(Tmux.session_name("mbaldin-v3-design-c", "wt-abc")) ==
             "mbaldin-v3-design-c"

    assert Identity.session_workspace("not-a-casein-session") == nil
  end

  test "mismatch names both resolved identities" do
    err = Identity.mismatch("alpha", Tmux.session_name("other", "u-dev"))

    assert err.error == :workspace_mismatch
    assert err.workspace.arg == "alpha"
    assert err.workspace.kind == :slug
    assert err.session.workspace == "other"
    assert err.session.name == Tmux.session_name("other", "u-dev")
  end

  test "resolve does not block on a hanging workspace source" do
    previous = Application.get_env(:casein, :workspace_source)
    Application.put_env(:casein, :workspace_source, __MODULE__.HangingSource)
    on_exit(fn -> restore_source(previous) end)

    start = System.monotonic_time(:millisecond)
    assert {:ok, %{kind: :slug}} = Identity.resolve("some-slug")
    assert {:ok, %{kind: :uuid}} = Identity.resolve("69ab354b-0157-4344-88db-40b751773eec")
    assert Identity.resolve(nil) == {:error, :missing_workspace_id}
    assert System.monotonic_time(:millisecond) - start < 5_000
  end

  defp restore_source(nil), do: Application.delete_env(:casein, :workspace_source)
  defp restore_source(value), do: Application.put_env(:casein, :workspace_source, value)
end

defmodule Casein.Workspaces.IdentityTest.HangingSource do
  @moduledoc false
  @behaviour Casein.WorkspaceSource

  @impl true
  def get(id, _auth \\ nil) do
    raise "WorkspaceSource.get/2 must not be called from Identity (id=#{inspect(id)})"
  end

  @impl true
  def list(_opts \\ [], _auth \\ nil), do: {:ok, []}

  @impl true
  def create(_params, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def start(_id, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def stop(_id, _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def delete(_id, _opts \\ [], _auth \\ nil), do: {:error, :unsupported}

  @impl true
  def stream_logs(_id, _service, _pid), do: {:error, :unsupported}

  @impl true
  def safe_host_path(_), do: {:error, :unsupported}

  @impl true
  def safe_host_loc(_), do: {:error, :unsupported}
end

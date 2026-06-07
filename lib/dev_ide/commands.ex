defmodule DevIDE.Commands do
  @moduledoc """
  Workspace command runner. Allowlisted, argv-style, no shell interpolation.

  M5 supports one in-flight run per workspace, exposed via
  `DevIDE.Commands.Run`. New adapters slot in via the
  `:dev_ide, :commands_adapter` config key.
  """

  alias DevIDE.Commands.Allowlist

  @type id :: String.t()
  @type argv :: [String.t()]

  @callback spawn(root :: String.t(), argv(), pid()) ::
              {:ok, reference(), term()} | {:error, term()}
  @callback kill(term()) :: :ok

  @doc "Map of allowlist id → argv. Stable for tests."
  def allowlist, do: Allowlist.all()
  def allowed?(id), do: Allowlist.allowed?(id)
  def argv_for(id), do: Allowlist.argv_for(id)

  def spawn({:remote, _host, _root} = loc, argv, subscriber),
    do: DevIDE.Commands.SshAdapter.spawn(loc, argv, subscriber)

  def spawn({:local, root}, argv, subscriber), do: local_spawn(root, argv, subscriber)
  def spawn(root, argv, subscriber) when is_binary(root), do: local_spawn(root, argv, subscriber)

  def kill(handle), do: impl().kill(handle)

  # The configured WorkspaceSource may wrap the argv (e.g. an integration
  # that runs commands inside a container). Defaults to identity.
  defp local_spawn(root, argv, subscriber) do
    impl().spawn(root, DevIDE.WorkspaceSource.prepare_local_argv(argv), subscriber)
  end

  defp impl, do: Application.get_env(:dev_ide, :commands_adapter, DevIDE.Commands.LocalAdapter)
end

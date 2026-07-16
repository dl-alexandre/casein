defmodule DevIDE.Agents.GrokCapabilityBundle do
  @moduledoc """
  Compiles Grok plugins into immutable, content-addressed capability bundles.

  The bundle contains no bearer token. Its MCP configuration references the
  managed-leader `DEV_IDE_API_TOKEN` capability, and Grok receives the absolute
  bundle path through ACP `_meta.pluginDirs` for one private leader only.
  """

  import Bitwise

  @manifest ~s({"description":"Session-scoped DevIDE tools, hooks, and skills","hooks":"./hooks/hooks.json","mcpServers":"./.mcp.json","name":"devide-grok-capabilities","skills":"./skills","version":"1.0.0"}\n)
  @digest_regex ~r/^sha256-([0-9a-f]{64})$/
  @skill_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/

  @type bundle :: %{dir: String.t(), digest: String.t()}

  @spec compile(keyword()) :: {:ok, bundle()} | {:error, term()}
  def compile(opts) when is_list(opts) do
    with {:ok, mcp_config} <- required_file(opts, :mcp_config),
         {:ok, root} <- ensure_root(Keyword.get(opts, :bundle_root, root())),
         {:ok, temp} <- make_temp(root) do
      populate_and_publish(temp, root, mcp_config, opts)
    end
  rescue
    error in [File.Error, ArgumentError] -> {:error, error}
  end

  @doc "Returns true only for a verified direct digest child of the configured bundle root."
  @spec allowed_path?(term()) :: boolean()
  def allowed_path?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Path.dirname(expanded) == Path.expand(root()) and
      match?([_, _], Regex.run(@digest_regex, Path.basename(expanded))) and
      verify(expanded) == :ok
  end

  def allowed_path?(_path), do: false

  @spec verify(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def verify(path, expected_digest \\ nil) when is_binary(path) do
    with {:ok, digest} <- named_digest(path),
         true <- is_nil(expected_digest) or expected_digest == digest,
         true <- File.dir?(path),
         :ok <- reject_symlinks_and_writes(path),
         ^digest <- digest(path) do
      :ok
    else
      false -> {:error, :bundle_digest_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :bundle_digest_mismatch}
    end
  end

  @spec root() :: String.t()
  def root do
    System.get_env("DEVIDE_GROK_BUNDLE_ROOT") ||
      Application.get_env(:dev_ide, :grok_capability_bundle_root) ||
      Path.join([home_dir(), ".devide", "grok-bundles"])
  end

  @spec leader_root() :: String.t()
  def leader_root do
    System.get_env("DEVIDE_GROK_LEADER_ROOT") ||
      Application.get_env(:dev_ide, :grok_leader_root) ||
      Path.join([home_dir(), ".devide", "grok-leaders"])
  end

  @spec leader_socket(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  # The only caller-controlled values are hashed into a fixed 24-hex filename;
  # the parent is an operator-configured root or a deterministic private fallback.
  # sobelow_skip ["Traversal.FileModule"]
  def leader_socket(workspace_id, checkout)
      when is_binary(workspace_id) and is_binary(checkout) do
    key = sha256(workspace_id <> <<0>> <> Path.expand(checkout)) |> binary_part(0, 24)
    root = Path.expand(leader_root())
    leader_dir = Path.join(root, key)
    path = Path.join(leader_dir, "leader.sock")

    {root, leader_dir, path} =
      if byte_size(path) <= 100,
        do: {root, leader_dir, path},
        else: short_leader_path(key)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         true <- private_directory?(root),
         :ok <- File.mkdir_p(leader_dir),
         :ok <- File.chmod(leader_dir, 0o700),
         true <- private_directory?(leader_dir) do
      {:ok, path}
    else
      false -> {:error, :unsafe_leader_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Recognizes leader.sock inside a private digest-keyed directory under a trusted root."
  def allowed_leader_socket?(path) when is_binary(path) do
    expanded = Path.expand(path)
    leader_dir = Path.dirname(expanded)
    root = Path.dirname(leader_dir)

    Path.basename(expanded) == "leader.sock" and
      Regex.match?(~r/^[0-9a-f]{24}$/, Path.basename(leader_dir)) and
      root in [Path.expand(leader_root()), short_leader_root()] and
      not symlink?(expanded) and
      private_directory?(root) and
      private_directory?(leader_dir)
  end

  def allowed_leader_socket?(_path), do: false

  # temp is created directly beneath the trusted bundle root, while every
  # destination below it is a fixed compiler-owned relative path.
  # sobelow_skip ["Traversal.FileModule"]
  defp populate_and_publish(temp, root, mcp_config, opts) do
    try do
      :ok = File.mkdir_p!(Path.join(temp, "hooks"))
      :ok = File.mkdir_p!(Path.join(temp, "skills"))
      :ok = File.write!(Path.join(temp, "plugin.json"), @manifest)
      :ok = File.cp!(mcp_config, Path.join(temp, ".mcp.json"))
      :ok = write_hooks(temp, opts)
      :ok = copy_skills(temp, opts)

      digest = digest(temp)
      target = Path.join(root, "sha256-" <> digest)
      :ok = make_read_only(temp)

      case File.rename(temp, target) do
        :ok -> :ok
        {:error, reason} when reason in [:eexist, :enotempty] -> verify(target, digest)
        {:error, reason} -> raise File.Error, reason: reason, action: "publish", path: target
      end

      if File.exists?(temp), do: remove_temp(temp)

      case verify(target, digest) do
        :ok -> {:ok, %{dir: target, digest: digest}}
        {:error, reason} -> {:error, reason}
      end
    rescue
      error ->
        remove_temp(temp)
        {:error, error}
    end
  end

  # Sources must pass required_file/2; destinations are fixed children of the
  # compiler-created temporary bundle directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_hooks(temp, opts) do
    destination = Path.join([temp, "hooks", "hooks.json"])

    if Keyword.get(opts, :hooks, true) do
      with {:ok, config} <- required_file(opts, :hook_config),
           {:ok, script} <- required_file(opts, :hook_script) do
        :ok = File.cp!(config, destination)
        script_destination = Path.join([temp, "hooks", "devide-agent-state.sh"])
        :ok = File.cp!(script, script_destination)
        File.chmod(script_destination, 0o755)
      end
    else
      File.write(destination, ~s({"hooks":{}}\n))
    end
  end

  defp copy_skills(temp, opts) do
    skills_root = Keyword.get(opts, :skills_root)

    opts
    |> Keyword.get(:skills, [])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case copy_skill(skills_root, name, Path.join(temp, "skills")) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Skill names reject separators/dot traversal, roots are internal compiler
  # inputs, and reject_skill_tree?/1 rejects nested symlinks and special files.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_skill(root, name, destination)
       when is_binary(root) and is_binary(name) do
    if Regex.match?(@skill_regex, name) do
      source = Path.join(root, name)

      cond do
        not File.dir?(source) or symlink?(source) ->
          {:error, {:invalid_skill_directory, name}}

        reject_skill_tree?(source) ->
          {:error, {:unsafe_skill_tree, name}}

        true ->
          File.cp_r!(source, Path.join(destination, name))
          :ok
      end
    else
      {:error, {:invalid_skill_name, name}}
    end
  end

  defp copy_skill(_root, name, _destination), do: {:error, {:invalid_skill_directory, name}}

  defp reject_skill_tree?(root) do
    case descendants(root) do
      {:ok, _entries} -> false
      {:error, _reason} -> true
    end
  end

  # root is the compiler-created temporary bundle; descendants/1 rejects
  # symlinks and unsupported entries before any chmod occurs.
  # sobelow_skip ["Traversal.FileModule"]
  defp make_read_only(root) do
    with {:ok, entries} <- descendants(root) do
      Enum.each(entries, fn path ->
        case File.stat!(path).type do
          :directory -> File.chmod!(path, 0o555)
          :regular -> File.chmod!(path, if(executable?(path), do: 0o555, else: 0o444))
        end
      end)

      File.chmod(root, 0o555)
    end
  end

  defp reject_symlinks_and_writes(root) do
    with false <- symlink?(root),
         {:ok, entries} <- descendants(root),
         true <- Enum.all?([root | entries], &(not symlink?(&1) and read_only?(&1))) do
      :ok
    else
      _ -> {:error, :bundle_not_immutable}
    end
  end

  defp descendants(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          path = Path.join(root, name)

          cond do
            symlink?(path) ->
              {:halt, {:error, :bundle_symlink}}

            File.dir?(path) ->
              case descendants(path) do
                {:ok, nested} -> {:cont, {:ok, [path | nested] ++ acc}}
                error -> {:halt, error}
              end

            File.regular?(path) ->
              {:cont, {:ok, [path | acc]}}

            true ->
              {:halt, {:error, :unsupported_bundle_entry}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # root is a verified/compiler-owned bundle and descendants/1 rejects
  # symlinks, so reads cannot escape the bundle tree.
  # sobelow_skip ["Traversal.FileModule"]
  defp digest(root) do
    {:ok, entries} = descendants(root)

    entries
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort_by(&Path.relative_to(&1, root))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, context ->
      relative = Path.relative_to(path, root)
      :crypto.hash_update(context, [relative, <<0>>, File.read!(path), <<0>>])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp named_digest(path) do
    case Regex.run(@digest_regex, Path.basename(Path.expand(path))) do
      [_, digest] -> {:ok, digest}
      _ -> {:error, :invalid_bundle_path}
    end
  end

  defp required_file(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) -> if File.regular?(path), do: {:ok, path}, else: {:error, key}
      _ -> {:error, key}
    end
  end

  # The root comes only from operator application/env configuration or an
  # internal materializer option, never from an HTTP/MCP parameter.
  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_root(root) do
    root = Path.expand(root)

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      {:ok, root}
    end
  end

  # root has passed ensure_root/1 and the child name is generated locally.
  # sobelow_skip ["Traversal.FileModule"]
  defp make_temp(root) do
    temp = Path.join(root, ".grok-bundle-#{System.unique_integer([:positive, :monotonic])}")

    case File.mkdir(temp) do
      :ok -> {:ok, temp}
      {:error, reason} -> {:error, reason}
    end
  end

  # path is only the locally generated child returned by make_temp/1; recursive
  # enumeration rejects symlinks before permissions or removal are attempted.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_temp(path) do
    if File.exists?(path) do
      _ = File.chmod(path, 0o700)

      case descendants(path) do
        {:ok, entries} ->
          Enum.each(entries, fn entry ->
            _ = File.chmod(entry, if(File.dir?(entry), do: 0o700, else: 0o600))
          end)

        _ ->
          :ok
      end

      File.rm_rf(path)
    end

    :ok
  end

  defp executable?(path), do: band(File.stat!(path).mode, 0o100) != 0
  defp read_only?(path), do: band(File.stat!(path).mode, 0o222) == 0

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp short_leader_path(key) do
    root = short_leader_root()
    leader_dir = Path.join(root, key)
    {root, leader_dir, Path.join(leader_dir, "leader.sock")}
  end

  defp short_leader_root do
    # Grok's built-in profiles grant the whole system temp directory write
    # access. A short fallback there would let one managed session alter its
    # siblings. /dev/shm stays short for Unix sockets but is writable only at
    # the exact per-leader directory added to DevIDE's custom profile.
    uid = current_uid()
    Path.join("/dev/shm", "devide-grok-leaders-#{uid}")
  end

  defp current_uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+([0-9]+)/m, status) do
      String.to_integer(uid)
    else
      _ -> File.stat!(home_dir()).uid
    end
  end

  defp private_directory?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} ->
        uid == current_uid() and band(mode, 0o077) == 0

      _other ->
        false
    end
  end

  defp home_dir do
    System.get_env("HOME") || System.get_env("USERPROFILE") ||
      raise ArgumentError, "HOME or USERPROFILE is required for Grok capability bundles"
  end
end

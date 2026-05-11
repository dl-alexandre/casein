defmodule DevIDE.Files do
  @moduledoc """
  Read/write file access for a workspace.

  All paths are user-supplied (file tree clicks, save events) and **must** be
  resolved via `DevIDE.Files.PathSafety` against the workspace root that comes
  from the manager (`ws.path`). The root itself is also re-checked against the
  configured `:workspaces_roots` allowlist via
  `DevIDE.Workspaces.safe_host_path/1`.

  Writes are version-checked against `DevIDE.Files.Version` and atomic via
  temp-file + rename in the same directory.
  """

  alias DevIDE.Files.{Entry, PathSafety, Version}

  @max_text_bytes 2 * 1024 * 1024

  @type list_error :: :not_a_directory | PathSafety.reason()
  @type read_error :: :too_large | :binary | :not_a_file | PathSafety.reason()
  @type write_error ::
          :conflict | :too_large | :binary | :not_a_file | PathSafety.reason() | term()

  @doc """
  List the immediate children of `root <> "/" <> rel`.

  Filters out ignored dirs/globs. Sorts dirs before files, both alphabetically.
  """
  @spec list(String.t(), String.t()) :: {:ok, [Entry.t()]} | {:error, list_error()}
  def list(root, rel \\ "") do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :directory}} <- File.stat(abs),
         {:ok, names} <- File.ls(abs) do
      entries =
        names
        |> Enum.reject(&PathSafety.ignored_dir?/1)
        |> Enum.reject(fn n -> PathSafety.ignored_path?(Path.join(rel, n)) end)
        |> Enum.flat_map(fn name -> stat_entry(abs, rel, name) end)
        |> Enum.sort_by(&{&1.kind != :dir, &1.name})

      {:ok, entries}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read a text file. Returns content and a version token. Refuses binary/large."
  @spec read_text(String.t(), String.t()) ::
          {:ok,
           %{
             path: String.t(),
             size: integer(),
             content: binary(),
             mtime: NaiveDateTime.t() | nil,
             version: Version.t()
           }}
          | {:error, read_error()}
  def read_text(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :regular, size: size, mtime: mtime} = stat}
         when size <= @max_text_bytes <- File.stat(abs),
         {:ok, content} <- File.read(abs),
         false <- PathSafety.likely_binary?(content) do
      {:ok,
       %{
         path: rel,
         size: byte_size(content),
         content: content,
         mtime: erl_to_naive(mtime),
         version: Version.compute(content, stat)
       }}
    else
      {:ok, %File.Stat{type: :regular}} -> {:error, :too_large}
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      true -> {:error, :binary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write `content` to `rel` only if the on-disk version still matches
  `expected_version`. Refuses binary content, oversized content,
  non-regular targets, traversal, and symlink escapes.

  Atomic: writes a sibling temp file and renames over the target. Preserves
  file mode.

  Returns `{:ok, %{version: new_version, size: size}}` on success or
  `{:error, reason}`. Reason is one of: `:conflict`, `:too_large`, `:binary`,
  `:not_a_file`, plus `PathSafety` reasons.
  """
  @spec write_text(String.t(), String.t(), binary(), Version.t()) ::
          {:ok, %{version: Version.t(), size: non_neg_integer()}}
          | {:error, write_error()}
  def write_text(root, rel, content, expected_version)
      when is_binary(content) and is_binary(expected_version) do
    cond do
      byte_size(content) > @max_text_bytes ->
        {:error, :too_large}

      PathSafety.likely_binary?(content) ->
        {:error, :binary}

      true ->
        do_write(root, rel, content, expected_version)
    end
  end

  @doc """
  Create a new empty file at `rel`. Refuses if it already exists, or if any
  PathSafety check fails. Returns `{:ok, version}`.
  """
  @spec create_file(String.t(), String.t()) ::
          {:ok, Version.t()} | {:error, write_error() | :exists}
  def create_file(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         :ok <- refuse_existing(abs),
         :ok <- File.write(abs, ""),
         {:ok, stat} <- File.stat(abs) do
      {:ok, Version.compute("", stat)}
    end
  end

  @doc "Create a directory at `rel`. Refuses if it already exists or PathSafety fails."
  @spec create_dir(String.t(), String.t()) :: :ok | {:error, write_error() | :exists}
  def create_dir(root, rel) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         :ok <- refuse_existing(abs),
         :ok <- File.mkdir_p(abs) do
      :ok
    end
  end

  @doc """
  Rename `from` → `to` within the workspace root. Refuses if either side
  fails PathSafety, or if the destination already exists.
  """
  @spec rename(String.t(), String.t(), String.t()) ::
          :ok | {:error, write_error() | :exists | :not_found}
  def rename(root, from, to) do
    with {:ok, src} <- PathSafety.resolve(root, from),
         {:ok, dst} <- PathSafety.resolve(root, to),
         :ok <- require_existing(src),
         :ok <- refuse_existing(dst),
         :ok <- File.rename(src, dst) do
      :ok
    end
  end

  defp refuse_existing(abs) do
    if File.exists?(abs), do: {:error, :exists}, else: :ok
  end

  defp require_existing(abs) do
    if File.exists?(abs), do: :ok, else: {:error, :not_found}
  end

  @doc """
  Delete a regular file. For directories, only empty ones are removed unless
  `recursive: true` is passed.
  """
  @spec delete(String.t(), String.t(), keyword()) ::
          :ok | {:error, write_error() | :not_found | :not_empty}
  def delete(root, rel, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)

    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, stat} <- File.lstat(abs) do
      do_delete(abs, stat, recursive)
    end
  end

  defp do_delete(abs, %File.Stat{type: :regular}, _), do: File.rm(abs)
  defp do_delete(abs, %File.Stat{type: :symlink}, _), do: File.rm(abs)

  defp do_delete(abs, %File.Stat{type: :directory}, true) do
    case File.rm_rf(abs) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp do_delete(abs, %File.Stat{type: :directory}, false) do
    case File.rmdir(abs) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :not_empty}
      {:error, :enotempty} -> {:error, :not_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete(_, _, _), do: {:error, :not_a_file}

  defp do_write(root, rel, content, expected_version) do
    with {:ok, abs} <- PathSafety.resolve(root, rel),
         {:ok, %File.Stat{type: :regular, mode: mode} = stat} <- File.stat(abs),
         {:ok, current} <- File.read(abs),
         current_version = Version.compute(current, stat),
         :ok <- check_version(current_version, expected_version),
         :ok <- atomic_write(abs, content, mode),
         {:ok, new_stat} <- File.stat(abs) do
      {:ok, %{version: Version.compute(content, new_stat), size: byte_size(content)}}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_version(current, expected) when current == expected, do: :ok
  defp check_version(_, _), do: {:error, :conflict}

  defp atomic_write(abs, content, mode) do
    dir = Path.dirname(abs)
    rand = Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    tmp = Path.join(dir, ".devide.tmp." <> rand)

    with :ok <- File.write(tmp, content),
         _ <- File.chmod(tmp, mode),
         :ok <- File.rename(tmp, abs) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp stat_entry(abs, rel, name) do
    full = Path.join(abs, name)

    case File.stat(full) do
      {:ok, stat} -> [Entry.from_stat(name, Path.join(rel, name), stat)]
      _ -> []
    end
  end

  defp erl_to_naive({{y, mo, d}, {h, mi, s}}) do
    case NaiveDateTime.new(y, mo, d, h, mi, s) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp erl_to_naive(_), do: nil
end

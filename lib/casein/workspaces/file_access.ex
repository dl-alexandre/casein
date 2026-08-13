defmodule Casein.Workspaces.FileAccess do
  @moduledoc """
  File and directory access for workspace locations, local or remote.

  Dispatches on a `workspace_loc` tagged tuple from
  `Casein.Workspaces.safe_host_loc/1`. Remote operations shell out via `ssh`
  using the user's `~/.ssh/config` (no in-band credentials).
  """

  alias Casein.Workspaces

  @type loc :: Workspaces.workspace_loc()
  @type entry :: %{name: String.t(), dir?: boolean(), size: non_neg_integer() | nil}
  @type stat :: %{
          type: :regular | :directory | :symlink | :device | :other,
          size: non_neg_integer() | nil
        }

  @max_read_bytes 2 * 1024 * 1024

  @doc "List directory entries under `subpath` relative to the workspace root."
  @spec ls(loc(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def ls(loc, subpath \\ "")

  def ls({:local, root}, sub) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub),
         {:ok, names} <- File.ls(target) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(target, name)
          stat = File.stat(full)

          %{
            name: name,
            dir?: match?({:ok, %File.Stat{type: :directory}}, stat),
            size:
              case stat do
                {:ok, %File.Stat{size: s, type: :regular}} -> s
                _ -> nil
              end
          }
        end)

      {:ok, entries}
    end
  end

  def ls({:remote, host, root}, sub) do
    # `ls -lAp --time-style=+%s` is portable enough for our purposes on Linux.
    # `-p` appends `/` to directories so we can flag them without an extra stat.
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub),
         {:ok, out} <- ssh_quoted(host, ["ls", "-lAp", "--time-style=+%s", "--", target]) do
      {:ok, parse_ls(out)}
    end
  end

  @doc "Stat one workspace-relative path without reading file content."
  @spec stat(loc(), String.t()) :: {:ok, stat()} | {:error, term()}
  def stat({:local, root}, sub) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub),
         {:ok, stat} <- File.stat(target) do
      {:ok, %{type: stat.type, size: stat_size(stat)}}
    end
  end

  def stat({:remote, host, root}, sub) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub),
         {:ok, out} <- ssh_quoted(host, ["stat", "-L", "-c", "%F\t%s", "--", target]) do
      parse_stat(out)
    end
  end

  @doc "Read a file's content (capped at 2 MiB)."
  @spec read(loc(), String.t()) :: {:ok, binary()} | {:error, term()}
  # target is confined by PathSafety.resolve/2 before File.read/1.
  # sobelow_skip ["Traversal.FileModule"]
  def read({:local, root}, sub) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub) do
      File.read(target)
    end
  end

  def read({:remote, host, root}, sub) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, sub) do
      case ssh_quoted(host, ["dd", "if=" <> target, "bs=4096", "count=512", "status=none"]) do
        {:ok, bin} when byte_size(bin) <= @max_read_bytes -> {:ok, bin}
        {:ok, bin} -> {:ok, binary_part(bin, 0, @max_read_bytes)}
        err -> err
      end
    end
  end

  @doc "Human-readable path label for the UI."
  @spec label(loc()) :: String.t()
  def label({:local, path}), do: path
  def label({:remote, host, path}), do: "#{host}:#{path}"

  @doc """
  Read a text file, returning the same shape as `Casein.Files.read_text/2`:

      {:ok, %{path, size, content, mtime, version}}

  Refuses binary content and oversized files. Version token for remote files
  is content-hash-only (no mtime), which is enough for optimistic concurrency
  on the read-modify-write path that already re-reads before writing.
  """
  @spec read_text(loc(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_text({:local, _root} = loc, rel) do
    {:local, root} = loc
    Casein.Files.read_text(root, rel)
  end

  def read_text({:remote, host, root}, rel) do
    with {:ok, target} <- Casein.Files.PathSafety.resolve(root, rel),
         {:ok, bin} <-
           ssh_quoted(host, ["dd", "if=" <> target, "bs=4096", "count=512", "status=none"]),
         false <- Casein.Files.PathSafety.likely_binary?(bin) do
      content =
        if byte_size(bin) > @max_read_bytes, do: binary_part(bin, 0, @max_read_bytes), else: bin

      digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 16)

      {:ok,
       %{
         path: rel,
         size: byte_size(content),
         content: content,
         mtime: nil,
         version: "#{byte_size(content)}:0:#{digest}"
       }}
    else
      true -> {:error, :binary}
      err -> err
    end
  end

  @doc """
  Write content to `rel`, atomically. Returns the same shape as
  `Casein.Files.write_text/4`. Optimistic concurrency: the on-disk content's
  current version must equal `expected_version`, else `{:error, :conflict}`.
  """
  @spec write_text(loc(), String.t(), binary(), String.t()) ::
          {:ok, %{version: String.t(), size: non_neg_integer()}} | {:error, term()}
  def write_text({:local, root}, rel, content, expected_version) do
    Casein.Files.write_text(root, rel, content, expected_version)
  end

  def write_text({:remote, host, root} = loc, rel, content, expected_version)
      when is_binary(content) do
    cond do
      byte_size(content) > @max_read_bytes ->
        {:error, :too_large}

      Casein.Files.PathSafety.likely_binary?(content) ->
        {:error, :binary}

      true ->
        # Confine BEFORE write — do not rely on the version-check read to catch
        # `../../.ssh/authorized_keys` (#927). PathSafety.resolve needs a local
        # filesystem for symlink walks; remote roots use expand+under only.
        with {:ok, target} <- confined_remote_target(root, rel),
             {:ok, %{version: current}} <- read_text(loc, rel),
             true <- current == expected_version do
          # ssh joins post-`--` argv with spaces and runs through the remote
          # login shell. Pass the whole pipeline as one string so the remote
          # shell parses redirection and `$(…)` correctly.
          cmd =
            "tmp=$(mktemp -p \"$(dirname #{shell_quote(target)})\") && cat > \"$tmp\" && mv \"$tmp\" #{shell_quote(target)}"

          case ssh_with_stdin(host, [cmd], content) do
            :ok ->
              digest =
                :crypto.hash(:sha256, content)
                |> Base.encode16(case: :lower)
                |> binary_part(0, 16)

              {:ok,
               %{
                 version: "#{byte_size(content)}:0:#{digest}",
                 size: byte_size(content)
               }}

            err ->
              err
          end
        else
          false -> {:error, :conflict}
          err -> err
        end
    end
  end

  @doc """
  Workspace-wide text search. Matches `Casein.Search.search/3`'s return shape:
  `{:ok, [%Casein.Search.Result{}]}`. For remote workspaces, runs `rg` on the
  far side over ssh.
  """
  @spec search(loc(), String.t(), keyword()) ::
          {:ok, [Casein.Search.Result.t()]} | {:error, term()}
  def search({:local, root}, query, opts), do: Casein.Search.search(root, query, opts)

  def search({:remote, host, root}, query, opts) when is_binary(query) do
    cond do
      String.length(query) < 2 -> {:error, :too_short}
      String.length(query) > 200 -> {:error, :too_long}
      true -> do_remote_search(host, root, query, opts)
    end
  end

  defp do_remote_search(host, root, query, opts) do
    # `grep -rnIF` — recursive, line-numbers, skip binaries, fixed-string.
    # Excludes common heavy dirs. Output: `path:line:content`. Use NUL via -Z
    # so paths with colons parse, but keep it simple: paths in workspaces
    # don't contain colons in practice. Fall back to `grep` because `rg` is
    # frequently absent on minimal hosts.
    excludes =
      ~w(.git _build deps node_modules)
      |> Enum.flat_map(fn d -> ["--exclude-dir=" <> d] end)

    argv = ["grep", "-rnIF", "--no-messages"] ++ excludes ++ ["-e", query, "--", root]
    remote_cmd = Enum.map_join(argv, " ", &shell_quote/1)

    timeout_ms = Keyword.get(opts, :timeout_ms, 10_000)
    result_cap = Keyword.get(opts, :result_cap, 200)

    case ssh_timeout(host, [remote_cmd], timeout_ms) do
      {:ok, output} ->
        capped = binary_part(output, 0, min(byte_size(output), 1 * 1024 * 1024))

        results =
          capped
          |> String.split("\n", trim: true)
          |> Enum.flat_map(&parse_grep_line(&1, root))
          |> Enum.take(result_cap)

        {:ok, results}

      err ->
        err
    end
  end

  # `path:line:preview`
  defp parse_grep_line(line, root) do
    case String.split(line, ":", parts: 3) do
      [path, lineno, preview] ->
        rel = Path.relative_to(path, root)

        if rel == path do
          []
        else
          [
            %Casein.Search.Result{
              path: rel,
              line: parse_int(lineno),
              column: nil,
              preview: preview |> String.replace_trailing("\n", "") |> String.slice(0, 240)
            }
          ]
        end

      _ ->
        []
    end
  end

  defp ssh_timeout(host, argv, timeout_ms) do
    task = Task.async(fn -> ssh(host, argv) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, out}} -> {:ok, out}
      # rg exits 1 when no matches — treat as success-with-empty-output
      {:ok, {:error, {:ssh_failed, 1, _}}} -> {:ok, ""}
      {:ok, err} -> err
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  @doc "Git status --short for the workspace."
  @spec git_status_short(loc()) :: {:ok, [map()]} | {:error, term()}
  def git_status_short({:local, root}), do: Casein.Git.status_short(root)

  def git_status_short({:remote, host, root}) do
    cmd = ["git", "-C", root, "status", "--short", "--untracked-files=all"]
    remote = Enum.map_join(cmd, " ", &shell_quote/1)

    case ssh(host, [remote]) do
      {:ok, out} -> {:ok, parse_status_short(out)}
      err -> err
    end
  end

  @doc "Git diff of one path."
  @spec git_diff(loc(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def git_diff({:local, root}, rel), do: Casein.Git.diff(root, rel)

  def git_diff({:remote, host, root}, rel) do
    cmd = ["git", "-C", root, "diff", "--no-color", "--", rel]
    remote = Enum.map_join(cmd, " ", &shell_quote/1)

    case ssh(host, [remote]) do
      {:ok, out} -> {:ok, cap_diff(out)}
      err -> err
    end
  end

  defp parse_status_short(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      <<x, y, " ", rest::binary>> ->
        [%{x: <<x>>, y: <<y>>, path: rest}]

      _ ->
        []
    end)
  end

  defp cap_diff(bin) when byte_size(bin) <= 256 * 1024, do: bin
  defp cap_diff(bin), do: binary_part(bin, 0, 256 * 1024)

  ## Internals

  # Pure path confinement for remote roots (no local File.lstat). Rejects
  # `..` escapes and absolute `rel` that leave the workspace root.
  defp confined_remote_target(root, rel) when is_binary(root) and is_binary(rel) do
    root_abs = Path.expand(root)
    target = Path.expand(rel, root_abs)
    relative = Path.relative_to(target, root_abs)

    if relative != target and not String.starts_with?(relative, "..") and
         not String.contains?(relative, "\0") do
      {:ok, target}
    else
      {:error, :outside_root}
    end
  end

  defp confined_remote_target(_, _), do: {:error, :outside_root}

  defp shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end

  defp ssh_quoted(host, argv) do
    remote = Enum.map_join(argv, " ", &shell_quote/1)
    ssh(host, [remote])
  end

  defp ssh_with_stdin(host, argv, stdin),
    do: Casein.Workspaces.SshRunner.run_with_stdin(host, argv, stdin)

  defp ssh(host, argv), do: Casein.Workspaces.SshRunner.run(host, argv)

  # Parses `ls -lAp` output. First line is "total N"; subsequent lines:
  #   "drwxr-xr-x 5 user grp 4096 2024-01-01 name/"   (directory; trailing /)
  #   "-rw-r--r-- 1 user grp  123 2024-01-01 file.txt"
  defp parse_ls(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "total "))
    |> Enum.flat_map(fn line ->
      case parse_ls_line(line) do
        nil -> []
        entry -> [entry]
      end
    end)
    |> Enum.sort_by(&{not &1.dir?, &1.name})
  end

  defp parse_ls_line(line) do
    case String.split(line, ~r/\s+/, parts: 9) do
      [perm, _links, _user, _grp, size, _m, _d, _t, name] ->
        dir? = String.starts_with?(perm, "d") or String.ends_with?(name, "/")
        clean_name = String.trim_trailing(name, "/")

        %{
          name: clean_name,
          dir?: dir?,
          size: parse_int(size)
        }

      _ ->
        nil
    end
  end

  defp stat_size(%File.Stat{type: :regular, size: size}), do: size
  defp stat_size(_), do: nil

  defp parse_stat(out) do
    case out |> String.trim() |> String.split("\t", parts: 2) do
      [type, size] ->
        type = stat_type(type)
        size = if type == :regular, do: parse_int(size), else: nil
        {:ok, %{type: type, size: size}}

      _ ->
        {:error, :invalid_stat}
    end
  end

  defp stat_type("regular file"), do: :regular
  defp stat_type("directory"), do: :directory
  defp stat_type("symbolic link"), do: :symlink
  defp stat_type("character special file"), do: :device
  defp stat_type("block special file"), do: :device
  defp stat_type(_), do: :other

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end
end

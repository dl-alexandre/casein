defmodule Casein.Agents.SkillIntegrity do
  @moduledoc """
  Whether the skill copies agents actually load still match the canonical ones.

  Casein's skills live in the casein checkout under `.claude/skills`, but agents
  routinely run in *other* product repos, so `scripts/lib/agent-skills.sh`
  copies the host-infrastructure skills into each provider config home at launch.
  Copying is the right call — the alternative is an orchestrator that cannot
  delegate — but it means the instructions an agent is following are a
  *duplicate* of the ones in the repo, and duplicates drift.

  The staging script compares trees when it runs, so a launch heals drift. The
  gap is everything between launches: a skill edited in place, a copy staged
  from an older checkout, a provider home that has not seen a launch since the
  canonical version changed. Nothing reports any of that today, and the failure
  mode is quiet — an agent confidently following instructions no one has read in
  months.

  ## States

  Per skill name, across every root that has a copy:

    * `:single` — one copy. Nothing to disagree with.
    * `:identical` — several copies, all fingerprinting the same.
    * `:divergent` — several copies with more than one fingerprint. Some agent
      is following different instructions from the rest.
    * `:unknown` — at least one copy could not be read. Not the same as
      agreement, and deliberately not merged into `:identical`.

  ## What is hashed

  The whole tree — `SKILL.md`, `references/`, scripts, nested directories — so a
  changed helper counts as drift even when `SKILL.md` is untouched. Paths are
  included alongside contents, so moving a file is a change.

  Two things are excluded. VCS and cache metadata (`.git`, `__pycache__`,
  `.DS_Store`) never reflect instruction content. And `.casein-staged`, the
  marker `agent-skills.sh` writes into copies it owns, exists only in the
  destination — counting it would make **every** staged copy divergent from
  canonical, which is the same reason the staging script excludes it from its
  own `diff -rq`.
  """

  # Bounds a runaway tree (a skill that accreted a node_modules) rather than
  # hashing an unbounded amount of disk on an operator-facing path.
  @max_files 500
  @max_bytes 5_000_000

  @marker ".casein-staged"
  @pruned ~w(.git __pycache__ .DS_Store node_modules)

  @type state :: :single | :identical | :divergent | :unknown

  @type copy :: %{
          root: String.t(),
          label: String.t() | nil,
          path: String.t(),
          fingerprint: String.t() | nil,
          reason: atom() | nil
        }

  @type skill :: %{
          name: String.t(),
          state: state(),
          copies: [copy()],
          fingerprints: [String.t()]
        }

  @doc "Files and directories never counted as instruction content."
  @spec pruned_names() :: [String.t()]
  def pruned_names, do: [@marker | @pruned]

  @doc """
  The roots agents actually load skills from on this box.

  The canonical copy in the casein checkout, the host global Claude and
  OpenCode homes, and every owner auth profile. Profiles are enumerated rather
  than named because drift is per-owner: the whole point is to notice that one
  owner's agents are running a version nobody else is.
  """
  @spec default_roots() :: [map()]
  def default_roots do
    home = Casein.Paths.home!()

    profiles =
      [home, ".casein", "agent-auth", "profiles", "*", "claude", "skills"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.map(fn path ->
        %{path: path, label: "profile:" <> Enum.at(Path.split(path), -3)}
      end)

    [
      %{path: Path.join(checkout(), ".claude/skills"), label: "canonical"},
      %{path: Path.join(home, ".claude/skills"), label: "claude-global"},
      %{path: Path.join(home, ".config/opencode/skills"), label: "opencode"}
    ] ++ profiles
  end

  defp checkout do
    case System.get_env("CASEIN_CHECKOUT") do
      path when is_binary(path) and path != "" -> path
      _ -> File.cwd!()
    end
  end

  @doc """
  Classify every skill name found across `roots`.

  `roots` are `%{path: ..., label: ...}` maps (or bare paths) in whatever order;
  the first root that carries a copy is not privileged, because this reports
  disagreement rather than picking a winner. Missing roots are skipped — a
  provider home that has never been staged is not drift.
  """
  @spec observe([map() | String.t()], keyword()) :: [skill()]
  def observe(roots, _opts \\ []) when is_list(roots) do
    roots
    |> Enum.map(&normalize_root/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&copies_in_root/1)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, copies} -> classify(name, Enum.map(copies, & &1.copy)) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Only the skills whose copies disagree or could not be read."
  @spec divergent([skill()]) :: [skill()]
  def divergent(skills) when is_list(skills) do
    Enum.filter(skills, &(&1.state in [:divergent, :unknown]))
  end

  @doc """
  Fingerprint one skill directory.

  Returns `{:error, reason}` rather than a sentinel hash when the tree cannot be
  read — an unreadable copy must not silently compare equal to anything.
  """
  @spec fingerprint(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def fingerprint(dir) when is_binary(dir) do
    case collect(dir) do
      {:ok, []} -> {:error, :empty}
      {:ok, entries} -> {:ok, hash(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Internals

  defp classify(name, copies) do
    fingerprints =
      copies
      |> Enum.map(& &1.fingerprint)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    state =
      cond do
        # Unreadable first: a tree we could not hash is not evidence of
        # agreement, whatever the other copies say.
        Enum.any?(copies, &is_nil(&1.fingerprint)) -> :unknown
        length(fingerprints) > 1 -> :divergent
        length(copies) > 1 -> :identical
        true -> :single
      end

    %{name: name, state: state, copies: copies, fingerprints: fingerprints}
  end

  defp copies_in_root(%{path: path} = root) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.map(&{&1, Path.join(path, &1)})
        |> Enum.filter(fn {_name, dir} -> File.dir?(dir) end)
        |> Enum.map(fn {name, dir} -> %{name: name, copy: copy_for(root, dir)} end)

      # A provider home that was never staged is absence, not drift.
      {:error, _reason} ->
        []
    end
  end

  defp copy_for(%{path: root_path, label: label}, dir) do
    {fingerprint, reason} =
      case fingerprint(dir) do
        {:ok, hash} -> {hash, nil}
        {:error, reason} -> {nil, reason}
      end

    %{root: root_path, label: label, path: dir, fingerprint: fingerprint, reason: reason}
  end

  # Relative paths are hashed alongside contents so a moved file is a change,
  # and the list is sorted so filesystem enumeration order cannot alter the
  # fingerprint of an identical tree.
  defp hash(entries) do
    entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {rel, content}, acc ->
      acc
      |> :crypto.hash_update(rel)
      |> :crypto.hash_update(<<0>>)
      |> :crypto.hash_update(content)
      |> :crypto.hash_update(<<0>>)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp collect(dir) do
    if File.dir?(dir) do
      walk([{dir, ""}], dir, [], 0, 0)
    else
      {:error, :enoent}
    end
  end

  defp walk([], _root, acc, _files, _bytes), do: {:ok, acc}

  defp walk(_queue, _root, _acc, files, bytes)
       when files > @max_files or bytes > @max_bytes,
       do: {:error, :too_large}

  # sobelow_skip ["Traversal.FileModule"]
  defp walk([{dir, prefix} | rest], root, acc, files, bytes) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reduce_while({rest, acc, files, bytes}, fn entry, state ->
          visit(entry, dir, prefix, state)
        end)
        |> case do
          {:error, reason} -> {:error, reason}
          {queue, acc, files, bytes} -> walk(queue, root, acc, files, bytes)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp visit(entry, dir, prefix, {queue, acc, files, bytes}) do
    path = Path.join(dir, entry)
    rel = if prefix == "", do: entry, else: prefix <> "/" <> entry

    cond do
      entry in [@marker | @pruned] ->
        {:cont, {queue, acc, files, bytes}}

      File.dir?(path) ->
        {:cont, {queue ++ [{path, rel}], acc, files, bytes}}

      true ->
        read_file(path, rel, {queue, acc, files, bytes})
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path, rel, {queue, acc, files, bytes}) do
    case File.read(path) do
      {:ok, content} ->
        {:cont, {queue, [{rel, content} | acc], files + 1, bytes + byte_size(content)}}

      # One unreadable file makes the whole tree unreadable: hashing what is
      # left would produce a confident fingerprint for a partial read. The
      # reason has to stay distinct from `:too_large`, or the operator goes
      # looking for a huge directory that does not exist.
      {:error, _reason} ->
        {:halt, {:error, :unreadable}}
    end
  end

  defp normalize_root(path) when is_binary(path) and path != "",
    do: %{path: Path.expand(path), label: nil}

  defp normalize_root(%{path: path} = root) when is_binary(path) and path != "" do
    %{path: Path.expand(path), label: Map.get(root, :label)}
  end

  defp normalize_root(_root), do: nil
end

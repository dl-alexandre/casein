defmodule Casein.Desktop.AgentWorktree do
  @moduledoc """
  Creates isolated Git worktrees for native Windows agent launches.

  Paths are application-derived beneath one validated root. Git is invoked with
  an argv list and never through a command shell.
  """

  @runtimes ~w(codex claude grok opencode cursor)
  @segment ~r/\A[a-z0-9][a-z0-9-]{0,47}\z/

  @type result :: %{
          path: String.t(),
          branch: String.t(),
          base_ref: String.t(),
          primary: String.t()
        }

  @spec create(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def create(primary, runtime, task \\ "adhoc", opts \\ [])

  def create(primary, runtime, task, opts)
      when is_binary(primary) and is_binary(runtime) and is_binary(task) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &git/2)

    with :ok <- validate_runtime(runtime),
         {:ok, task} <- validate_task(task),
         {:ok, primary} <- repository_root(primary, runner),
         {:ok, root} <- worktree_root(primary, opts),
         {:ok, base_ref} <- base_ref(primary, opts, runner),
         {:ok, branch} <- branch_name(runtime, task, opts) do
      path = Path.join(root, String.replace(branch, "/", "-"))

      case runner.(["-C", primary, "worktree", "add", "-b", branch, path, base_ref], []) do
        {_output, 0} -> {:ok, %{path: path, branch: branch, base_ref: base_ref, primary: primary}}
        {output, status} -> {:error, {:git_worktree_add_failed, status, bounded(output)}}
      end
    end
  end

  def create(_primary, _runtime, _task, _opts), do: {:error, :invalid_arguments}

  defp validate_runtime(runtime) when runtime in @runtimes, do: :ok
  defp validate_runtime(_runtime), do: {:error, :unsupported_agent}

  defp validate_task(task) do
    slug = task |> String.trim() |> String.downcase()
    if Regex.match?(@segment, slug), do: {:ok, slug}, else: {:error, :invalid_task}
  end

  defp repository_root(primary, runner) do
    case runner.(["-C", primary, "rev-parse", "--show-toplevel"], []) do
      {output, 0} -> {:ok, output |> String.trim() |> Path.expand()}
      {_output, _status} -> {:error, :not_a_git_repository}
    end
  end

  # root is canonicalized and rejected inside the primary repository before and after creation.
  # sobelow_skip ["Traversal.FileModule"]
  defp worktree_root(primary, opts) do
    root =
      Keyword.get(opts, :root) ||
        Path.join(System.get_env("TEMP") || System.tmp_dir!(), "casein-agent-worktrees")

    with {:ok, root} <- canonical_path(root),
         {:ok, primary} <- canonical_path(primary),
         :ok <- validate_root_location(root, primary),
         :ok <- File.mkdir_p(root),
         {:ok, created_root} <- canonical_path(root),
         :ok <- validate_root_location(created_root, primary) do
      {:ok, created_root}
    end
  end

  defp validate_root_location(root, primary) do
    if within?(root, primary), do: {:error, :worktree_root_inside_repository}, else: :ok
  end

  defp base_ref(primary, opts, runner) do
    case Keyword.get(opts, :base_ref) do
      ref when is_binary(ref) -> validate_base_ref(ref)
      nil -> discover_base_ref(primary, runner)
      _other -> {:error, :invalid_base_ref}
    end
  end

  defp validate_base_ref(ref) do
    if Regex.match?(~r/\A[A-Za-z0-9._\/-]+\z/, ref) and not String.starts_with?(ref, "-") and
         not String.contains?(ref, ".."),
       do: {:ok, ref},
       else: {:error, :invalid_base_ref}
  end

  defp discover_base_ref(primary, runner) do
    candidates = ["origin/HEAD", "origin/master", "origin/main", "HEAD"]

    Enum.find_value(candidates, {:error, :base_ref_not_found}, fn ref ->
      case runner.(["-C", primary, "rev-parse", "--verify", "#{ref}^{commit}"], []) do
        {_output, 0} -> {:ok, ref}
        _ -> false
      end
    end)
  end

  defp branch_name(runtime, task, opts) do
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> DateTime.utc_now() end)
    suffix = Keyword.get_lazy(opts, :suffix, fn -> System.unique_integer([:positive]) end)

    if match?(%DateTime{}, timestamp) and is_integer(suffix) and suffix > 0 do
      stamp = Calendar.strftime(timestamp, "%Y%m%d%H%M%S")
      {:ok, "agent/#{runtime}/#{task}-#{stamp}-#{suffix}"}
    else
      {:error, :invalid_branch_identity}
    end
  end

  defp within?(path, parent) do
    path = comparison_path(path)
    parent = comparison_path(parent)
    path == parent or String.starts_with?(path, parent <> "/")
  end

  defp comparison_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, nil}, fn segment, {:ok, current} ->
      candidate = if is_nil(current), do: segment, else: Path.join(current, segment)

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          case File.read_link(candidate) do
            {:ok, target} -> {:cont, {:ok, Path.expand(target, Path.dirname(candidate))}}
            {:error, reason} -> {:halt, {:error, {:worktree_root_unreadable, reason}}}
          end

        {:ok, _stat} ->
          {:cont, {:ok, candidate}}

        {:error, :enoent} ->
          {:cont, {:ok, candidate}}

        {:error, reason} ->
          {:halt, {:error, {:worktree_root_unreadable, reason}}}
      end
    end)
  end

  # The executable is a fixed product dependency and every argument is passed as argv.
  # sobelow_skip ["CI.System"]
  defp git(args, opts), do: System.cmd("git", args, Keyword.merge([stderr_to_stdout: true], opts))

  defp bounded(output), do: output |> to_string() |> String.trim() |> String.slice(0, 1_024)
end

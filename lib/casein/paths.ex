defmodule Casein.Paths do
  @moduledoc """
  Portable filesystem anchors for Casein.

  Product code must not hard-code operator home directories or host worktree
  roots. Resolve anchors from the process environment (or a test override) so a
  fresh clone, container image, or desktop host works without MILC topology baked
  into defaults.
  """

  @doc """
  Resolve the current user's home directory.

  Order:

  1. `:casein, :home_dir` application env (tests / managed overlays)
  2. `$HOME`
  3. `$USERPROFILE` (Windows)
  4. `System.user_home/0`

  Returns `nil` when none is available.
  """
  @spec home() :: String.t() | nil
  def home do
    cond do
      present?(Application.get_env(:casein, :home_dir)) ->
        Application.get_env(:casein, :home_dir)

      present?(System.get_env("HOME")) ->
        System.get_env("HOME")

      present?(System.get_env("USERPROFILE")) ->
        System.get_env("USERPROFILE")

      true ->
        case System.user_home() do
          home when is_binary(home) and home != "" -> home
          _ -> nil
        end
    end
  end

  @doc """
  Like `home/0`, but raises when no home directory can be resolved.

  Portable container/desktop profiles always set `HOME` (the production image
  uses `/home/casein`). Failing closed here is preferable to inventing a
  host-specific path.
  """
  @spec home!() :: String.t()
  def home! do
    case home() do
      home when is_binary(home) ->
        home

      nil ->
        raise ArgumentError,
              "HOME or USERPROFILE is required; Casein does not default to a host-specific path"
    end
  end

  @doc """
  Agent-worktree roots from config and env only (no portable defaults).

  Sources, in order:

  1. `:casein, :agent_worktree_roots` application env (list of strings)
  2. `$CASEIN_AGENT_WORKTREE_ROOTS` (comma- or colon-separated)

  Empty entries are dropped. Paths are expanded.
  """
  @spec configured_agent_worktree_roots() :: [String.t()]
  def configured_agent_worktree_roots do
    (app_agent_worktree_roots() ++ env_agent_worktree_roots())
    |> Enum.map(&expand_root/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Portable default agent-worktree roots — no host-specific path literals.

  Always includes `$TMPDIR/casein-agent-worktrees` (or the OS temp dir). When a
  home directory resolves, also includes home-relative agent cache locations
  (`~/.local/share/{opencode,codex}`, `~/.cache/codex`, `~/.claude`).
  """
  @spec default_agent_worktree_roots() :: [String.t()]
  def default_agent_worktree_roots do
    tmp_root = Path.join(System.tmp_dir!(), "casein-agent-worktrees")

    home_roots =
      case home() do
        home when is_binary(home) and home != "" ->
          [
            Path.join(home, ".local/share/opencode"),
            Path.join(home, ".local/share/codex"),
            Path.join(home, ".cache/codex"),
            Path.join(home, ".claude")
          ]

        _ ->
          []
      end

    [tmp_root | home_roots]
  end

  @doc """
  Roots used when scanning the host for agent worktrees (alarms, janitors).

  Uses `configured_agent_worktree_roots/0` when non-empty; otherwise falls back
  to `default_agent_worktree_roots/0`. Does not invent MILC paths such as
  `/data/casein-agent-worktrees`.
  """
  @spec agent_worktree_roots() :: [String.t()]
  def agent_worktree_roots do
    case configured_agent_worktree_roots() do
      [] -> default_agent_worktree_roots()
      roots -> roots
    end
  end

  @doc """
  Full admission root set for validating an observed agent worktree path.

  Concatenates configured roots, optional extra roots (e.g. artifact project
  root), and portable defaults. Callers that need artifact roots should pass
  them via `extra`.
  """
  @spec agent_worktree_admission_roots(keyword()) :: [String.t()]
  def agent_worktree_admission_roots(opts \\ []) do
    extra =
      opts
      |> Keyword.get(:extra, [])
      |> List.wrap()
      |> Enum.map(&expand_root/1)
      |> Enum.reject(&is_nil/1)

    configured_agent_worktree_roots() ++ extra ++ default_agent_worktree_roots()
  end

  defp app_agent_worktree_roots do
    case Application.get_env(:casein, :agent_worktree_roots, []) do
      roots when is_list(roots) -> Enum.filter(roots, &(is_binary(&1) and &1 != ""))
      root when is_binary(root) and root != "" -> [root]
      _ -> []
    end
  end

  defp env_agent_worktree_roots do
    case System.get_env("CASEIN_AGENT_WORKTREE_ROOTS") do
      nil -> []
      "" -> []
      value -> String.split(value, [",", ":"], trim: true)
    end
  end

  defp expand_root(root) when is_binary(root) and root != "", do: Path.expand(root)
  defp expand_root(_), do: nil

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false
end

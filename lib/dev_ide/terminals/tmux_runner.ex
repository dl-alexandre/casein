defmodule DevIDE.Terminals.TmuxRunner do
  @moduledoc """
  DevIDE argv wrapper for `TmuxCtl` tmux subprocesses.

  Routes tmux through `WorkspaceSource.prepare_local_argv/2` when workspaces
  run inside a manager-owned container, unless `:tmux_host_shell` forces host tmux.
  """

  @behaviour TmuxCtl.Runner

  alias DevIDE.Terminals.TmuxServer
  alias DevIDE.WorkspaceSource

  @doc """
  Whether tmux sessions and one-shot topology calls target host tmux directly.
  """
  @spec host_shell?() :: boolean()
  def host_shell? do
    Application.get_env(:dev_ide, :tmux_host_shell) ||
      System.get_env("DEV_IDE_TMUX_HOST_SHELL") in ~w(1 true yes)
  end

  @doc """
  Probe whether `tmux` is available inside the wrapped (container) context
  for `cwd`. Cached in `:persistent_term` per cwd — Session.init uses it to
  decide between the in-container tmux server (preferred) and the legacy
  host-tmux fallback for workspace images that don't yet ship tmux.
  """
  @spec container_has_tmux?(String.t()) :: boolean()
  def container_has_tmux?(cwd) do
    key = {__MODULE__, :container_tmux, cwd}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        result = probe_container_tmux(cwd)
        if result, do: :persistent_term.put(key, true)
        result

      cached ->
        cached
    end
  end

  # sobelow_skip ["CI.System"]
  @impl TmuxCtl.Runner
  def run(argv, opts \\ []) when is_list(argv) do
    [cmd | args] = argv(argv, opts)

    cmd_opts =
      opts
      |> Keyword.take([:cd])
      |> Keyword.put_new(:stderr_to_stdout, true)

    System.cmd(cmd, args, cmd_opts)
  end

  @doc """
  Build a host/container-wrapped argv for `tmux` subcommand arguments.

  Options:

    * `:cwd` — passed to `WorkspaceSource.prepare_local_argv/2` when wrapping
  """
  @spec argv([String.t()], keyword()) :: [String.t()]
  def argv(tmux_args, opts \\ []) when is_list(tmux_args) do
    if host_shell?() or host_session_target?(tmux_args) do
      host_tmux_argv(tmux_args)
    else
      case Keyword.get(opts, :cwd) do
        cwd when is_binary(cwd) and cwd != "" ->
          WorkspaceSource.prepare_local_argv(["tmux"] ++ TmuxServer.args() ++ tmux_args, cwd: cwd)

        _ ->
          WorkspaceSource.prepare_local_argv(["tmux"] ++ TmuxServer.args() ++ tmux_args)
      end
    end
  end

  defp host_tmux_argv(tmux_args),
    do: ["tmux"] ++ TmuxServer.args() ++ host_tmux_config_args() ++ tmux_args

  defp host_tmux_config_args do
    case host_tmux_config_file() do
      path when is_binary(path) and path != "" -> ["-f", path]
      _ -> []
    end
  end

  defp host_tmux_config_file do
    [
      Application.get_env(:tmux_ctl, :config_file),
      Application.get_env(:dev_ide, :tmux_config_file),
      System.get_env("DEV_IDE_TMUX_CONFIG"),
      default_host_tmux_config_file()
    ]
    |> Enum.find(&(is_binary(&1) and File.regular?(&1)))
  end

  defp default_host_tmux_config_file do
    case :code.priv_dir(:dev_ide) do
      priv when is_list(priv) -> Path.join(to_string(priv), "tmux/devide.conf")
      _ -> nil
    end
  end

  defp host_session_target?(tmux_args) do
    case target_session(tmux_args) do
      session when is_binary(session) and session != "" -> host_session_alive?(session)
      _ -> false
    end
  end

  defp target_session(["-t", target | _]), do: normalize_target(target)
  defp target_session([_arg | rest]), do: target_session(rest)
  defp target_session([]), do: nil

  defp normalize_target(target) when is_binary(target) do
    target
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_target(_target), do: nil

  # sobelow_skip ["CI.System"]
  defp host_session_alive?(session) do
    case System.cmd("tmux", TmuxServer.args() ++ ["has-session", "-t", session],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # sobelow_skip ["CI.System"]
  defp probe_container_tmux(cwd) do
    probe_argv =
      WorkspaceSource.prepare_local_argv(["sh", "-c", "command -v tmux >/dev/null 2>&1"])

    case probe_argv do
      ["sh" | _] ->
        true

      [cmd | args] ->
        case System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true) do
          {_, 0} ->
            true

          {out, code} ->
            require Logger

            Logger.info(
              "container at #{cwd} lacks tmux (exit=#{code}, out=#{inspect(String.slice(out, 0, 200))}); " <>
                "Terminals.Session will fall back to host tmux"
            )

            false
        end
    end
  rescue
    e in [ErlangError, File.Error] ->
      require Logger

      Logger.warning(
        "container tmux probe failed at #{cwd}: #{Exception.message(e)}; assuming absent"
      )

      false
  end
end

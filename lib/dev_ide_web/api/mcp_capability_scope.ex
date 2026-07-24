defmodule CaseinWeb.API.MCPCapabilityScope do
  @moduledoc """
  Filters MCP discovery and authorizes calls for an agent capability.

  Meta-tools are intentionally unavailable to capability clients. In
  particular, denying `invoke_tool` prevents its cross-server router from
  bypassing the exact direct-tool grant.
  """

  alias Casein.Agents.TerminalTools
  alias CaseinWeb.API.MCPToolSearch

  @spec filter_tools([map()], keyword()) :: [map()]
  def filter_tools(tools, opts) when is_list(tools) do
    case capability_context(opts) do
      :none -> tools
      {:ok, surface, allowed, _claims} -> Enum.filter(tools, &(tool_name(&1) in allowed[surface]))
      {:error, _reason} -> []
    end
  end

  @spec authorize_call(map(), keyword()) :: :ok | {:error, atom()}
  def authorize_call(params, opts) when is_map(params) do
    case capability_context(opts) do
      :none -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, surface, allowed, claims} -> authorize_params(params, surface, allowed, claims)
    end
  end

  def authorize_call(_params, opts) do
    case capability_context(opts) do
      :none -> :ok
      _ -> {:error, :capability_invalid_tool_call}
    end
  end

  @doc "Authorize a call and inject the capability's immutable session scope."
  @spec prepare_call(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare_call(params, opts) when is_map(params) do
    with :ok <- authorize_call(params, opts) do
      {:ok, bind_session(params, opts)}
    end
  end

  def prepare_call(_params, _opts), do: {:error, :capability_invalid_tool_call}

  defp authorize_params(params, surface, allowed, claims) do
    name = Map.get(params, "name") || Map.get(params, :name)

    cond do
      not is_binary(name) ->
        {:error, :capability_invalid_tool_call}

      MCPToolSearch.meta_tool?(name) ->
        {:error, :capability_meta_tool_forbidden}

      name not in Map.get(allowed, surface, []) ->
        {:error, :capability_tool_forbidden}

      true ->
        args = Map.get(params, "arguments", %{}) || %{}

        with :ok <- authorize_bound_session(surface, name, args, claims) do
          authorize_bound_report(name, args, claims)
        end
    end
  end

  defp authorize_bound_session("terminal", name, args, claims) when is_map(args) do
    requested = Map.get(args, "session") || Map.get(args, :session)
    pane = Map.get(args, "pane") || Map.get(args, :pane)
    reported = Map.get(args, "tmux_session_id") || Map.get(args, :tmux_session_id)

    cond do
      requested not in [nil, "", claims.tmux_session_id] ->
        {:error, :capability_session_mismatch}

      pane not in [nil, "", claims.pane_id] ->
        {:error, :capability_pane_mismatch}

      name == "terminal_report_worktree" and
          reported not in [nil, "", claims.tmux_session_id] ->
        {:error, :capability_session_mismatch}

      true ->
        :ok
    end
  end

  defp authorize_bound_session(_surface, _name, _args, _claims), do: :ok

  defp authorize_bound_report("terminal_report_agent_state", args, claims) when is_map(args) do
    leader = Map.get(args, "grok_leader_socket") || Map.get(args, :grok_leader_socket)
    bundle_dir = Map.get(args, "grok_bundle_dir") || Map.get(args, :grok_bundle_dir)
    digest = Map.get(args, "grok_bundle_digest") || Map.get(args, :grok_bundle_digest)
    runtime = Map.get(args, "agent_runtime") || Map.get(args, :agent_runtime)
    transcript = Map.get(args, "transcript_path") || Map.get(args, :transcript_path)

    cond do
      runtime != "grok" ->
        {:error, :capability_runtime_mismatch}

      digest != claims.bundle_digest ->
        {:error, :capability_bundle_mismatch}

      not bound_bundle_dir?(bundle_dir, claims.bundle_digest) ->
        {:error, :capability_bundle_mismatch}

      not bound_leader?(leader, claims.leader_id) ->
        {:error, :capability_leader_mismatch}

      not bound_transcript?(transcript, claims.leader_id) ->
        {:error, :capability_transcript_mismatch}

      true ->
        :ok
    end
  end

  defp authorize_bound_report(_name, _args, _claims), do: :ok

  defp bound_leader?(leader, expected) when is_binary(leader) and is_binary(expected) do
    Path.basename(leader) == "leader.sock" and
      Path.basename(Path.dirname(leader)) == expected
  end

  defp bound_leader?(_leader, _expected), do: false

  defp bound_bundle_dir?(dir, expected) when is_binary(dir) and is_binary(expected),
    do: Path.basename(dir) in [expected, "sha256-" <> expected]

  defp bound_bundle_dir?(_dir, _expected), do: false

  defp bound_transcript?(path, leader_id)
       when is_binary(path) and is_binary(leader_id) do
    if Regex.match?(~r/\A[0-9a-f]{24}\z/, leader_id) do
      home = Path.expand(System.get_env("HOME") || "/home/devbox")
      root = Path.join([home, ".devide", "grok-homes", leader_id, "sessions"])
      expanded = Path.expand(path)

      Path.basename(expanded) == "updates.jsonl" and
        expanded != root and
        String.starts_with?(expanded, root <> "/")
    else
      false
    end
  end

  defp bound_transcript?(_path, _leader_id), do: false

  defp bind_session(params, opts) do
    case capability_context(opts) do
      {:ok, "terminal", _allowed, claims} ->
        name = Map.get(params, "name") || Map.get(params, :name)
        args = Map.get(params, "arguments", %{}) || %{}

        args =
          cond do
            name == "terminal_report_worktree" ->
              Map.put_new(args, "tmux_session_id", claims.tmux_session_id)

            terminal_session_parameter?(name) ->
              Map.put_new(args, "session", claims.tmux_session_id)

            true ->
              args
          end

        args =
          if terminal_pane_parameter?(name),
            do: Map.put_new(args, "pane", claims.pane_id),
            else: args

        Map.put(params, "arguments", args)

      _ ->
        params
    end
  end

  defp terminal_session_parameter?(name) when is_binary(name) do
    Enum.any?(TerminalTools.definitions(), fn tool ->
      properties = get_in(tool.parameters, [:properties]) || %{}

      tool.name == name and
        (Map.has_key?(properties, :session) or Map.has_key?(properties, "session"))
    end)
  end

  defp terminal_session_parameter?(_name), do: false

  defp terminal_pane_parameter?(name) when is_binary(name) do
    Enum.any?(TerminalTools.definitions(), fn tool ->
      properties = get_in(tool.parameters, [:properties]) || %{}
      tool.name == name and (Map.has_key?(properties, :pane) or Map.has_key?(properties, "pane"))
    end)
  end

  defp terminal_pane_parameter?(_name), do: false

  defp capability_context(opts) do
    case Keyword.get(opts, :agent_capability) do
      claims when is_map(claims) ->
        surface = Keyword.get(opts, :agent_capability_surface)
        allowed = Keyword.get(opts, :agent_capability_tools)

        if is_binary(surface) and is_map(allowed),
          do: {:ok, surface, allowed, claims},
          else: {:error, :invalid_capability_context}

      _ ->
        :none
    end
  end

  defp tool_name(tool), do: Map.get(tool, :name) || Map.get(tool, "name")
end

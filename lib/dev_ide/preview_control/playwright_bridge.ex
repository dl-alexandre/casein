defmodule DevIDE.PreviewControl.PlaywrightBridge do
  @moduledoc false
  use GenServer
  require Logger

  @timeout 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec command(map()) :: {:ok, map()} | {:error, term()}
  def command(payload) when is_map(payload) do
    GenServer.call(__MODULE__, {:command, payload}, @timeout)
  end

  @impl GenServer
  def init(_opts) do
    case script_path() do
      nil ->
        if Application.get_env(:dev_ide, :preview_playwright_script) do
          Logger.warning("Preview Playwright helper script was configured but could not be found")
        end

        {:ok, %{port: nil, pending: nil, buffer: ""}}

      script ->
        scripts_dir = Path.dirname(script)

        case System.find_executable("node") do
          nil ->
            Logger.warning("Preview Playwright helper is configured, but node is not available")
            {:ok, %{port: nil, pending: nil, buffer: ""}}

          executable ->
            port =
              Port.open({:spawn_executable, executable}, [
                {:args, [script, "--daemon"]},
                :binary,
                :exit_status,
                :hide,
                {:line, 10_000_000},
                {:cd, scripts_dir}
              ])

            {:ok, %{port: port, pending: nil, buffer: ""}}
        end
    end
  end

  @impl GenServer
  def handle_call({:command, _payload}, _from, %{port: nil} = state) do
    {:reply, {:error, :playwright_unavailable}, state}
  end

  def handle_call({:command, payload}, from, %{port: port, pending: nil} = state) do
    Port.command(port, Jason.encode!(payload) <> "\n")
    {:noreply, %{state | pending: from}}
  end

  def handle_call({:command, _payload}, _from, %{pending: _} = state) do
    {:reply, {:error, :playwright_busy}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port, pending: from} = state)
      when not is_nil(from) do
    reply = decode_line(line)
    GenServer.reply(from, reply)
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    # Orphan response — ignore.
    _ = decode_line(line)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if pending = state.pending do
      GenServer.reply(pending, {:error, {:playwright_exited, status}})
    end

    {:noreply, %{state | port: nil, pending: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"ok" => true} = result} -> {:ok, result}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, {:playwright_error, error}}
      {:ok, _} -> {:error, :invalid_playwright_response}
      {:error, _} -> {:error, :invalid_playwright_response}
    end
  end

  @doc false
  def script_path do
    case Application.get_env(:dev_ide, :preview_playwright_script) do
      nil -> nil
      path when is_binary(path) -> resolve_script_path(path)
    end
  end

  defp resolve_script_path(path) do
    path
    |> candidate_script_paths()
    |> Enum.find(&File.regular?/1)
  end

  defp candidate_script_paths(path) do
    cwd_path = Path.expand(path, File.cwd!())

    priv_path =
      if Path.type(path) == :relative do
        with dir when is_binary(dir) <- priv_dir() do
          path
          |> String.replace_prefix("priv/", "")
          |> Path.expand(dir)
        end
      end

    [cwd_path, priv_path]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp priv_dir do
    case :code.priv_dir(:dev_ide) do
      dir when is_list(dir) -> List.to_string(dir)
      {:error, _} -> nil
    end
  end
end

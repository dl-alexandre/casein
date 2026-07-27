defmodule Casein.Codex.SessionTitles do
  @moduledoc """
  Resolves Codex session ids to short titles from Codex's durable history.

  Codex writes its session id into the pane title, while its foreground
  process remains `node`. The history file is therefore the durable source for
  conversation-aware window labels after Casein or tmux restarts.
  """

  use GenServer

  alias Casein.Labels.Derivation

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec titles([String.t()]) :: %{String.t() => String.t()}
  def titles(session_ids) when is_list(session_ids), do: titles(__MODULE__, session_ids)

  @doc false
  def titles(server, session_ids) when is_list(session_ids) do
    ids =
      session_ids
      |> Enum.filter(&valid_session_id?/1)
      |> MapSet.new()

    if MapSet.size(ids) == 0 do
      %{}
    else
      GenServer.call(server, {:titles, ids})
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       path: Keyword.get(opts, :path, history_path()),
       signature: nil,
       titles: %{}
     }}
  end

  @impl true
  def handle_call({:titles, ids}, _from, state) do
    state = refresh_if_changed(state)
    {:reply, Map.take(state.titles, MapSet.to_list(ids)), state}
  end

  defp refresh_if_changed(state) do
    signature = file_signature(state.path)

    if signature == state.signature do
      state
    else
      %{state | signature: signature, titles: read_titles(state.path)}
    end
  end

  defp file_signature(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {stat.size, stat.mtime}
      {:error, _reason} -> :missing
    end
  end

  defp read_titles(path) do
    path
    |> File.stream!(:line, [])
    |> Enum.reduce(%{}, fn line, titles ->
      with {:ok, %{"session_id" => id, "text" => text}} <- Jason.decode(line),
           true <- valid_session_id?(id),
           title when is_binary(title) <- Derivation.from_agent_label(text) do
        Map.put_new(titles, id, title)
      else
        _ -> titles
      end
    end)
  rescue
    File.Error -> %{}
  end

  defp valid_session_id?(value) when is_binary(value),
    do: Regex.match?(@uuid_pattern, String.trim(value))

  defp valid_session_id?(_value), do: false

  defp history_path do
    codex_home =
      System.get_env("CODEX_HOME") ||
        Path.join(System.get_env("HOME") || System.user_home!(), ".codex")

    Path.join(codex_home, "history.jsonl")
  end
end

defmodule PreviewCtl.Session do
  @moduledoc """
  Runtime orchestration for preview control sessions.

  Origin guards, adapter dispatch, and registry updates live here. Host
  applications attach opaque session metadata (Ecto structs, audit ids, etc.)
  to registry entries.
  """

  alias PreviewCtl.{Origin, Registry}

  @type entry :: map()
  @type session_id :: integer()

  @doc "Fetch a live runtime entry."
  @spec fetch(session_id()) :: {:ok, entry()} | {:error, :not_found}
  def fetch(session_id) when is_integer(session_id) do
    case Registry.get(session_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc "Update adapter state in the registry."
  @spec update_adapter_state(session_id(), map()) :: {:ok, entry()} | {:error, term()}
  def update_adapter_state(session_id, adapter_state) when is_integer(session_id) do
    Registry.update(session_id, fn entry -> %{entry | adapter_state: adapter_state} end)
  end

  @doc "Close the adapter runtime and remove the registry entry."
  @spec close(session_id()) :: {:ok, entry()} | {:error, :not_found}
  def close(session_id) when is_integer(session_id) do
    with {:ok, entry} <- fetch(session_id) do
      _ = entry.adapter_module.close(entry.adapter_state)
      :ok = Registry.delete(session_id)
      {:ok, entry}
    end
  end

  @doc false
  @spec observe(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def observe(session_id) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, observation} <- entry.adapter_module.observe(entry.adapter_state) do
      {:ok, entry, observation}
    end
  end

  @doc false
  @spec observe_live(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def observe_live(session_id) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state, observation} <-
           entry.adapter_module.observe_live(entry.adapter_state),
         {:ok, entry} <-
           commit_state(session_id, entry, adapter_state, observation) do
      {:ok, entry, observation}
    end
  end

  @doc false
  @spec click(session_id(), map()) :: {:ok, entry(), map()} | {:error, term()}
  def click(session_id, target) when is_map(target) do
    with {:ok, entry} <- fetch(session_id),
         :ok <- ensure_target(target),
         {:ok, adapter_state, observation} <-
           entry.adapter_module.click(entry.adapter_state, target) do
      case commit_state(session_id, entry, adapter_state, observation) do
        {:ok, entry} -> {:ok, entry, observation}
        {:error, :origin_not_allowed} -> {:error, {:origin_not_allowed, observation}}
      end
    end
  end

  @doc false
  @spec type(session_id(), String.t(), String.t(), map()) ::
          {:ok, entry(), map()} | {:error, term()}
  def type(session_id, selector, text, opts \\ %{})
      when is_integer(session_id) and is_binary(selector) and is_binary(text) and is_map(opts) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state} <-
           entry.adapter_module.type(entry.adapter_state, selector, text, opts),
         observation <-
           Map.get(adapter_state, :last_observation) || %{selector: selector, text: text},
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, observation) do
      {:ok, entry, observation}
    end
  end

  @doc false
  @spec press(session_id(), String.t(), map()) ::
          {:ok, entry(), map()} | {:error, term()}
  def press(session_id, key, opts \\ %{})
      when is_integer(session_id) and is_binary(key) and is_map(opts) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state} <- entry.adapter_module.press(entry.adapter_state, key, opts),
         observation <- Map.get(adapter_state, :last_observation) || %{key: key},
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, observation) do
      {:ok, entry, observation}
    end
  end

  @doc false
  @spec navigate(session_id(), String.t()) :: {:ok, entry(), map()} | {:error, term()}
  def navigate(session_id, path_or_url) when is_integer(session_id) and is_binary(path_or_url) do
    with {:ok, entry} <- fetch(session_id),
         url <- Origin.resolve_against(path_or_url, current_url(entry)),
         :ok <- ensure_allowed_url(entry, url),
         {:ok, adapter_state, observation} <-
           entry.adapter_module.navigate(entry.adapter_state, url),
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, observation, url) do
      {:ok, entry, observation}
    end
  end

  @doc false
  @spec go_back(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def go_back(session_id) when is_integer(session_id), do: history_action(session_id, :go_back)

  @doc false
  @spec go_forward(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def go_forward(session_id) when is_integer(session_id),
    do: history_action(session_id, :go_forward)

  @doc false
  @spec reload(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def reload(session_id) when is_integer(session_id), do: history_action(session_id, :reload)

  @doc false
  @spec screenshot(session_id()) :: {:ok, entry(), map(), term()} | {:error, term()}
  def screenshot(session_id) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state, observation, artifact} <-
           entry.adapter_module.screenshot(entry.adapter_state),
         {:ok, entry} <-
           Registry.update(session_id, fn e -> %{e | adapter_state: adapter_state} end) do
      {:ok, entry, observation, artifact}
    end
  end

  @doc false
  @spec record_start(session_id(), keyword()) :: {:ok, entry(), map()} | {:error, term()}
  def record_start(session_id, opts) do
    with {:ok, entry} <- fetch(session_id),
         :ok <- ensure_recording_supported(entry),
         {:ok, adapter_state, result} <-
           entry.adapter_module.record_start(entry.adapter_state, opts),
         {:ok, entry} <-
           Registry.update(session_id, fn e -> %{e | adapter_state: adapter_state} end) do
      {:ok, entry, result}
    end
  end

  @doc false
  @spec record_stop(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def record_stop(session_id) do
    with {:ok, entry} <- fetch(session_id),
         :ok <- ensure_recording_supported(entry),
         {:ok, adapter_state, result} <- entry.adapter_module.record_stop(entry.adapter_state),
         {:ok, entry} <-
           Registry.update(session_id, fn e -> %{e | adapter_state: adapter_state} end) do
      {:ok, entry, result}
    end
  end

  defp ensure_recording_supported(entry) do
    if function_exported?(entry.adapter_module, :record_start, 2) and
         function_exported?(entry.adapter_module, :record_stop, 1) do
      :ok
    else
      {:error, :recording_unsupported}
    end
  end

  @doc false
  @spec get_storage(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def get_storage(session_id) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state, storage} <- entry.adapter_module.get_storage(entry.adapter_state),
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, storage) do
      {:ok, entry, storage}
    end
  end

  @doc false
  @spec clear_storage(session_id()) :: {:ok, entry(), map()} | {:error, term()}
  def clear_storage(session_id) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state, storage} <- entry.adapter_module.clear_storage(entry.adapter_state),
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, storage) do
      {:ok, entry, storage}
    end
  end

  @doc "Resolve the configured default adapter module."
  @spec default_adapter() :: module()
  def default_adapter do
    Application.get_env(:preview_ctl, :adapter, PreviewCtl.Test.FakeAdapter)
  end

  @doc "Resolve an adapter atom or module."
  @spec adapter_for(atom() | module() | String.t() | nil) :: module()
  def adapter_for(nil), do: default_adapter()

  def adapter_for(name) when is_binary(name) do
    name |> String.to_existing_atom() |> adapter_for()
  end

  def adapter_for(:playwright), do: PreviewCtl.Playwright.Adapter
  def adapter_for(:memory), do: PreviewCtl.Test.FakeAdapter
  def adapter_for(mod) when is_atom(mod), do: mod

  defp commit_state(session_id, entry, adapter_state, observation, url \\ nil) do
    url =
      url || observation_url(observation) || current_url(%{entry | adapter_state: adapter_state})

    with :ok <- ensure_allowed_url(entry, url) do
      Registry.update(session_id, fn e ->
        e
        |> Map.put(:adapter_state, adapter_state)
        |> Map.put(:current_url, url)
      end)
    end
  end

  defp ensure_allowed_url(entry, url) do
    if Origin.within_origin?(url, base_url(entry), allowed_origins(entry)),
      do: :ok,
      else: {:error, :origin_not_allowed}
  end

  defp ensure_target(%{selector: selector}) when is_binary(selector), do: :ok
  defp ensure_target(%{x: x, y: y}) when is_integer(x) and is_integer(y), do: :ok
  defp ensure_target(%{"selector" => selector}) when is_binary(selector), do: :ok
  defp ensure_target(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y), do: :ok
  defp ensure_target(_), do: {:error, :invalid_target}

  defp history_action(session_id, action) do
    with {:ok, entry} <- fetch(session_id),
         {:ok, adapter_state, observation} <-
           apply(entry.adapter_module, action, [entry.adapter_state]),
         {:ok, entry} <- commit_state(session_id, entry, adapter_state, observation) do
      {:ok, entry, observation}
    end
  end

  defp current_url(entry) do
    Map.get(entry.adapter_state || %{}, :current_url) ||
      Map.get(entry, :current_url) ||
      session_current_url(entry) ||
      base_url(entry)
  end

  defp session_current_url(%{session: %{current_url: url}}) when is_binary(url), do: url
  defp session_current_url(_), do: nil

  defp base_url(%{preview: %{url: url}}) when is_binary(url), do: url
  defp base_url(%{base_url: url}) when is_binary(url), do: url
  defp base_url(%{session: %{current_url: url}}) when is_binary(url), do: url
  defp base_url(_), do: ""

  defp allowed_origins(%{allowed_origins: origins}) when is_list(origins), do: origins
  defp allowed_origins(_), do: Origin.localhost_origins()

  defp observation_url(%{} = observation) do
    Map.get(observation, :url) || Map.get(observation, "url")
  end

  defp observation_url(_), do: nil
end

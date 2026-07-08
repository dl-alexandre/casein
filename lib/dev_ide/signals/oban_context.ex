defmodule DevIDE.Signals.ObanContext do
  @moduledoc false

  alias DevIDE.Signals.Context
  alias Jido.Signal.Trace.Context, as: TraceContext

  @meta_key "signals_context"

  @doc false
  @spec meta_key() :: String.t()
  def meta_key, do: @meta_key

  @doc false
  @spec encode(TraceContext.t() | nil) :: map() | nil
  def encode(nil), do: nil

  def encode(%TraceContext{} = ctx) do
    ctx
    |> TraceContext.to_map()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc false
  @spec decode(term()) :: TraceContext.t() | nil
  def decode(nil), do: nil
  def decode(%TraceContext{} = ctx), do: ctx

  def decode(snapshot) when is_map(snapshot) do
    case TraceContext.from_map(snapshot) do
      {:ok, ctx} -> ctx
      {:error, _} -> nil
    end
  end

  def decode(_), do: nil

  @doc false
  @spec stamp_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def stamp_changeset(%Ecto.Changeset{} = changeset) do
    case encode(Context.snapshot()) do
      nil ->
        changeset

      snapshot ->
        meta =
          changeset
          |> Ecto.Changeset.get_field(:meta, %{})
          |> Map.put(@meta_key, snapshot)

        Ecto.Changeset.put_change(changeset, :meta, meta)
    end
  end

  @doc false
  @spec perform(Oban.Job.t(), (Oban.Job.t() -> term())) :: term()
  def perform(%Oban.Job{} = job, fun) when is_function(fun, 1) do
    Context.with_snapshot(decode(job_meta_snapshot(job)), fn -> fun.(job) end)
  end

  defp job_meta_snapshot(%Oban.Job{meta: meta}) when is_map(meta), do: Map.get(meta, @meta_key)
  defp job_meta_snapshot(_), do: nil
end

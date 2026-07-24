defmodule Casein.Terminals.SessionTemplates do
  @moduledoc false

  alias Casein.Terminals.{SessionTemplate, Templates}
  alias Casein.Terminals.SessionTemplate.Export, as: SessionTemplateExport

  @doc "Lists built-in and, when workspace_id is supplied, saved session template stubs."
  @spec session_templates(String.t() | nil) :: [SessionTemplate.t()]
  def session_templates(workspace_id \\ nil) do
    SessionTemplate.list(workspace_id)
  end

  @doc "Fetches a built-in session template by id."
  @spec get_session_template(String.t()) ::
          {:ok, SessionTemplate.t()} | {:error, :template_not_found}
  def get_session_template(id) do
    SessionTemplate.get(id)
  end

  @doc "Builds a template export from a tmux topology snapshot."
  @spec export_session_template(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def export_session_template(topology, opts \\ []) do
    SessionTemplate.export_topology(topology, opts)
  end

  @doc "Serializes a session template export to YAML."
  @spec session_template_to_yaml(map()) :: String.t()
  def session_template_to_yaml(template) do
    SessionTemplateExport.to_yaml(template)
  end

  @doc "Runs a dry-run plan for a built-in session template."
  @spec dry_run_session_template(String.t() | SessionTemplate.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def dry_run_session_template(template_or_id, opts \\ []) do
    SessionTemplate.dry_run(template_or_id, opts)
  end

  @doc "Executes a built-in session template."
  @spec execute_session_template(String.t(), String.t() | SessionTemplate.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_session_template(session, template_or_id, opts \\ []) do
    SessionTemplate.execute(session, template_or_id, opts)
  end

  @doc "Lists saved session templates for a workspace."
  @spec list_saved_templates(String.t(), keyword()) :: [Templates.saved()]
  def list_saved_templates(workspace_id, opts \\ []) do
    Templates.list_for_workspace(workspace_id, opts)
  end

  @doc "Fetches a saved session template scoped to a workspace."
  @spec get_saved_template(String.t(), String.t()) ::
          {:ok, Templates.saved()} | {:error, :not_found}
  def get_saved_template(workspace_id, id) do
    Templates.get(workspace_id, id)
  end

  @doc "Saves a session template export."
  @spec save_template(map()) :: {:ok, Templates.saved()} | {:error, Ecto.Changeset.t()}
  def save_template(attrs) do
    Templates.save(attrs)
  end

  @doc "Updates a saved session template."
  @spec update_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, Templates.saved()}
          | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
  def update_saved_template(workspace_id, id, attrs, opts \\ []) do
    Templates.update(workspace_id, id, attrs, opts)
  end

  @doc "Duplicates a saved session template."
  @spec duplicate_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, Templates.saved()}
          | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
  def duplicate_saved_template(workspace_id, id, attrs \\ %{}, opts \\ []) do
    Templates.duplicate(workspace_id, id, attrs, opts)
  end

  @doc "Deletes a saved session template."
  @spec delete_saved_template(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_saved_template(workspace_id, id) do
    Templates.delete(workspace_id, id)
  end

  @doc "True when a saved session template can be applied."
  @spec saved_template_apply_supported?(Templates.saved()) :: boolean()
  def saved_template_apply_supported?(saved) do
    Templates.apply_supported?(saved)
  end

  @doc "Dry-runs a saved session template."
  @spec dry_run_saved_template(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def dry_run_saved_template(workspace_id, id, opts \\ []) do
    Templates.dry_run(workspace_id, id, opts)
  end

  @doc "Executes a saved session template."
  @spec execute_saved_template(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_saved_template(workspace_id, session, id, opts \\ []) do
    Templates.execute(workspace_id, session, id, opts)
  end

  @doc "Diffs a saved template against the current tmux topology."
  @spec diff_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def diff_saved_template(workspace_id, id, topology, opts \\ []) do
    Templates.diff(workspace_id, id, topology, opts)
  end

  @doc "Executes a saved template reconciliation plan."
  @spec execute_saved_template_reconcile(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_saved_template_reconcile(workspace_id, session, id, topology, opts \\ []) do
    Templates.execute_reconcile(workspace_id, session, id, topology, opts)
  end
end

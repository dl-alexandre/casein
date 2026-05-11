defmodule DevIdeWeb.API.RunnerController do
  use DevIdeWeb, :controller

  alias DevIDE.Runners

  def poll(conn, params) do
    case Runners.poll(params) do
      {:ok, assignment} ->
        json(conn, %{protocol: Runners.protocol(), assignment: assignment})

      :none ->
        send_resp(conn, :no_content, "")

      {:error, reason} ->
        rejected(conn, :bad_request, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case Runners.replay(id) do
      {:ok, payload} -> json(conn, payload)
      :error -> not_found(conn)
    end
  end

  def report(conn, %{"id" => id} = params) do
    case Runners.append_report(id, Map.delete(params, "id")) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(%{protocol: Runners.protocol(), report: Runners.report_payload(report)})

      {:error, :not_found} ->
        not_found(conn)

      {:error, :claim_token_invalid} ->
        rejected(conn, :forbidden, :claim_token_invalid)

      {:error, :lease_expired} ->
        rejected(conn, :conflict, :lease_expired)

      {:error, :assignment_not_claimed} ->
        rejected(conn, :conflict, :assignment_not_claimed)

      {:error, reason} when reason in [:assignment_terminal, :duplicate_report_conflict] ->
        rejected(conn, :conflict, reason)

      {:error, reason} ->
        rejected(conn, :bad_request, reason)
    end
  end

  def complete(conn, %{"id" => id} = params) do
    terminal(conn, id, Map.delete(params, "id"), &Runners.complete/2)
  end

  def fail(conn, %{"id" => id} = params) do
    terminal(conn, id, Map.delete(params, "id"), &Runners.fail/2)
  end

  defp terminal(conn, id, attrs, fun) do
    case fun.(id, attrs) do
      {:ok, assignment, report} ->
        json(conn, %{
          protocol: Runners.protocol(),
          assignment: Runners.assignment_payload(assignment),
          report: Runners.report_payload(report)
        })

      {:error, :not_found} ->
        not_found(conn)

      {:error, :claim_token_invalid} ->
        rejected(conn, :forbidden, :claim_token_invalid)

      {:error, :lease_expired} ->
        rejected(conn, :conflict, :lease_expired)

      {:error, :assignment_not_claimed} ->
        rejected(conn, :conflict, :assignment_not_claimed)

      {:error, reason} when reason in [:assignment_terminal, :duplicate_report_conflict] ->
        rejected(conn, :conflict, reason)

      {:error, reason} ->
        rejected(conn, :bad_request, reason)
    end
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found", failure_class: DevIDE.Runners.Failure.class(:not_found)})
  end

  defp rejected(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{
      error: to_string(reason),
      failure_class: DevIDE.Runners.Failure.class(reason)
    })
  end
end

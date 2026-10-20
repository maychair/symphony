defmodule SymphonyElixir.Taskboard.Memory do
  @moduledoc """
  In-memory Taskboard fixture provider used by Mock Issue / Mock Agent tests.

  It is selected only by `tracker.kind: memory` and never writes provider data.
  Tests may inject a mutator to observe action requests.
  """

  @behaviour SymphonyElixir.Taskboard.Provider

  alias SymphonyElixir.Tracker.Issue

  @impl true
  def list_issues(_settings, opts) do
    fun = Keyword.get(opts, :issues_fun, fn -> configured_issues() end)

    cond do
      is_function(fun, 0) -> {:ok, fun.()}
      is_function(fun, 1) -> {:ok, fun.([])}
      true -> {:ok, configured_issues()}
    end
  end

  @impl true
  def issue_detail(_settings, identifier, opts) do
    details = configured_details()

    with {:ok, issue} <- find_issue(identifier, opts) do
      detail = Map.get(details, identifier) || Map.get(details, issue.id) || %{}

      payload = %{
        issue: issue,
        description: detail_description(detail, issue),
        labels: Map.get(detail, "labels", issue.labels),
        comments: Map.get(detail, "comments", []),
        deliveries: Map.get(detail, "deliveries", []),
        execution: Map.get(detail, "execution", Keyword.get(opts, :execution)),
        capabilities: %{
          create_issue: true,
          comment: issue.state != "closed",
          dispatch: issue.state != "closed",
          retry: true,
          rework: true,
          accept: true
        }
      }

      payload =
        if Map.has_key?(detail, "runtime_entry") do
          Map.put(payload, :runtime_entry, detail["runtime_entry"])
        else
          payload
        end

      {:ok, payload}
    end
  end

  @impl true
  def delivery_summaries(_settings, %Issue{} = issue, _opts) do
    details = configured_details()
    detail = Map.get(details, issue.identifier) || Map.get(details, issue.id) || %{}
    {:ok, List.wrap(detail["deliveries"] || detail[:deliveries])}
  end

  @impl true
  def create_issue(_settings, attrs, _opts) do
    number = System.unique_integer([:positive])

    result = %{
      "id" => number,
      "identifier" => "MOCK-#{number}",
      "url" => "https://example.invalid/issues/#{number}",
      "title" => attrs["title"]
    }

    mutate({:create_issue, attrs, result})
    {:ok, result}
  end

  @impl true
  def comment(_settings, identifier, body, _opts) do
    result = %{
      id: System.unique_integer([:positive]),
      author: "mock-human",
      body: body,
      system: false,
      engine: false,
      created_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      updated_at: nil,
      url: nil
    }

    case mutate({:comment, identifier, body, result}) do
      {:error, _reason} = error -> error
      _ -> {:ok, result}
    end
  end

  @impl true
  def add_label(_settings, identifier, label, _opts) do
    mutate({:add_label, identifier, label})
    :ok
  end

  @impl true
  def remove_label(_settings, identifier, label, _opts) do
    mutate({:remove_label, identifier, label})
    :ok
  end

  defp find_issue(identifier, opts) do
    case Keyword.get(opts, :issues_fun) do
      fun when is_function(fun, 0) -> find(fun.(), identifier)
      fun when is_function(fun, 1) -> find(fun.([]), identifier)
      _ -> find(configured_issues(), identifier)
    end
  end

  defp find(issues, identifier) do
    case Enum.find(issues, fn
           %Issue{identifier: ^identifier} -> true
           %Issue{id: ^identifier} -> true
           _ -> false
         end) do
      %Issue{} = issue -> {:ok, issue}
      nil -> {:error, :taskboard_issue_not_found}
    end
  end

  defp configured_issues do
    :symphony_elixir
    |> Application.get_env(:memory_tracker_issues, [])
    |> Enum.filter(&match?(%Issue{}, &1))
  end

  defp configured_details do
    Application.get_env(:symphony_elixir, :taskboard_memory_details, %{})
  end

  defp detail_description(detail, issue) do
    Map.get(detail, "description") || Map.get(detail, :description) || issue.description
  end

  defp mutate(event) do
    case Application.get_env(:symphony_elixir, :taskboard_memory_mutator) do
      fun when is_function(fun, 1) -> fun.(event)
      _ -> :ok
    end
  end
end

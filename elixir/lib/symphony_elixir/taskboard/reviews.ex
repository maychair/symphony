defmodule SymphonyElixir.Taskboard.Reviews do
  @moduledoc "Read-only MR/PR cards from the automatic lane, never from manual review journals."
  alias SymphonyElixir.ReviewLane.{GitLab, Listener}
  alias SymphonyElixir.RuntimeContext
  alias SymphonyElixir.Taskboard.Provider
  alias SymphonyElixir.TaskWorkflow

  @spec snapshot() :: {:ok, map()} | {:error, term()}
  def snapshot do
    if RuntimeContext.whereis(Listener), do: Listener.board_snapshot(), else: {:ok, %{config: nil, records: []}}
  catch
    :exit, _ -> {:error, :automatic_review_snapshot_unavailable}
  end

  @spec merge([map()], {:ok, map()} | {:error, term()}) :: {[map()], [map()]}
  def merge(projects, {:ok, %{config: %{"enabled" => true} = config, records: records}}) do
    records
    |> Enum.filter(&in_scope?(&1, config))
    |> Enum.group_by(& &1["project"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({projects, []}, fn {repo, rounds}, {acc, errors} ->
      project = Enum.find(acc, &(&1.local and &1.repo == repo)) || review_project(repo, config)
      cards = rounds |> Enum.group_by(& &1["iid"]) |> Enum.map(fn {_, history} -> card(history, project, config) end) |> Enum.reject(&is_nil/1)
      updated = Map.update(project, :cards, cards, &(&1 ++ cards))
      {Enum.reject(acc, &(&1.id == project.id)) ++ [updated], errors}
    end)
  end

  def merge(projects, {:ok, _disabled}), do: {projects, []}
  def merge(projects, {:error, reason}), do: {projects, [%{project_id: "automatic-reviews", project: "Automatic reviews", error: inspect(reason)}]}

  defp in_scope?(record, config) do
    project = get_in(config, ["projects", record["project"]])
    kind = if config["provider"] == "github", do: "pr", else: "mr"
    path = if kind == "pr", do: "/#{record["project"]}/pull/#{record["iid"]}", else: "/#{record["project"]}/-/merge_requests/#{record["iid"]}"

    repository_id = to_string(project && project["id"])
    native = %{"repository_id" => repository_id, "kind" => kind, "number" => record["iid"]}
    expected_work = Map.merge(Map.take(config, ~w(provider host)), native)

    is_map(project) and record["work"] == expected_work and
      is_integer(record["round"]) and record["round"] > 0 and GitLab.web_url?(record["url"], config, path)
  end

  defp review_project(repo, config) do
    %{
      id: "reviews-" <> TaskWorkflow.digest([config["provider"], config["host"], config["projects"][repo]["id"]]),
      name: repo,
      repo: repo,
      kind: config["provider"],
      local: true,
      write_enabled: false,
      url: nil,
      cards: []
    }
  end

  defp card(history, project, config) do
    history = Enum.sort_by(history, & &1["round"], :desc)
    latest = hd(history)

    if latest["eligibility"] not in ["closed", "merged", "unassigned"] do
      {column, status} = state(latest)
      separator = if config["provider"] == "github", do: "#", else: "!"
      review = round_summary(latest)

      %{
        item_type: "review",
        issue_id: "review:" <> TaskWorkflow.digest(latest["work"]),
        issue_identifier: "Review #{separator}#{latest["iid"]}",
        title: latest["title"] || "Review #{latest["project"]}#{separator}#{latest["iid"]}",
        summary: Provider.summary(text(latest["error"] || get_in(latest, ["workflow_result", "body"]))),
        description: nil,
        priority: nil,
        tracker_state: latest["phase"],
        labels: [],
        url: latest["url"],
        project_id: project.id,
        project: project.name,
        repo: latest["project"],
        kind: config["provider"],
        column: column,
        agent_status: status,
        needs_human: column == "Human Review",
        runtime: nil,
        delivery: nil,
        artifacts: review.artifacts,
        projection: nil,
        human_action: %{required: column == "Human Review", summary: guidance(column, status)},
        review: Map.put(review, :history, Enum.map(history, &round_summary/1)),
        updated_at: latest["updated_at"] || latest["created_at"],
        created_at: latest["created_at"]
      }
    end
  end

  defp state(record) do
    cond do
      record["eligibility"] != "current" -> {"Human Review", "blocked"}
      record["phase"] == "queued" -> {"Todo", "queued"}
      record["phase"] == "running" -> {"In Progress", "running"}
      record["phase"] == "completed" and record["native_stop_confirmed"] == true and is_map(record["workflow_result"]) -> {"Done", "workflow completed"}
      true -> {"Human Review", "workflow incomplete"}
    end
  end

  defp round_summary(record) do
    result = record["workflow_result"] || %{}

    %{
      round: record["round"],
      head: record["head"],
      base: record["base"],
      target_branch: record["target_branch"],
      phase: record["phase"],
      conclusion: text(result["status"]) || "incomplete",
      artifacts: for(%{"url" => url} = artifact <- List.wrap(result["artifacts"]), is_binary(url), do: %{kind: "review", label: text(artifact["label"]) || "Review report", url: url})
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp guidance("Done", _status), do: "本轮工作流已结束；审查结论及交付情况见 Agent 结果。"
  defp guidance("Human Review", status), do: "自动审查需要处理：#{status}。"
  defp guidance(_column, _status), do: "按现有自动审查规则执行。"
end

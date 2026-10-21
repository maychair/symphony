defmodule SymphonyElixir.Taskboard.Reviews do
  @moduledoc "Read-only MR/PR cards from the automatic lane, never from manual review journals."
  alias SymphonyElixir.ReviewLane.{GitLab, Listener, Publication}
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
      {column, status} = state(latest, config)
      separator = if config["provider"] == "github", do: "#", else: "!"
      review = round_summary(latest, config)

      %{
        item_type: "review",
        issue_id: "review:" <> TaskWorkflow.digest(latest["work"]),
        issue_identifier: "Review #{separator}#{latest["iid"]}",
        title: latest["title"] || "Review #{latest["project"]}#{separator}#{latest["iid"]}",
        summary: Provider.summary(latest["error"] || latest["publication_error"] || get_in(latest, ["review_result", "body"])),
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
        review: Map.put(review, :history, Enum.map(history, &round_summary(&1, config))),
        updated_at: latest["updated_at"] || latest["created_at"],
        created_at: latest["created_at"]
      }
    end
  end

  defp state(record, config) do
    cond do
      record["eligibility"] != "current" -> {"Human Review", "blocked"}
      record["publication_error"] != nil -> {"Human Review", "publication unconfirmed"}
      record["phase"] == "queued" -> {"Todo", "queued"}
      record["phase"] in ["running", "publishing"] -> {"In Progress", record["phase"]}
      completed?(record, config) -> {"Done", "review completed"}
      true -> {"Human Review", "review incomplete"}
    end
  end

  defp completed?(record, config) do
    complete_result?(record) and confirmed_publication?(record, config)
  end

  defp complete_result?(record) do
    result = record["review_result"]

    record["phase"] == "completed" and record["review_protocol"] == 3 and is_map(result) and
      result["status"] in ["passed", "changes_requested"] and
      Enum.all?(~w(head base policy_sha), &(record[&1] == result[&1])) and record["native_stop_confirmed"] == true
  end

  defp confirmed_publication?(record, config) do
    publication = record["publication"]
    proof = %{"head" => record["head"], "base" => record["base"], "target_branch" => record["target_branch"], "publication_sha" => TaskWorkflow.digest(publication)}

    is_map(publication) and record["review_completion"] == proof and
      Publication.valid?(record, config["publisher_id"]) and publication["entries"] != [] and
      Enum.all?(publication["entries"], &(&1["status"] == "published" and is_map(&1["receipt"])))
  end

  defp round_summary(record, config) do
    %{
      round: record["round"],
      head: record["head"],
      base: record["base"],
      target_branch: record["target_branch"],
      phase: record["phase"],
      conclusion: get_in(record, ["review_result", "status"]) || "incomplete",
      artifacts: artifacts(record, config)
    }
  end

  defp artifacts(record, config) do
    if is_map(record["publication"]) and Publication.valid?(record, config["publisher_id"]) do
      for entry <- record["publication"]["entries"], entry["status"] == "published", is_map(entry["receipt"]) do
        report_link(record, entry["receipt"])
      end
    else
      []
    end
  end

  defp report_link(record, receipt) do
    anchor = if record["work"]["provider"] == "github", do: "pullrequestreview-" <> String.replace_prefix(receipt["discussion_id"], "pull_review_", ""), else: "note_#{receipt["note_id"]}"
    %{kind: "review", label: "Review report · round #{record["round"]}", url: record["url"] <> "#" <> anchor}
  end

  defp guidance("Done", _status), do: "本轮审查及结论发布已完成；具体问题与建议见审查报告。"
  defp guidance("Human Review", status), do: "自动审查需要处理：#{status}。"
  defp guidance(_column, _status), do: "按现有自动审查规则执行。"
end

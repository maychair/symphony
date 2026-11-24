defmodule SymphonyElixir.ReviewLane.WaitNotice do
  @moduledoc "Render and read back a native GitLab Review status notice."
  alias SymphonyElixir.ReviewLane.GitLab
  alias SymphonyElixir.{TaskReconciler, TaskWorkflow, WaitNotice}

  @marker ~r/
<!-- symphony-review-wait:([a-f0-9]{64}) -->
<!-- symphony-engine-notice -->\z/

  @spec pending?(map(), map()) :: boolean()
  def pending?(%{"provider" => "gitlab"} = config, %{"phase" => "failed", "native_stop_confirmed" => true, "workflow_result" => %{"status" => "needs_input"}} = record) do
    config["publish_results"] != false and record["wait_notice"]["state"] != "confirmed"
  end

  def pending?(_, _), do: false

  @spec status_note?(map()) :: boolean()
  def status_note?(%{"body" => body} = note) when is_binary(body),
    do: TaskReconciler.engine_notice?(note) and Regex.match?(@marker, String.trim_trailing(body))

  def status_note?(_), do: false

  @spec prepare(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(config, record, mr) do
    reviewer = Enum.find(mr["reviewers"], &(&1["id"] == config["reviewer_id"]))
    result = record["workflow_result"]
    axes = if is_map(result["axes"]), do: Map.values(result["axes"]), else: []
    gaps = for %{"gaps" => gaps} <- axes, gap <- List.wrap(gaps), do: gap
    gaps = gaps |> safe_lines() |> Enum.sort()
    findings = result["findings"] |> List.wrap() |> Enum.flat_map(&finding/1) |> safe_lines()

    with name when is_binary(name) <- username(reviewer),
         [_ | _] <- gaps do
      key = TaskWorkflow.digest([record["work"], record["round"], Enum.sort(Enum.map(gaps, &String.downcase/1))])
      owners = mr["assignees"] |> List.wrap() |> Enum.map(&username/1) |> Enum.reject(&is_nil/1)
      owner = if owners == [], do: "MR 作者", else: Enum.map_join(owners, "、", &("@" <> &1))
      found = if findings == [], do: "本轮没有可公开的已确认发现。", else: bullets(findings)

      body =
        """
        @#{name} **Symphony 自动审查暂待补充证据**

        MR !#{record["iid"]} · 第 #{record["round"]} 轮 · `#{String.slice(record["head"], 0, 8)}`

        **已确认的发现**
        #{found}

        **待补证据**
        #{bullets(gaps)}

        **责任人**　#{owner}。请补齐上述证据并在此 MR 留下可核对的结果，由 reviewer 重新发起复审。

        <!-- symphony-review-wait:#{key} -->
        #{TaskReconciler.engine_notice_marker()}
        """
        |> String.trim_trailing()

      {:ok, %{"key" => key, "body" => body, "state" => "sending", "publisher_id" => config["publisher_id"]}}
    else
      _ -> {:error, :review_wait_notice_missing_public_details}
    end
  end

  @spec check(map(), String.t(), map()) :: {:ok, map() | nil} | {:error, term()}
  def check(config, path, notice) do
    with {:ok, discussions} <- GitLab.discussions(config, path) do
      notes = Enum.flat_map(discussions, &List.wrap(&1["notes"]))
      {:ok, WaitNotice.find(notes, &matches?(&1, notice))}
    end
  end

  @spec validate_sender(map(), map()) :: :ok | {:error, term()}
  def validate_sender(config, notice) do
    publisher = config["publisher_id"]

    with true <- GitLab.comment_body?(notice["body"]) or {:error, :review_wait_notice_unsafe_body},
         {:ok, %{"id" => ^publisher}} <- GitLab.request(config, "GET", "user") do
      :ok
    else
      _ -> {:error, :review_wait_notice_sender_unverified}
    end
  end

  @spec post(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post(config, path, notice) do
    with {:ok, _} <- GitLab.request(config, "POST", path <> "/discussions", %{"body" => notice["body"]}),
         {:ok, %{} = note} <- check(config, path, notice) do
      {:ok, note}
    else
      _ -> {:error, :review_wait_notice_unconfirmed}
    end
  end

  defp matches?(%{"id" => id, "body" => body, "author" => %{"id" => author}} = note, %{"publisher_id" => author} = notice)
       when is_integer(id) and is_binary(body),
       do: status_note?(note) and String.trim_trailing(body) == notice["body"]

  defp matches?(_, _), do: false

  defp username(%{"username" => name}) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/, name), do: name
  end

  defp username(_), do: nil

  defp finding(%{"criterion" => title, "location" => location, "impact" => impact, "resolution" => resolution})
       when is_binary(title) and is_binary(location) and is_binary(impact) and is_binary(resolution),
       do: ["#{title}（#{location}）。#{impact} 修改建议：#{resolution}"]

  defp finding(_), do: []

  defp safe_lines(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.replace(String.trim(&1), ~r/\s+/u, " "))
    |> Enum.reject(&unsafe?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp unsafe?(line) do
    line == "" or
      Regex.match?(
        ~r"https?://|file://|/(?:home|Users|tmp|private|var/tmp)/|[<>@]|(?<![A-Za-z0-9_./-])/\S|~/|\$\{?HOME|[A-Za-z]:[\\/]|(?<![A-Za-z0-9_./-])(?:\.\./|\.codex/|\.agents/|(?:Worktrees|Workspace|Projects|Tools|Tmp|State|Builds)/)"iu,
        line
      )
  end

  defp bullets(lines), do: Enum.map_join(lines, "\n", &("- " <> &1))
end

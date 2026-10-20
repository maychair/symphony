defmodule SymphonyElixir.ReviewWorkflow do
  @moduledoc "The single manual/automatic review pipeline; exactly two independent axes and one result reducer."
  alias SymphonyElixir.{ReviewAxis, ReviewResult, RuntimeContext, TaskWorkflow}
  @axes ["standards", "spec"]

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(context, opts \\ []) do
    if cancelled?(), do: {:error, :scheduler_stop}, else: run_current(context, opts)
  after
    Process.delete({__MODULE__, :cancelled})
  end

  defp run_current(context, opts) do
    with {:ok, rules, digest, models} <- load_rules(context.config),
         true <- context.record["policy_sha"] in [nil, digest] || {:error, :review_policy_changed},
         {:ok, checkpoint} <- checkpoint_option(opts) do
      record = Map.put(context.record, "policy_sha", digest)
      context = context |> Map.put(:record, record) |> Map.put(:rules, rules) |> Map.put(:models, models)
      :ok = checkpoint.(%{"review_protocol" => 2, "policy_sha" => digest})
      parent = self()
      {:ok, supervisor} = Task.Supervisor.start_link()
      runner = Keyword.get(opts, :axis_runner, fn axis, ctx, event -> ReviewAxis.run(axis, ctx, event, opts) end)

      deadline = Keyword.get(opts, :deadline) || System.monotonic_time(:millisecond) + 3_600_000
      tasks = Map.new(@axes, &start_axis(&1, supervisor, parent, runner, context, deadline))

      try do
        axes = collect(tasks, %{}, checkpoint, deadline)
        :ok = checkpoint.(%{"axes" => axes})
        if cancelled?(), do: {:error, {:scheduler_stop, axes}}, else: ReviewResult.aggregate(record, axes)
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  defp checkpoint_option(opts) do
    case Keyword.fetch(opts, :checkpoint) do
      {:ok, checkpoint} when is_function(checkpoint, 1) -> {:ok, checkpoint}
      _ -> {:error, :review_checkpoint_required}
    end
  end

  @spec rules(map()) :: {:ok, map(), String.t()} | {:error, term()}
  def rules(config) do
    case load_rules(config) do
      {:ok, rules, sha, _models} -> {:ok, rules, sha}
      error -> error
    end
  end

  defp load_rules(config) do
    with path when is_binary(path) <- config["policy_file"] || config["instructions_file"],
         {:ok, body} <- File.read(path),
         sections = Regex.split(~r/^## (Common|Standards|Spec)\s*$/m, body, include_captures: true),
         true <- length(sections) == 7,
         rules = sections |> Enum.drop(1) |> Enum.chunk_every(2) |> Map.new(fn [heading, text] -> {heading |> String.trim() |> String.replace_prefix("## ", ""), text} end),
         true <- Enum.sort(Map.keys(rules)) == ["Common", "Spec", "Standards"] and Enum.all?(rules, fn {_, text} -> String.trim(text) != "" end) do
      models = role_settings(config)
      {:ok, rules, policy_digest(body, models), models}
    else
      _ -> {:error, :shared_review_policy_unavailable}
    end
  rescue
    _ -> {:error, :shared_review_policy_unavailable}
  end

  @spec role_settings(map()) :: map()
  def role_settings(config) do
    files = config["role_files"] || %{}
    if map_size(files) > 0 and Enum.sort(Map.keys(files)) != Enum.sort(@axes), do: raise(ArgumentError, "two review roles required")

    Map.new(files, fn {axis, path} ->
      body = File.read!(path)

      fields =
        Map.new(["model", "model_reasoning_effort"], fn key ->
          [_, value] = Regex.run(Regex.compile!("^" <> key <> " = \"([^\"]+)\"$", "m"), body)
          {key, value}
        end)

      {axis, fields}
    end)
  end

  defp policy_digest(body, roles) when map_size(roles) == 0, do: TaskWorkflow.digest(body)
  defp policy_digest(body, roles), do: TaskWorkflow.digest(%{"rules" => body, "roles" => roles})

  defp start_axis(axis, supervisor, parent, runner, context, deadline) do
    event = fn changes -> relay(parent, axis, changes, deadline) end
    action = RuntimeContext.wrap(fn -> runner.(axis, context, event) end)
    task = Task.Supervisor.async_nolink(supervisor, action)
    {task.ref, {axis, task}}
  end

  defp relay(parent, axis, changes, deadline) do
    ref = make_ref()
    send(parent, {:review_axis_checkpoint, self(), ref, axis, changes})

    receive do
      {^ref, reply} -> reply
    after
      min(max(deadline - System.monotonic_time(:millisecond), 0), 30_000) -> exit(:review_checkpoint_timeout)
    end
  end

  defp collect(tasks, axes, _checkpoint, _deadline) when map_size(tasks) == 0, do: axes

  defp collect(tasks, axes, checkpoint, deadline) do
    receive do
      {:review_axis_checkpoint, pid, ref, axis, changes} ->
        authorized = Enum.any?(tasks, fn {_, {name, task}} -> name == axis and task.pid == pid end)

        if authorized and allocation?(changes) and cancelled?() do
          Enum.each(tasks, fn {_, {_, task}} -> send(task.pid, :symphony_stop) end)
          send(pid, {ref, {:error, :scheduler_stop}})
          collect(tasks, axes, checkpoint, deadline)
        else
          checkpoint_axis(authorized, tasks, axes, checkpoint, deadline, {pid, ref, axis, changes})
        end

      {ref, result} when is_reference(ref) and is_map_key(tasks, ref) ->
        {axis, _task} = tasks[ref]
        Process.demonitor(ref, [:flush])
        next = Map.put(axes, axis, Map.merge(axes[axis] || %{}, result))
        :ok = checkpoint.(%{"axes" => next})
        collect(Map.delete(tasks, ref), next, checkpoint, deadline)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(tasks, ref) ->
        {axis, _task} = tasks[ref]
        next = Map.put(axes, axis, ReviewAxis.halt(failed(axes[axis], reason)))
        :ok = checkpoint.(%{"axes" => next})
        collect(Map.delete(tasks, ref), next, checkpoint, deadline)

      :symphony_stop ->
        Process.put({__MODULE__, :cancelled}, true)
        Enum.each(tasks, fn {_, {_, task}} -> send(task.pid, :symphony_stop) end)
        collect(tasks, axes, checkpoint, min(deadline, System.monotonic_time(:millisecond) + 30_000))
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Enum.reduce(tasks, axes, fn {_, {axis, task}}, acc ->
          Task.shutdown(task, :brutal_kill)
          Map.put(acc, axis, ReviewAxis.halt(failed(acc[axis], :review_timeout)))
        end)
    end
  end

  defp checkpoint_axis(true, tasks, axes, checkpoint, deadline, {pid, ref, axis, changes}) do
    next = Map.update(axes, axis, changes, &Map.merge(&1, changes))

    case checkpoint.(%{"axes" => next}) do
      :ok ->
        send(pid, {ref, :ok})
        collect(tasks, next, checkpoint, deadline)

      {:error, _} = error ->
        Process.put({__MODULE__, :cancelled}, true)
        Enum.each(tasks, fn {_, {_, task}} -> send(task.pid, :symphony_stop) end)
        send(pid, {ref, error})
        collect(tasks, axes, checkpoint, deadline)
    end
  end

  defp checkpoint_axis(false, tasks, axes, checkpoint, deadline, _message),
    do: collect(tasks, axes, checkpoint, deadline)

  defp allocation?(changes), do: changes["thread_allocation_intent"] == true or changes["turn_allocation_intent"] == true

  defp cancelled? do
    receive do
      :symphony_stop ->
        Process.put({__MODULE__, :cancelled}, true)
        true
    after
      0 -> Process.get({__MODULE__, :cancelled}) == true
    end
  end

  defp failed(axis, reason),
    do:
      Map.merge(Map.merge(%{"thread_id" => nil, "turn_id" => nil}, axis || %{}), %{
        "status" => "failed",
        "report" => "审查未完成：#{inspect(reason)}",
        "findings" => [],
        "responses" => [],
        "reads_verified" => false,
        "native_stop_confirmed" => false
      })
end

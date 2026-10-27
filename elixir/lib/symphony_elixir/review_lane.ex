defmodule SymphonyElixir.ReviewLane do
  alias SymphonyElixir.RuntimeContext
  @moduledoc "Native repository review discovery using the existing Orchestrator admission and capacity."

  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(config())

  @spec config() :: map() | nil
  def config do
    case SymphonyElixir.Config.settings() do
      {:ok, %{tracker: %{provider: %{"review_lane" => %{"enabled" => true} = config}}}} -> resolve(config)
      _ -> nil
    end
  end

  @spec job?(SymphonyElixir.Tracker.Issue.t()) :: boolean()
  def job?(%{id: "review:" <> _, native_ref: %{"execution_kind" => "review_lane"}}), do: true
  def job?(_issue), do: false

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{provider: %{"mail_review" => %{"enabled" => true}}}), do: {:error, :mail_review_retired_migration_required}

  def validate_config(%{provider: %{"review_lane" => %{"enabled" => true} = raw}}) do
    config = resolve(raw)

    allowed =
      ~w(enabled disabled publish_results provider host reviewer_id publisher_id projects state_dir poll_interval_ms instruction_files result_command model_settings glab_bin gh_bin allow_insecure_http webhook_secret)

    checks = [
      {Enum.all?(Map.keys(config), &(&1 in allowed)), :unknown_review_configuration},
      {is_boolean(Map.get(config, "disabled", false)), :review_lane_disabled_boolean_required},
      {is_boolean(Map.get(config, "publish_results", true)), :review_lane_publish_results_boolean_required},
      {config["provider"] in ["gitlab", "github"], :review_lane_provider_unsupported},
      {valid_host?(config["host"]), :review_lane_host_required},
      {positive?(config["reviewer_id"]), :review_lane_reviewer_id_required},
      {positive?(config["publisher_id"]), :review_lane_publisher_id_required},
      {nonempty_map?(config["projects"]), :review_lane_projects_required},
      {valid_projects?(config["projects"]), :review_lane_invalid_projects},
      {absolute_path?(config["state_dir"]), :review_lane_absolute_state_required},
      {positive?(Map.get(config, "poll_interval_ms", 60_000)), :review_lane_poll_interval_required},
      {is_nil(config["result_command"]) or command?(config["result_command"]), :invalid_workflow_result_command},
      {model_settings?(config["model_settings"] || %{}), :invalid_workflow_model_settings}
    ]

    case Enum.find(checks, fn {valid, _reason} -> not valid end) do
      nil -> validate_rules(config)
      {false, reason} -> {:error, reason}
    end
  end

  def validate_config(_settings), do: :ok

  defp validate_rules(config) do
    case SymphonyElixir.WorkflowInstructions.load(config) do
      {:ok, _rules, _sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_host?(host), do: is_binary(host) and Regex.match?(~r/^[a-zA-Z0-9.-]+$/, host)
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty_map?(value), do: is_map(value) and map_size(value) > 0
  defp absolute_path?(value), do: is_binary(value) and Path.type(value) == :absolute

  defp model_settings?(settings) when is_map(settings) do
    Enum.all?(settings, fn {key, value} -> key in ~w(model model_reasoning_effort) and is_binary(value) and value != "" end)
  end

  defp model_settings?(_), do: false

  defp command?([executable | args]), do: is_binary(executable) and executable != "" and Enum.all?(args, &is_binary/1)
  defp command?(_), do: false
  defp valid_projects?(projects) when is_map(projects), do: Enum.all?(projects, &valid_project?/1)
  defp valid_projects?(_projects), do: false

  defp valid_project?({project, %{"id" => id}}) when is_binary(project) do
    Regex.match?(~r{^[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+$}, project) and
      positive?(id)
  end

  defp valid_project?(_project), do: false

  @spec resolve(term()) :: term()
  def resolve("$" <> name), do: RuntimeContext.get_env(name)
  def resolve(value) when is_map(value), do: Map.new(value, fn {key, entry} -> {key, resolve(entry)} end)
  def resolve(value) when is_list(value), do: Enum.map(value, &resolve/1)
  def resolve(value), do: value

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings) do
    Enum.uniq(
      ["GLAB_TOKEN"] ++
        SymphonyElixir.GitLab.Client.secret_environment_names(settings) ++
        SymphonyElixir.GitHub.Client.secret_environment_names(settings)
    )
  end
end

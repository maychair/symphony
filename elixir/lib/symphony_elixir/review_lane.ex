defmodule SymphonyElixir.ReviewLane do
  @moduledoc "Native repository review discovery using the existing Orchestrator admission and capacity."
  alias SymphonyElixir.ReviewLane.Listener

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

    checks = [
      {config["provider"] == "gitlab", :review_lane_provider_unsupported},
      {valid_host?(config["host"]), :review_lane_host_required},
      {positive?(config["reviewer_id"]), :review_lane_reviewer_id_required},
      {positive?(config["publisher_id"]), :review_lane_publisher_id_required},
      {nonempty_map?(config["projects"]), :review_lane_projects_required},
      {valid_projects?(config["projects"]), :review_lane_invalid_projects},
      {absolute_path?(config["state_dir"]), :review_lane_absolute_state_required},
      {positive?(Map.get(config, "poll_interval_ms", 60_000)), :review_lane_poll_interval_required},
      {instructions_file?(config["instructions_file"]), :review_lane_instructions_file_required}
    ]

    case Enum.find(checks, fn {valid, _reason} -> not valid end) do
      nil -> :ok
      {false, reason} -> {:error, reason}
    end
  end

  def validate_config(_settings), do: :ok

  defp valid_host?(host), do: is_binary(host) and Regex.match?(~r/^[a-zA-Z0-9.-]+$/, host)
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty_map?(value), do: is_map(value) and map_size(value) > 0
  defp absolute_path?(value), do: is_binary(value) and Path.type(value) == :absolute
  defp instructions_file?(path), do: absolute_path?(path) and File.regular?(path)
  defp valid_projects?(projects) when is_map(projects), do: Enum.all?(projects, &valid_project?/1)
  defp valid_projects?(_projects), do: false

  defp valid_project?({project, %{"checkout" => checkout, "id" => id}}) when is_binary(project) do
    Regex.match?(~r{^[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+$}, project) and
      positive?(id) and absolute_path?(checkout) and File.dir?(checkout)
  end

  defp valid_project?(_project), do: false

  @spec binding() :: map()
  def binding do
    %{
      adapter: __MODULE__,
      tracker_settings: %{},
      tool_specs: agent_tool_specs(),
      secret_environment_names: secret_environment_names(%{}),
      agent_environment: %{}
    }
  end

  @spec resolve(term()) :: term()
  def resolve("$" <> name), do: System.get_env(name)
  def resolve(value) when is_map(value), do: Map.new(value, fn {key, entry} -> {key, resolve(entry)} end)
  def resolve(value) when is_list(value), do: Enum.map(value, &resolve/1)
  def resolve(value), do: value

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_settings), do: ["GITLAB_TOKEN", "GLAB_TOKEN"]

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    [
      %{
        "name" => "review_submit",
        "description" =>
          "Submit substantiated Chinese findings; the scheduler validates the fixed MR head and posts discussions. An empty list explicitly completes a no-findings review. Do not include slash-command lines, even in examples.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["findings"],
          "properties" => %{"findings" => %{"type" => "array", "maxItems" => 50, "items" => %{"type" => "string", "maxLength" => 16_384}}}
        }
      }
    ]
  end

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool("review_submit", arguments, opts) do
    result = Listener.submit(opts[:issue].id, arguments)
    output = Jason.encode!(%{"result" => inspect(result)})
    %{"success" => result == :ok, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  def execute_agent_tool(_tool, _arguments, _opts), do: %{"success" => false, "output" => "Unsupported review tool", "contentItems" => []}
end

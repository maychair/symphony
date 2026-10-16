defmodule SymphonyElixir.MailReview do
  @moduledoc "Opt-in review-only tracker lane using the existing Orchestrator admission and capacity."
  alias SymphonyElixir.MailReview.Listener

  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(config())

  @spec config() :: map() | nil
  def config do
    case SymphonyElixir.Config.settings() do
      {:ok, %{tracker: %{provider: %{"mail_review" => %{"enabled" => true} = config}}}} -> resolve(config)
      _ -> nil
    end
  end

  @spec job?(SymphonyElixir.Tracker.Issue.t()) :: boolean()
  def job?(%{id: "mail-review:" <> _, native_ref: %{"execution_kind" => "mail_review"}}), do: true
  def job?(_issue), do: false

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{provider: %{"mail_review" => %{"enabled" => true} = raw}}) do
    config = resolve(raw)

    cond do
      not (is_binary(config["host"]) and Regex.match?(~r/^[a-zA-Z0-9.-]+$/, config["host"])) ->
        {:error, :mail_review_host_required}

      not (is_binary(config["username"]) and config["username"] != "") ->
        {:error, :mail_review_username_required}

      not (is_map(config["projects"]) and map_size(config["projects"]) > 0) ->
        {:error, :mail_review_projects_required}

      not Enum.all?(config["projects"], fn {project, options} ->
        Regex.match?(~r{^[a-zA-Z0-9_.-]+(?:/[a-zA-Z0-9_.-]+)+$}, project) and is_map(options) and
          is_binary(options["checkout"]) and Path.type(options["checkout"]) == :absolute and File.dir?(options["checkout"])
      end) ->
        {:error, :mail_review_invalid_projects}

      not Enum.all?(["state_dir"], &(is_binary(config[&1]) and Path.type(config[&1]) == :absolute)) ->
        {:error, :mail_review_absolute_state_required}

      not (is_list(config["reviewer_names"]) and config["reviewer_names"] != [] and Enum.all?(config["reviewer_names"], &(is_binary(&1) and &1 != ""))) ->
        {:error, :mail_review_names_required}

      not (is_list(config["mail_senders"]) and config["mail_senders"] != []) ->
        {:error, :mail_review_senders_required}

      not (is_binary(config["instructions_file"]) and Path.type(config["instructions_file"]) == :absolute and File.regular?(config["instructions_file"])) ->
        {:error, :mail_review_instructions_file_required}

      true ->
        :ok
    end
  end

  def validate_config(_settings), do: :ok

  @spec binding() :: map()
  def binding do
    %{adapter: __MODULE__, tracker_settings: %{}, tool_specs: agent_tool_specs(), secret_environment_names: secret_environment_names(%{}), agent_environment: %{}}
  end

  @spec resolve(term()) :: term()
  def resolve("$" <> name), do: System.get_env(name)
  def resolve(value) when is_map(value), do: Map.new(value, fn {key, entry} -> {key, resolve(entry)} end)
  def resolve(value) when is_list(value), do: Enum.map(value, &resolve/1)
  def resolve(value), do: value

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_settings), do: ["GITLAB_TOKEN", "GLAB_TOKEN", "LARK_USER_ACCESS_TOKEN", "LARK_APP_SECRET"]

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    [
      %{
        "name" => "mail_review_submit",
        "description" => "Submit substantiated Chinese findings; the scheduler validates the fixed MR head and posts discussions. An empty list explicitly completes a no-findings review.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["findings"],
          "properties" => %{"findings" => %{"type" => "array", "maxItems" => 50, "items" => %{"type" => "string", "maxLength" => 16384}}}
        }
      }
    ]
  end

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool("mail_review_submit", arguments, opts) do
    result = Listener.submit(opts[:issue].id, arguments)
    output = Jason.encode!(%{"result" => inspect(result)})
    %{"success" => result == :ok, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  def execute_agent_tool(_tool, _arguments, _opts), do: %{"success" => false, "output" => "Unsupported review tool", "contentItems" => []}
end

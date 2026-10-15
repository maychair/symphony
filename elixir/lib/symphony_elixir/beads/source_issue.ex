defmodule SymphonyElixir.Beads.SourceIssue do
  @moduledoc "Bounded, explicit source Issue closure after verified delivery acceptance."

  alias SymphonyElixir.Beads.Repository

  @spec read(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(settings, url) do
    with {:ok, source} <- source(settings, url),
         {:ok, issue} <- fetch(source),
         true <- issue_url(source, issue) == url || {:error, :source_issue_identity_mismatch} do
      {:ok, %{closed: closed?(source, issue), raw: issue}}
    end
  end

  @spec close(map(), String.t()) :: :ok | {:error, term()}
  def close(settings, url) do
    with {:ok, source} <- source(settings, url),
         {:ok, issue} <- fetch(source),
         true <- issue_url(source, issue) == url || {:error, :source_issue_identity_mismatch} do
      close_and_confirm(source, issue)
    end
  end

  defp source(settings, url) do
    configured = resolve(settings.provider["review_repository"])

    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path, query: nil, fragment: nil} ->
        github_source(path, configured)

      %URI{host: host, path: path} ->
        if Repository.gitlab_url?(settings, url), do: gitlab_source(path, configured, host), else: {:error, :invalid_source_issue_reference}

      _ ->
        {:error, :invalid_source_issue_reference}
    end
  end

  defp github_source(path, configured) do
    case Regex.run(~r{^/([^/]+/[^/]+)/issues/(\d+)$}, path) do
      [_, project, number] ->
        if configured == "github.com/" <> project do
          get = ["issue", "view", number, "--repo", project, "--json", "state,url"]
          close = ["issue", "close", number, "--repo", project]
          {:ok, %{provider: "github", bin: "gh", get: get, close: close}}
        else
          {:error, :source_issue_outside_configured_repository}
        end

      _ ->
        {:error, :invalid_source_issue_reference}
    end
  end

  defp gitlab_source(path, configured, host) do
    case Regex.run(~r{^/(.+)/-/issues/(\d+)$}, path) do
      [_, project, number] ->
        if configured == host <> "/" <> project do
          endpoint = "projects/" <> URI.encode_www_form(project) <> "/issues/" <> number
          {:ok, %{provider: "gitlab", bin: "glab", get: ["api", "--hostname", host, endpoint], close: ["api", "--hostname", host, "--method", "PUT", endpoint, "-f", "state_event=close"]}}
        else
          {:error, :source_issue_outside_configured_repository}
        end

      _ ->
        {:error, :invalid_source_issue_reference}
    end
  end

  defp close_and_confirm(source, issue) do
    if closed?(source, issue) do
      :ok
    else
      with {:ok, _} <- command(source.bin, source.close),
           {:ok, confirmed} <- fetch(source),
           true <- closed?(source, confirmed) || {:error, :source_issue_not_confirmed_closed} do
        :ok
      end
    end
  end

  defp fetch(source) do
    with {:ok, output} <- command(source.bin, source.get), do: Jason.decode(output)
  end

  defp command(bin, args) do
    task = Task.async(fn -> run(bin, args) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, error}} -> {:error, {:source_issue_request_failed, error}}
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {_output, status}} -> {:error, {:source_issue_request_failed, status}}
      nil -> {:error, :source_issue_request_timeout}
    end
  end

  defp run(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: false)
  rescue
    error in [ErlangError, ArgumentError] -> {:error, Exception.message(error)}
  end

  defp closed?(%{provider: "github"}, issue), do: issue["state"] == "CLOSED"
  defp closed?(%{provider: "gitlab"}, issue), do: issue["state"] == "closed"
  defp issue_url(%{provider: "github"}, issue), do: issue["url"]
  defp issue_url(%{provider: "gitlab"}, issue), do: issue["web_url"]
  defp resolve("$" <> name), do: System.get_env(name)
  defp resolve(value), do: value
end

defmodule SymphonyElixir.Beads.Repository do
  @moduledoc "Explicit remote repository and self-managed GitLab web origin binding."

  @spec resolve(term()) :: term()
  def resolve("$" <> key), do: System.get_env(key)
  def resolve(value), do: value

  @spec gitlab_origin(map()) :: String.t()
  def gitlab_origin(settings), do: resolve(settings.provider["gitlab_web_url"]) || "https://gitlab.com"

  @spec gitlab_url?(map(), String.t()) :: boolean()
  def gitlab_url?(settings, url) do
    expected = URI.parse(gitlab_origin(settings))
    actual = URI.parse(url)

    valid_origin = expected.scheme in ["http", "https"] and is_binary(expected.host)
    clean_origin = Enum.all?([expected.userinfo, expected.query, expected.fragment], &is_nil/1)
    clean_url = Enum.all?([actual.userinfo, actual.query, actual.fragment], &is_nil/1)
    same_origin = {actual.scheme, actual.host, actual.port} == {expected.scheme, expected.host, expected.port}
    valid_origin and clean_origin and clean_url and same_origin and expected.path in [nil, "", "/"]
  end

  @spec review_repository(String.t()) :: {:ok, String.t()} | :error
  def review_repository(url) do
    uri = URI.parse(url)
    pattern = if uri.host == "github.com", do: ~r{^/([^/]+/[^/]+)/pull/\d+$}, else: ~r{^/([^/]+(?:/[^/]+)+)/-/merge_requests/\d+$}

    case {uri, Regex.run(pattern, uri.path || "")} do
      {%URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}, [_, project]}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, host <> "/" <> project}

      _ ->
        :error
    end
  end
end

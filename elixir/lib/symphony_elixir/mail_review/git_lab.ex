defmodule SymphonyElixir.MailReview.GitLab do
  @moduledoc "Authenticated, bounded GitLab reads and review-discussion publication via native glab credentials."

  @spec request(map(), String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def request(config, method, path, fields \\ %{}) do
    args = ["api", "--hostname", config["host"], "--method", method, path]
    args = args ++ Enum.flat_map(fields, fn {key, value} -> ["--raw-field", "#{key}=#{value}"] end)

    case command(config["glab_bin"] || "glab", args) do
      {:ok, output} -> Jason.decode(output)
      error -> error
    end
  end

  @spec command(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def command(executable, args) do
    case System.cmd("timeout", ["--signal=TERM", "30s", executable | args], stderr_to_stdout: false) do
      {output, 0} when byte_size(output) <= 8_388_608 -> {:ok, output}
      {_output, status} -> {:error, {:command_failed, executable, status}}
    end
  rescue
    error -> {:error, {:command_unavailable, Exception.message(error)}}
  end

  @spec mr_path(String.t(), pos_integer()) :: String.t()
  def mr_path(project, iid), do: "projects/#{URI.encode_www_form(project)}/merge_requests/#{iid}"

  @spec discussions(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def discussions(config, path), do: pages(config, path <> "/discussions", 1, [])

  defp pages(_config, _path, 101, _acc), do: {:error, :discussion_page_limit}

  defp pages(config, path, page, acc) do
    case request(config, "GET", path <> "?per_page=100&page=#{page}") do
      {:ok, entries} when is_list(entries) and length(entries) < 100 -> {:ok, acc ++ entries}
      {:ok, entries} when is_list(entries) -> pages(config, path, page + 1, acc ++ entries)
      {:ok, _} -> {:error, :invalid_discussions_response}
      error -> error
    end
  end
end

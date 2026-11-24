defmodule SymphonyElixir.ReviewLane.Result do
  @moduledoc "Identify a local source-worktree acquisition failure in a Review result."

  # Older workflows recorded acquisition errors as reviewer evidence gaps.
  @legacy_worktree_gap ~r/no available slot for project |no (?:clean )?available [a-z0-9_.-]+ (?:worktree|pool) slot\b|no (?:available|free|clean) worktree slots?\b|缺少可(?:领取|用)的干净(?:审查)?槽位|worktree\s+名额已用满|slot-\d+ 有受保护的未提交改动，无法检出固定版本/iu

  @spec worktree_failure(map()) :: String.t() | nil
  def worktree_failure(%{"failure_kind" => "worktree_acquire", "reason" => reason}) when is_binary(reason), do: reason
  def worktree_failure(%{"failure_kind" => "worktree_acquire"}), do: "No acquisition error detail was supplied."

  def worktree_failure(%{"status" => "needs_input"} = result) do
    [result["reason"] | legacy_gaps(result["axes"])]
    |> Enum.find(&(is_binary(&1) and Regex.match?(@legacy_worktree_gap, &1)))
  end

  def worktree_failure(_), do: nil

  defp legacy_gaps(axes) when is_map(axes) do
    for {_, %{"gaps" => gaps}} <- axes, gap <- List.wrap(gaps), do: gap
  end

  defp legacy_gaps(_), do: []
end

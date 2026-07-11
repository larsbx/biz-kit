defmodule CoopSubstrate.Cockpit do
  @moduledoc """
  The operator cockpit, read side (Phase 5A; corpus 10 §5): the R-queue as a
  pure fold — open items, deadline-ordered, `as_of:`-reproducible, closed
  items gone. Zero private state: succession stays a key ceremony because
  nothing here lives in the person.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @doc """
  Open R items for a chapter, ordered `{deadline_ms, item_id}` (basis-time
  tie order is the flagged v0 correction, docs/phase5a_plan.md). Supports
  `as_of:`.
  """
  @spec queue(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def queue(chapter_id, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      items =
        for {{^chapter_id, item_id}, %{open: true} = item} <- state.escalations do
          item |> Map.delete(:open) |> Map.put(:item_id, item_id)
        end

      {:ok, Enum.sort_by(items, &{&1.deadline_ms, &1.item_id})}
    end
  end
end

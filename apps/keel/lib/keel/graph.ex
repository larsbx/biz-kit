defmodule Keel.Graph do
  @moduledoc "Minimal directed-graph helpers over `{from, to}` edge lists."

  def successors(edges, v), do: for({^v, w} <- edges, do: w)

  @doc "Some cycle as a closed vertex path `[v, …, v]`, or `nil` if acyclic."
  def cycle(edges) do
    edges
    |> Enum.flat_map(&Tuple.to_list/1)
    |> Enum.uniq()
    |> Enum.reduce_while(%{}, fn v, done ->
      case visit(edges, v, [], done) do
        {:cycle, c} -> {:halt, c}
        done -> {:cont, done}
      end
    end)
    |> then(&if(is_list(&1), do: &1))
  end

  defp visit(edges, v, path, done) do
    cond do
      Map.has_key?(done, v) ->
        done

      v in path ->
        {:cycle, (path |> Enum.reverse() |> Enum.drop_while(&(&1 != v))) ++ [v]}

      true ->
        edges
        |> successors(v)
        |> Enum.reduce_while(done, fn w, acc ->
          case visit(edges, w, [v | path], acc) do
            {:cycle, _} = c -> {:halt, c}
            acc -> {:cont, acc}
          end
        end)
        |> case do
          {:cycle, _} = c -> c
          acc -> Map.put(acc, v, true)
        end
    end
  end

  @doc "Some vertex reachable from `v` (inclusive) satisfies `pred`."
  def reaches?(edges, v, pred), do: reach(edges, [v], MapSet.new(), pred)

  defp reach(_, [], _, _), do: false

  defp reach(edges, [v | rest], seen, pred) do
    cond do
      MapSet.member?(seen, v) -> reach(edges, rest, seen, pred)
      pred.(v) -> true
      true -> reach(edges, rest ++ successors(edges, v), MapSet.put(seen, v), pred)
    end
  end
end

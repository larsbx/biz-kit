defmodule CoopSubstrate.Protocol.StreamRoot do
  @moduledoc """
  The stream-heads tree (Phase 12A, docs/phase12a_plan.md): a Merkle root
  over a chapter's per-stream last-event hashes, carried on `CheckpointV2`
  so an exported bundle can prove COMPLETENESS offline — a withheld tail
  changes a stream's head and falls out of the signed root.

  A tree rather than a flat list on purpose: inclusion proofs reveal only
  sibling hashes, never other streams' ids — a heads list would leak the
  chapter roster (stream ids name members).

  No new cryptographic primitive: SHA-256 over canonical bytes, the same
  hashing the chains already use, with domain-separated leaf/node
  encodings. Leaves are sorted by stream id, so the root is a pure
  function of the heads map; an odd node is promoted unchanged.
  """

  alias CoopSubstrate.Canonical

  @doc """
  The root over a `%{stream_id => head_hash}` map. Total: the empty map
  has a distinguished sentinel root (no `nil` ever enters a checkpoint
  body), and nothing can prove into it.
  """
  def root(heads) when is_map(heads) do
    case leaves(heads) do
      [] ->
        {:ok, bytes} = Canonical.encode(["stream-empty"])
        :crypto.hash(:sha256, bytes)

      layer ->
        layer |> Enum.map(fn {_id, leaf} -> leaf end) |> reduce_root()
    end
  end

  @doc """
  The inclusion proof for `stream_id`: a list of `{side, hash}` siblings
  from leaf to root (`side` is where the SIBLING sits), or `:error` when
  the stream is not in the heads map.
  """
  def prove(heads, stream_id) when is_map(heads) do
    layer = leaves(heads)

    case Enum.find_index(layer, fn {id, _leaf} -> id == stream_id end) do
      nil -> :error
      index -> {:ok, collect_proof(Enum.map(layer, fn {_id, leaf} -> leaf end), index, [])}
    end
  end

  @doc "Does (stream_id, head_hash) prove into `root` via `proof`?"
  def proven?(stream_id, head_hash, proof, root) when is_list(proof) do
    computed =
      Enum.reduce(proof, leaf_hash(stream_id, head_hash), fn
        {:left, sibling}, acc -> node_hash(sibling, acc)
        {:right, sibling}, acc -> node_hash(acc, sibling)
      end)

    computed == root
  end

  defp leaves(heads) do
    heads
    |> Enum.sort_by(fn {stream_id, _head} -> stream_id end)
    |> Enum.map(fn {stream_id, head} -> {stream_id, leaf_hash(stream_id, head)} end)
  end

  defp reduce_root([root]), do: root
  defp reduce_root(layer), do: layer |> pair_up() |> reduce_root()

  defp pair_up([left, right | rest]), do: [node_hash(left, right) | pair_up(rest)]
  defp pair_up(odd), do: odd

  defp collect_proof([_single], _index, acc), do: Enum.reverse(acc)

  defp collect_proof(layer, index, acc) do
    sibling_index = if rem(index, 2) == 0, do: index + 1, else: index - 1

    acc =
      case Enum.at(layer, sibling_index) do
        # An odd promoted node has no sibling at this level.
        nil -> acc
        sibling -> [{if(sibling_index < index, do: :left, else: :right), sibling} | acc]
      end

    collect_proof(pair_up(layer), div(index, 2), acc)
  end

  defp leaf_hash(stream_id, head) do
    {:ok, bytes} = Canonical.encode(["stream-leaf", stream_id, {:bytes, head}])
    :crypto.hash(:sha256, bytes)
  end

  defp node_hash(left, right) do
    {:ok, bytes} = Canonical.encode(["stream-node", {:bytes, left}, {:bytes, right}])
    :crypto.hash(:sha256, bytes)
  end
end

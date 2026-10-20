defmodule TaskCore.Host do
  @moduledoc """
  What a host application supplies to the task core: the two effects its
  rules need. Everything else (storage, signing, ordering, transport) stays
  in the host, which hands each rule plain data.

  `TaskCore.State.init/1` takes the host module; the state carries it.
  """

  @doc """
  Whether the artifact with this SHA-256 digest is in the host's store,
  intact and at most `limit` bytes: `{:ok, size}` or `{:error, reason}`.
  """
  @callback verify_artifact(digest :: <<_::256>>, limit :: non_neg_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  The host's canonical hash of a term, as it names definitions. It must be
  deterministic: replay recomputes it.
  """
  @callback hash(term()) :: binary()
end

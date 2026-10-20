defmodule CoopSubstrate.QuotaWriter do
  @moduledoc false
  alias CoopSubstrate.ArtifactCustody.Quota

  # An actual writer on a peer, paused after its reservation and before I/O.
  def start(parent, key, bytes) do
    spawn(fn ->
      digest = :crypto.hash(:sha256, bytes)
      size = byte_size(bytes)

      result =
        Quota.store(key, digest, size, size, fn ->
          send(parent, {:writer_ready, self()})

          receive do
            :land -> CoopSubstrate.Harness.Artifacts.put(bytes)
            :fail -> {:error, :enospc}
          end
        end)

      send(parent, {:writer_finished, self(), result})
    end)
  end
end

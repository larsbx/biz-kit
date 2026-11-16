defmodule CoopSubstrate.ProcurementContractEvidence do
  @moduledoc """
  Private evidence-owner boundary for inert procurement reviews.

  A configured implementation resolves current, verified evidence for the exact
  chapter, cooperative, request and private case reference. It verifies party
  authority, assent to the canonical record digest, the legal identity of the
  cooperative and the provenance of structured purchase, title, invoice and
  separately allocated service-cost facts. For agency it verifies the mandate
  issuer, its current grant and revocation status, and case scope. A purchase
  amount tagged :original_goods_price must come from the supplier's original
  goods consideration, excluding service allocations.

  The callback runs during a serialized Log read. Use a bounded local snapshot
  with fresh authority and evidence, return an error for unavailable or stale
  data, and never call Log, perform network I/O or write financial state there.
  """

  @callback resolve({String.t(), String.t(), String.t()}, String.t(), non_neg_integer()) ::
              {:ok, map()} | {:error, term()}
end

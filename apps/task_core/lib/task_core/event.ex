defmodule TaskCore.Event do
  @moduledoc """
  An accepted, signed event, as the rules read it. A host may pass this
  struct or its own (a ledger envelope, say) with the same fields: the
  rules match on fields, never on the struct.

    * `event_id`: unique, assigned by the signer;
    * `chapter_id`: the root of its scope;
    * `type` and `payload`: string-keyed, as `TaskCore.Admission.event_types/0`
      declares them;
    * `signers`: who signed it, each with `key_id` and `pubkey`; the host
      has verified the signatures.
  """

  @enforce_keys [:event_id, :chapter_id, :type, :payload]
  defstruct [:event_id, :chapter_id, :type, :payload, signers: []]

  @type signer :: %{key_id: String.t(), pubkey: binary()}
  @type t :: %__MODULE__{
          event_id: String.t(),
          chapter_id: String.t(),
          type: String.t(),
          payload: map(),
          signers: [signer()]
        }
end

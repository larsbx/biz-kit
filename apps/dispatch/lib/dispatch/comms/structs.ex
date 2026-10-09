defmodule Dispatch.Comms do
  @moduledoc """
  Canonical, provider-neutral communications structs (Section 27.1).

  Section 27.1 forbids these from carrying Twilio SDK types, SIDs, TwiML,
  ConversationRelay frames, SIP headers, or SMPP PDUs. A provider's own
  identifier travels separately in `communication_provider_refs`, which is what
  keeps the per-channel migration in Section 27.7 a configuration change.
  """
end

defmodule Dispatch.Comms.OutboundMessage do
  @moduledoc "A message the central service has authorized for delivery."
  @enforce_keys [:message_id, :conversation_id, :to_e164, :from_e164, :body, :idempotency_key]
  defstruct [
    :message_id,
    :conversation_id,
    :to_e164,
    :from_e164,
    :body,
    :idempotency_key,
    :consent_basis,
    :purpose,
    :correlation_id,
    channel: :SMS
  ]

  @type t :: %__MODULE__{
          message_id: String.t(),
          conversation_id: String.t(),
          to_e164: String.t(),
          from_e164: String.t(),
          body: String.t(),
          idempotency_key: String.t(),
          consent_basis: atom() | nil,
          purpose: atom() | nil,
          correlation_id: String.t() | nil,
          channel: :SMS | :MMS | :TELEGRAM | :WHATSAPP
        }
end

defmodule Dispatch.Comms.InboundMessage do
  @moduledoc "A normalized inbound message, already stripped of provider wire format."
  @enforce_keys [:provider, :provider_event_id, :from_e164, :to_e164, :body, :occurred_at]
  defstruct [
    :provider,
    :provider_event_id,
    :from_e164,
    :to_e164,
    :body,
    :occurred_at,
    :correlation_id,
    channel: :SMS,
    media_references: []
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          provider_event_id: String.t(),
          from_e164: String.t(),
          to_e164: String.t(),
          body: String.t(),
          occurred_at: DateTime.t(),
          correlation_id: String.t() | nil,
          channel: :SMS | :MMS | :TELEGRAM | :WHATSAPP,
          media_references: [String.t()]
        }
end

defmodule Dispatch.Comms.SendReceipt do
  @moduledoc "Provider-neutral acknowledgement that a send was accepted."
  @enforce_keys [:message_id, :provider, :accepted_at]
  defstruct [:message_id, :provider, :accepted_at, :provider_reference, :state]

  @type t :: %__MODULE__{
          message_id: String.t(),
          provider: atom(),
          accepted_at: DateTime.t(),
          provider_reference: String.t() | nil,
          state: atom() | nil
        }
end

defmodule Dispatch.Comms.InboundCall do
  @moduledoc "A normalized inbound call presented to the AI-first state machine of Section 8.1."
  @enforce_keys [:call_id, :provider, :provider_event_id, :from_e164, :to_e164, :occurred_at]
  defstruct [
    :call_id,
    :provider,
    :provider_event_id,
    :from_e164,
    :to_e164,
    :occurred_at,
    :correlation_id
  ]

  @type t :: %__MODULE__{
          call_id: String.t(),
          provider: atom(),
          provider_event_id: String.t(),
          from_e164: String.t(),
          to_e164: String.t(),
          occurred_at: DateTime.t(),
          correlation_id: String.t() | nil
        }
end

defmodule Dispatch.Comms.OutboundCall do
  @moduledoc "An approved `CallPlan` rendered for origination (Section 8.4)."
  @enforce_keys [:call_id, :call_plan_id, :to_e164, :from_e164, :purpose, :expires_at]
  defstruct [
    :call_id,
    :call_plan_id,
    :to_e164,
    :from_e164,
    :purpose,
    :expires_at,
    :correlation_id,
    permitted_disclosures: [],
    prohibited_commitments: []
  ]

  @type t :: %__MODULE__{
          call_id: String.t(),
          call_plan_id: String.t(),
          to_e164: String.t(),
          from_e164: String.t(),
          purpose: atom(),
          expires_at: DateTime.t(),
          correlation_id: String.t() | nil,
          permitted_disclosures: [atom()],
          prohibited_commitments: [atom()]
        }
end

defmodule Dispatch.Comms.AnswerPlan do
  @moduledoc """
  How a provider should answer a call.

  Section 8.2 makes the absence of a bridge target part of the type: there is no
  field for a destination number, so no adapter can render one from this struct.
  """
  @enforce_keys [:call_id, :disclosure_text, :media_session_token]
  defstruct [:call_id, :disclosure_text, :media_session_token, :locale, :fallback_text]

  @type t :: %__MODULE__{
          call_id: String.t(),
          disclosure_text: String.t(),
          media_session_token: String.t(),
          locale: String.t() | nil,
          fallback_text: String.t() | nil
        }
end

defmodule Dispatch.Comms.CallReceipt do
  @moduledoc "Provider-neutral acknowledgement that an origination was accepted."
  @enforce_keys [:call_id, :provider, :accepted_at]
  defstruct [:call_id, :provider, :accepted_at, :provider_reference, :state]

  @type t :: %__MODULE__{
          call_id: String.t(),
          provider: atom(),
          accepted_at: DateTime.t(),
          provider_reference: String.t() | nil,
          state: atom() | nil
        }
end

defmodule Dispatch.Comms.ProviderEvent do
  @moduledoc "A validated, normalized provider status callback."
  @enforce_keys [
    :provider,
    :provider_event_id,
    :subject_type,
    :subject_id,
    :event_type,
    :occurred_at
  ]
  defstruct [
    :provider,
    :provider_event_id,
    :subject_type,
    :subject_id,
    :event_type,
    :occurred_at,
    :correlation_id,
    payload: %{}
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          provider_event_id: String.t(),
          subject_type: :MESSAGE | :CALL,
          subject_id: String.t(),
          event_type: atom(),
          occurred_at: DateTime.t(),
          correlation_id: String.t() | nil,
          payload: map()
        }
end

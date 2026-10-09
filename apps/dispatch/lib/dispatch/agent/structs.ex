defmodule Dispatch.Agent.SessionRequest do
  @moduledoc """
  A request to open an agent session (Section 29.0).

  `authorized_context_refs` carries identifiers only. The runtime resolves
  nothing itself: Section 9 routes every read through a typed tool so that Ash
  policies, not prompt text, decide what the assistant may see.
  """
  @enforce_keys [:agent_session_id, :channel, :tool_allowlist]
  defstruct [
    :agent_session_id,
    :channel,
    :tool_allowlist,
    :locale,
    :correlation_id,
    authorized_context_refs: %{}
  ]

  @type t :: %__MODULE__{
          agent_session_id: String.t(),
          channel: :VOICE | :SMS | :PORTAL,
          tool_allowlist: [String.t()],
          locale: String.t() | nil,
          correlation_id: String.t() | nil,
          authorized_context_refs: map()
        }
end

defmodule Dispatch.Agent.Session do
  @moduledoc """
  An open session.

  `agent_session_id` is canonical; `provider_session_ref` is an opaque provider
  handle stored in `agent_provider_refs`. Section 29.0 makes provider-side
  memory non-authoritative, so replaying an audited action never needs it.
  """
  @enforce_keys [:agent_session_id, :provider, :opened_at]
  defstruct [:agent_session_id, :provider, :opened_at, :provider_session_ref, :adapter_version]

  @type t :: %__MODULE__{
          agent_session_id: String.t(),
          provider: atom(),
          opened_at: DateTime.t(),
          provider_session_ref: String.t() | nil,
          adapter_version: String.t() | nil
        }
end

defmodule Dispatch.Agent.TurnRequest do
  @moduledoc "One turn, carrying the per-turn tool allowlist of Section 29.0."
  @enforce_keys [:session, :input, :tool_allowlist]
  defstruct [:session, :input, :tool_allowlist, :deadline_ms, :correlation_id]

  @type t :: %__MODULE__{
          session: Dispatch.Agent.Session.t(),
          input: String.t() | map(),
          tool_allowlist: [String.t()],
          deadline_ms: pos_integer() | nil,
          correlation_id: String.t() | nil
        }
end

defmodule Dispatch.Agent.ToolCall do
  @moduledoc """
  A structured tool call as the adapter reports it.

  Arguments stay raw JSON here. Section 29.0 validates them against the
  application-owned schema before execution, and Section 29.0.1 forbids the
  adapter from executing anything, so this is a request and never an effect.
  """
  @enforce_keys [:tool_call_id, :name, :arguments]
  defstruct [:tool_call_id, :name, :arguments]

  @type t :: %__MODULE__{tool_call_id: String.t(), name: String.t(), arguments: map()}
end

defmodule Dispatch.Agent.TurnResult do
  @moduledoc "The outcome of one turn, with usage and provenance for Section 32 metrics."
  @enforce_keys [:session, :finish_reason]
  defstruct [:session, :finish_reason, :text, :usage, :latency_ms, :provider, tool_calls: []]

  @type t :: %__MODULE__{
          session: Dispatch.Agent.Session.t(),
          finish_reason: :STOP | :TOOL_CALLS | :LENGTH | :TIMEOUT | :ERROR,
          text: String.t() | nil,
          usage: map() | nil,
          latency_ms: non_neg_integer() | nil,
          provider: atom() | nil,
          tool_calls: [Dispatch.Agent.ToolCall.t()]
        }
end

defmodule Dispatch.Agent.StreamRequest do
  @moduledoc "A request to open a streaming turn for a voice call."
  @enforce_keys [:session, :tool_allowlist]
  defstruct [:session, :tool_allowlist, :locale, :deadline_ms, :correlation_id]

  @type t :: %__MODULE__{
          session: Dispatch.Agent.Session.t(),
          tool_allowlist: [String.t()],
          locale: String.t() | nil,
          deadline_ms: pos_integer() | nil,
          correlation_id: String.t() | nil
        }
end

defmodule Dispatch.Agent.Stream do
  @moduledoc "A handle to an open stream."
  @enforce_keys [:stream_id, :session, :provider]
  defstruct [:stream_id, :session, :provider, :provider_stream_ref]

  @type t :: %__MODULE__{
          stream_id: String.t(),
          session: Dispatch.Agent.Session.t(),
          provider: atom(),
          provider_stream_ref: term() | nil
        }
end

defmodule Dispatch.Agent.InputEvent do
  @moduledoc """
  A provider-neutral input event.

  Audio arrives as a reference rather than inline bytes so transcripts and media
  stay under the retention policy of Section 13 instead of flowing through
  process mailboxes and logs.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :text, :audio_reference, :occurred_at]

  @type t :: %__MODULE__{
          kind: :SPEECH_FINAL | :SPEECH_PARTIAL | :DTMF | :BARGE_IN | :HANGUP,
          text: String.t() | nil,
          audio_reference: String.t() | nil,
          occurred_at: DateTime.t() | nil
        }
end

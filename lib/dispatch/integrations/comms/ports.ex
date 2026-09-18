defmodule Dispatch.Integrations.Comms.MessagingProvider do
  @moduledoc """
  Messaging port (Section 27.1).

  `validate_ingress/1` takes the raw `Plug.Conn` on purpose: Section 27.2
  requires the provider signature to be validated against the exact public URL
  *before* the body is parsed or persisted, which is only possible while the
  adapter still holds the connection.
  """

  @callback send_message(Dispatch.Comms.OutboundMessage.t()) ::
              {:ok, Dispatch.Comms.SendReceipt.t()} | {:error, term()}

  @callback validate_ingress(Plug.Conn.t()) ::
              {:ok, Dispatch.Comms.InboundMessage.t()} | {:error, term()}
end

defmodule Dispatch.Integrations.Comms.VoiceProvider do
  @moduledoc """
  Voice control port (Section 27.1).

  `answer/1` returns an `AnswerPlan`, which carries no destination number, so
  the inbound no-contact invariant of Section 8.2 is enforced by the type rather
  than by adapter discipline.
  """

  @callback answer(Dispatch.Comms.InboundCall.t()) ::
              {:ok, Dispatch.Comms.AnswerPlan.t()} | {:error, term()}

  @callback originate(Dispatch.Comms.OutboundCall.t()) ::
              {:ok, Dispatch.Comms.CallReceipt.t()} | {:error, term()}

  @callback validate_ingress(Plug.Conn.t()) ::
              {:ok, Dispatch.Comms.ProviderEvent.t()} | {:error, term()}
end

defmodule Dispatch.Integrations.Comms.VoiceMediaProvider do
  @moduledoc """
  Voice media port (Section 27.1).

  Media transport is separate from call control so Section 27.7 can migrate them
  independently; a deployment may keep Twilio call control while moving media.
  """

  @callback accept_session(map()) :: {:ok, term()} | {:error, term()}
  @callback receive_frame(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback send_assistant_output(term(), map()) :: :ok | {:error, term()}
  @callback close(term(), atom()) :: :ok
end

defmodule Dispatch.Integrations.Comms.Unconfigured do
  @moduledoc """
  Deterministic "no provider selected" communications adapters.

  These are the development defaults, so a clean checkout starts without any
  telecom credential. They are not mocks and they never simulate success:
  Section 8.6 requires a deterministic fallback rather than invented state, and
  `Dispatch.Config` rejects them in production, so selecting one there is a
  startup failure instead of a silently dead channel.
  """

  @error {:error, :comms_adapter_not_configured}

  defmodule Messaging do
    @moduledoc "Unconfigured messaging adapter. Every operation fails deterministically."
    @behaviour Dispatch.Integrations.Comms.MessagingProvider

    @impl true
    def send_message(%Dispatch.Comms.OutboundMessage{}),
      do: {:error, :comms_adapter_not_configured}

    @impl true
    def validate_ingress(%Plug.Conn{}), do: {:error, :comms_adapter_not_configured}
  end

  defmodule Voice do
    @moduledoc "Unconfigured voice-control adapter."
    @behaviour Dispatch.Integrations.Comms.VoiceProvider

    @impl true
    def answer(%Dispatch.Comms.InboundCall{}), do: {:error, :comms_adapter_not_configured}

    @impl true
    def originate(%Dispatch.Comms.OutboundCall{}), do: {:error, :comms_adapter_not_configured}

    @impl true
    def validate_ingress(%Plug.Conn{}), do: {:error, :comms_adapter_not_configured}
  end

  defmodule VoiceMedia do
    @moduledoc "Unconfigured voice-media adapter."
    @behaviour Dispatch.Integrations.Comms.VoiceMediaProvider

    @impl true
    def accept_session(_params), do: {:error, :comms_adapter_not_configured}

    @impl true
    def receive_frame(_session, _frame), do: {:error, :comms_adapter_not_configured}

    @impl true
    def send_assistant_output(_session, _output), do: {:error, :comms_adapter_not_configured}

    @impl true
    def close(_session, _reason), do: :ok
  end

  @doc "The error every operation on an unconfigured communications port returns."
  @spec error() :: {:error, :comms_adapter_not_configured}
  def error, do: @error
end

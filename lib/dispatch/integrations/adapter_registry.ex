defmodule Dispatch.Integrations.AdapterRegistry do
  @moduledoc """
  The provider-selection surface of Section 31.

  Sections 27, 28, and 29 each require that a provider be replaceable by
  configuration alone. That is only true if one place knows which module is
  selected for each port and which secrets that choice makes mandatory, so this
  module owns both and is the single input to the startup validation in
  `Dispatch.Config`.

  Reports describe presence, never values (Section 31).
  """

  @typedoc "A configurable provider port."
  @type port_key ::
          :messaging
          | :voice
          | :voice_media
          | :agent_runtime
          | :agent_streaming_runtime
          | :geocoder
          | :router
          | :map_presentation
          | :face_verifier

  @ports %{
    messaging: %{
      env: "COMMS_MESSAGING_ADAPTER",
      config: [:comms, :messaging_adapter],
      behaviour: Dispatch.Integrations.Comms.MessagingProvider
    },
    voice: %{
      env: "COMMS_VOICE_ADAPTER",
      config: [:comms, :voice_adapter],
      behaviour: Dispatch.Integrations.Comms.VoiceProvider
    },
    voice_media: %{
      env: "COMMS_VOICE_MEDIA_ADAPTER",
      config: [:comms, :voice_media_adapter],
      behaviour: Dispatch.Integrations.Comms.VoiceMediaProvider
    },
    agent_runtime: %{
      env: "AGENT_RUNTIME_ADAPTER",
      config: [:agent, :runtime],
      behaviour: Dispatch.Integrations.Agent.Runtime
    },
    agent_streaming_runtime: %{
      env: "AGENT_STREAMING_RUNTIME_ADAPTER",
      config: [:agent, :streaming_runtime],
      behaviour: Dispatch.Integrations.Agent.StreamingRuntime
    },
    geocoder: %{
      env: "GEO_GEOCODER_ADAPTER",
      config: [:geo, :geocoder],
      behaviour: Dispatch.Integrations.Geo.Geocoder
    },
    router: %{
      env: "GEO_ROUTER_ADAPTER",
      config: [:geo, :router],
      behaviour: Dispatch.Integrations.Geo.Router
    },
    # Section 28.5 selects the portal map adapter in the browser, so the server
    # holds a descriptor name rather than a module; the value is checked against
    # the allowlist below instead of against a behaviour.
    map_presentation: %{
      env: "MAP_PRESENTATION_PROVIDER",
      config: [:geo, :map_presentation],
      behaviour: nil,
      kind: :name,
      allowed: [:google, :maplibre]
    },
    face_verifier: %{
      env: "FACE_VERIFIER_ADAPTER",
      config: [:identity, :face_verifier],
      behaviour: Dispatch.Identity.Face.Verifier
    }
  }

  # Section 31: a provider's secrets are required only when one of its adapters
  # is selected. The prefix is matched against the selected module name so a
  # replacement adapter in the same namespace inherits the same requirement.
  @secrets_by_namespace [
    {"Dispatch.Integrations.Comms.Twilio",
     ~w(TWILIO_ACCOUNT_SID TWILIO_API_KEY_SID TWILIO_API_KEY_SECRET TWILIO_PHONE_NUMBER)},
    {"Dispatch.Integrations.Agent.Hermes", ~w(HERMES_BASE_URL HERMES_SERVICE_TOKEN)},
    {"Dispatch.Integrations.Geo.Google", ~w(GOOGLE_MAPS_SERVER_CREDENTIAL)}
  ]

  @doc "Every configurable port key."
  @spec port_keys() :: [port_key()]
  def port_keys, do: Map.keys(@ports)

  @doc "Static metadata for a port: its environment variable, config path, and behaviour."
  @spec port(port_key()) :: map()
  def port(key) when is_map_key(@ports, key) do
    @ports |> Map.fetch!(key) |> Map.put_new(:kind, :module) |> Map.put_new(:allowed, nil)
  end

  @doc "Port keys whose configured value is a module rather than a descriptor name."
  @spec module_port_keys() :: [port_key()]
  def module_port_keys do
    port_keys() |> Enum.filter(fn key -> port(key).kind == :module end)
  end

  @doc "The module currently selected for a port, or nil when unconfigured."
  @spec selected(port_key()) :: module() | nil
  def selected(key) do
    %{config: [app_key, sub_key]} = port(key)

    :dispatch
    |> Application.get_env(app_key, [])
    |> Keyword.get(sub_key)
  end

  @doc """
  Environment variable names whose presence is mandatory given the current
  adapter selection. Used by startup validation and by the redacted report.
  """
  @spec required_secrets() :: [String.t()]
  def required_secrets do
    selected_module_names()
    |> Enum.flat_map(fn name ->
      Enum.flat_map(@secrets_by_namespace, fn {namespace, secrets} ->
        if String.starts_with?(name, namespace), do: secrets, else: []
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Redacted adapter report for `/health/dependencies`.

  Section 31 permits configuration keys and presence; this returns the selected
  module name, whether it exports its port behaviour, and secret presence.
  """
  @spec configuration_report() :: map()
  def configuration_report do
    ports =
      Map.new(port_keys(), fn key ->
        meta = port(key)
        module = selected(key)

        {key,
         %{
           env: meta.env,
           selected: module && to_string_value(module),
           implements_behaviour: meta.kind == :module and implements?(module, meta.behaviour)
         }}
      end)

    %{
      ports: ports,
      required_secrets:
        Map.new(required_secrets(), fn name -> {name, System.get_env(name) not in [nil, ""]} end)
    }
  end

  @doc "True when `module` declares `behaviour` in its `@behaviour` attributes."
  @spec implements?(module() | nil, module() | nil) :: boolean()
  def implements?(nil, _behaviour), do: false
  def implements?(_module, nil), do: true

  def implements?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in List.flatten(module.module_info(:attributes)[:behaviour] || [])
  end

  defp to_string_value(value) when is_atom(value) do
    if Atom.to_string(value) =~ ~r/^Elixir\./, do: inspect(value), else: to_string(value)
  end

  defp to_string_value(value), do: to_string(value)

  defp selected_module_names do
    module_port_keys()
    |> Enum.map(&selected/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&inspect/1)
  end
end

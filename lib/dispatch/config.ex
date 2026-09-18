defmodule Dispatch.Config do
  @moduledoc """
  Startup validation of the configuration contract in Section 31.

  Section 31 requires production startup to fail closed on a missing adapter
  secret, an out-of-range bound, or a non-production-only mode left enabled.
  Returning a list of violations rather than raising on the first one lets an
  operator fix a misconfigured deployment in a single pass.
  """

  alias Dispatch.Integrations.AdapterRegistry

  @typedoc "A single configuration violation, identified by a stable reason code."
  @type violation :: %{code: String.t(), key: String.t(), detail: String.t()}

  @breakglass_ttl_bounds 60..3_600
  @face_challenge_ttl_bounds 30..120

  @doc """
  Validates the running configuration and raises when it is unusable.

  Called from `config/runtime.exs` so an invalid deployment never binds a port.
  """
  @spec validate!(keyword()) :: :ok
  def validate!(opts \\ []) do
    case validate(opts) do
      [] ->
        :ok

      violations ->
        raise ArgumentError, """
        Invalid configuration; refusing to start.

        #{Enum.map_join(violations, "\n", fn v -> "  - [#{v.code}] #{v.key}: #{v.detail}" end)}
        """
    end
  end

  @doc "Returns every configuration violation, or `[]` when the configuration is valid."
  @spec validate(keyword()) :: [violation()]
  def validate(opts \\ []) do
    env = Keyword.get(opts, :env, Application.get_env(:dispatch, :environment, :dev))
    production? = env == :prod

    Enum.concat([
      validate_adapters(),
      validate_nonproduction_adapters(production?),
      validate_secrets(production?),
      validate_breakglass(production?),
      validate_face(production?)
    ])
  end

  # Every port must name a module that is compiled in and exports its behaviour.
  # Sections 27.1, 28.1, and 29.0 all depend on that being checked centrally,
  # because a typo would otherwise surface as a runtime crash mid-call.
  defp validate_adapters do
    Enum.flat_map(AdapterRegistry.port_keys(), fn key ->
      meta = AdapterRegistry.port(key)
      validate_port(meta, AdapterRegistry.selected(key))
    end)
  end

  # A descriptor-name port names a browser-side adapter (Section 28.5), so it is
  # checked against an allowlist rather than loaded as a module.
  defp validate_port(%{kind: :name} = meta, value) do
    cond do
      is_nil(value) ->
        [violation("ADAPTER_UNCONFIGURED", meta.env, "No provider is selected.")]

      value not in meta.allowed ->
        [
          violation(
            "ADAPTER_NOT_ALLOWED",
            meta.env,
            "#{inspect(value)} is not one of #{inspect(meta.allowed)}."
          )
        ]

      true ->
        []
    end
  end

  defp validate_port(meta, module) do
    cond do
      is_nil(module) ->
        [violation("ADAPTER_UNCONFIGURED", meta.env, "No adapter module is selected.")]

      not Code.ensure_loaded?(module) ->
        [violation("ADAPTER_NOT_COMPILED", meta.env, "#{inspect(module)} is not compiled in.")]

      not AdapterRegistry.implements?(module, meta.behaviour) ->
        [
          violation(
            "ADAPTER_BEHAVIOUR_MISMATCH",
            meta.env,
            "#{inspect(module)} does not implement #{inspect(meta.behaviour)}."
          )
        ]

      true ->
        []
    end
  end

  # The development defaults fail every call deterministically. Reaching
  # production with one selected would present as a silently dead channel, which
  # Section 35 forbids, so it is a startup failure instead.
  @nonproduction_namespaces [
    "Dispatch.Integrations.Comms.Unconfigured",
    "Dispatch.Integrations.Geo.Unconfigured",
    "Dispatch.Integrations.Agent.Fake"
  ]

  defp validate_nonproduction_adapters(false), do: []

  defp validate_nonproduction_adapters(true) do
    Enum.flat_map(AdapterRegistry.module_port_keys(), fn key ->
      meta = AdapterRegistry.port(key)
      name = AdapterRegistry.selected(key) |> inspect()

      if Enum.any?(@nonproduction_namespaces, &String.starts_with?(name, &1)) do
        [
          violation(
            "ADAPTER_NOT_PRODUCTION_SAFE",
            meta.env,
            "#{name} is a development-only adapter and cannot be selected in production."
          )
        ]
      else
        []
      end
    end)
  end

  defp validate_secrets(false), do: []

  defp validate_secrets(true) do
    AdapterRegistry.required_secrets()
    |> Enum.reject(fn name -> System.get_env(name) not in [nil, ""] end)
    |> Enum.map(fn name ->
      violation("SECRET_MISSING", name, "Required by the selected adapter but not set.")
    end)
  end

  defp validate_breakglass(production?) do
    ttl = Application.get_env(:dispatch, :breakglass, []) |> Keyword.get(:max_ttl_seconds, 1_800)
    single_user? = Application.get_env(:dispatch, :breakglass, [])[:nonprod_single_user_mode]
    requester = System.get_env("BREAKGLASS_REQUESTER_ENTITLEMENT")
    approver = System.get_env("BREAKGLASS_APPROVER_ENTITLEMENT")

    ttl_violation =
      if ttl in @breakglass_ttl_bounds do
        []
      else
        [
          violation(
            "BREAKGLASS_TTL_OUT_OF_RANGE",
            "BREAKGLASS_MAX_TTL_SECONDS",
            "Must be between 60 and 3600; got #{inspect(ttl)}."
          )
        ]
      end

    # Section 31: production startup fails when the single-user flow is enabled.
    single_user_violation =
      if production? and single_user? do
        [
          violation(
            "BREAKGLASS_SINGLE_USER_IN_PRODUCTION",
            "BREAKGLASS_NONPROD_SINGLE_USER_MODE",
            "The single-user flow is forbidden in production."
          )
        ]
      else
        []
      end

    # Section 23.4 separates requesting from approving; equal entitlements would
    # let one person do both.
    entitlement_violation =
      if production? and (is_nil(requester) or requester == approver) do
        [
          violation(
            "BREAKGLASS_ENTITLEMENTS_NOT_DISTINCT",
            "BREAKGLASS_REQUESTER_ENTITLEMENT",
            "Requester and approver entitlements must be set and distinct in production."
          )
        ]
      else
        []
      end

    ttl_violation ++ single_user_violation ++ entitlement_violation
  end

  defp validate_face(production?) do
    identity = Application.get_env(:dispatch, :identity, [])
    enabled? = Keyword.get(identity, :face_1_to_1_enabled, false)
    ttl = Keyword.get(identity, :face_challenge_ttl_seconds, 120)

    ttl_violation =
      if ttl in @face_challenge_ttl_bounds do
        []
      else
        [
          violation(
            "FACE_CHALLENGE_TTL_OUT_OF_RANGE",
            "FACE_CHALLENGE_TTL_SECONDS",
            "Must be between 30 and 120; got #{inspect(ttl)}."
          )
        ]
      end

    # Section 31: enabling face matching without its full policy context is a
    # startup failure, not a degraded mode.
    enablement_violations =
      if enabled? do
        [
          {:manifest_public_key, "FACE_POLICY_MANIFEST_PUBLIC_KEY"},
          {:face_attestation_retention_days, "FACE_ATTESTATION_RETENTION_DAYS"},
          {:consent_text_version, "FACE_CONSENT_TEXT_VERSION"},
          {:jurisdiction_policy_version, "FACE_JURISDICTION_POLICY_VERSION"}
        ]
        |> Enum.reject(fn {key, _env} -> Keyword.get(identity, key) not in [nil, ""] end)
        |> Enum.map(fn {_key, env} ->
          violation("FACE_ENABLED_WITHOUT_POLICY", env, "Required when FACE_1_TO_1_ENABLED=true.")
        end)
      else
        []
      end

    # Section 25.6 makes DisabledFaceVerifier the default; a production
    # deployment that leaves face matching off must actually select it.
    adapter_violation =
      if production? and not enabled? and
           AdapterRegistry.selected(:face_verifier) != Dispatch.Identity.Face.DisabledVerifier do
        [
          violation(
            "FACE_ADAPTER_INCONSISTENT",
            "FACE_VERIFIER_ADAPTER",
            "Must be Dispatch.Identity.Face.DisabledVerifier while FACE_1_TO_1_ENABLED=false."
          )
        ]
      else
        []
      end

    ttl_violation ++ enablement_violations ++ adapter_violation
  end

  defp violation(code, key, detail), do: %{code: code, key: key, detail: detail}
end

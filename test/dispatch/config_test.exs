defmodule Dispatch.ConfigTest do
  @moduledoc """
  Section 31 makes configuration a fail-closed contract. These assert the
  boundaries themselves, because an off-by-one on a TTL bound or a
  development-only adapter reaching production would both present as a working
  deployment.
  """

  use ExUnit.Case, async: false

  alias Dispatch.Config

  setup do
    original = %{
      comms: Application.get_env(:dispatch, :comms),
      geo: Application.get_env(:dispatch, :geo),
      agent: Application.get_env(:dispatch, :agent),
      identity: Application.get_env(:dispatch, :identity),
      breakglass: Application.get_env(:dispatch, :breakglass)
    }

    on_exit(fn ->
      Enum.each(original, fn {key, value} -> Application.put_env(:dispatch, key, value) end)
    end)

    :ok
  end

  defp codes(env), do: Config.validate(env: env) |> Enum.map(& &1.code) |> Enum.sort()

  test "the development configuration is valid" do
    assert Config.validate(env: :test) == []
  end

  describe "adapter selection" do
    test "an unconfigured port is a violation" do
      Application.put_env(:dispatch, :geo, geocoder: nil, router: nil, map_presentation: :google)

      assert "ADAPTER_UNCONFIGURED" in codes(:test)
    end

    test "a module that does not implement its port behaviour is a violation" do
      Application.put_env(:dispatch, :geo,
        geocoder: Dispatch.Config,
        router: Dispatch.Integrations.Geo.Unconfigured.Router,
        map_presentation: :google
      )

      assert "ADAPTER_BEHAVIOUR_MISMATCH" in codes(:test)
    end

    test "a descriptor-name port is checked against an allowlist, not loaded as a module" do
      base = Application.get_env(:dispatch, :geo)

      # Section 28.5 selects the portal map adapter in the browser, so the
      # server holds a name. It must not be validated as a module.
      Application.put_env(:dispatch, :geo, Keyword.put(base, :map_presentation, :maplibre))
      assert Config.validate(env: :test) == []

      Application.put_env(:dispatch, :geo, Keyword.put(base, :map_presentation, :leaflet))
      assert "ADAPTER_NOT_ALLOWED" in codes(:test)
      refute "ADAPTER_NOT_COMPILED" in codes(:test)
    end

    test "development-only adapters are rejected in production but allowed elsewhere" do
      refute "ADAPTER_NOT_PRODUCTION_SAFE" in codes(:test)
      assert "ADAPTER_NOT_PRODUCTION_SAFE" in codes(:prod)
    end
  end

  describe "break-glass bounds" do
    test "the TTL range is inclusive at both ends" do
      for ttl <- [60, 1_800, 3_600] do
        Application.put_env(:dispatch, :breakglass, max_ttl_seconds: ttl)
        refute "BREAKGLASS_TTL_OUT_OF_RANGE" in codes(:test)
      end

      for ttl <- [59, 3_601, 0, -1] do
        Application.put_env(:dispatch, :breakglass, max_ttl_seconds: ttl)
        assert "BREAKGLASS_TTL_OUT_OF_RANGE" in codes(:test)
      end
    end

    test "the single-user flow fails production startup" do
      Application.put_env(:dispatch, :breakglass,
        max_ttl_seconds: 1_800,
        nonprod_single_user_mode: true
      )

      assert "BREAKGLASS_SINGLE_USER_IN_PRODUCTION" in codes(:prod)
      refute "BREAKGLASS_SINGLE_USER_IN_PRODUCTION" in codes(:dev)
    end

    test "requester and approver entitlements must be distinct in production" do
      assert "BREAKGLASS_ENTITLEMENTS_NOT_DISTINCT" in codes(:prod)
    end
  end

  describe "face verification" do
    test "the challenge TTL range is inclusive at both ends" do
      base = Application.get_env(:dispatch, :identity)

      for ttl <- [30, 120] do
        Application.put_env(
          :dispatch,
          :identity,
          Keyword.put(base, :face_challenge_ttl_seconds, ttl)
        )

        refute "FACE_CHALLENGE_TTL_OUT_OF_RANGE" in codes(:test)
      end

      for ttl <- [29, 121] do
        Application.put_env(
          :dispatch,
          :identity,
          Keyword.put(base, :face_challenge_ttl_seconds, ttl)
        )

        assert "FACE_CHALLENGE_TTL_OUT_OF_RANGE" in codes(:test)
      end
    end

    test "enabling face matching without its policy context is a violation" do
      base = Application.get_env(:dispatch, :identity)
      Application.put_env(:dispatch, :identity, Keyword.put(base, :face_1_to_1_enabled, true))

      assert "FACE_ENABLED_WITHOUT_POLICY" in codes(:test)
    end

    test "enabling face matching while the disabled verifier is selected is a violation" do
      # The disabled verifier answers every challenge ENROLLMENT_REQUIRED, so
      # this pairing means the feature is on and nobody can ever be verified.
      # Section 31 requires startup to fail closed when matching is enabled
      # without a valid adapter, and the default adapter is not one.
      base = Application.get_env(:dispatch, :identity)

      Application.put_env(
        :dispatch,
        :identity,
        base
        |> Keyword.put(:face_1_to_1_enabled, true)
        |> Keyword.put(:face_verifier, Dispatch.Identity.Face.DisabledVerifier)
        |> Keyword.put(:manifest_public_key, "key")
        |> Keyword.put(:face_attestation_retention_days, "30")
        |> Keyword.put(:consent_text_version, "v1")
        |> Keyword.put(:jurisdiction_policy_version, "v1")
      )

      codes = codes(:test)

      # Every policy value is present, so this must be the only thing missing.
      refute "FACE_ENABLED_WITHOUT_POLICY" in codes
      assert "FACE_ADAPTER_INCONSISTENT" in codes
    end

    test "FACE_1_TO_1_ENABLED defaults to false and pairs with the disabled verifier" do
      identity = Application.get_env(:dispatch, :identity)

      refute Keyword.fetch!(identity, :face_1_to_1_enabled)
      assert Keyword.fetch!(identity, :face_verifier) == Dispatch.Identity.Face.DisabledVerifier
    end
  end

  test "validate!/1 raises on an invalid configuration" do
    Application.put_env(:dispatch, :breakglass, max_ttl_seconds: 10)

    assert_raise ArgumentError, ~r/BREAKGLASS_TTL_OUT_OF_RANGE/, fn ->
      Config.validate!(env: :test)
    end
  end
end

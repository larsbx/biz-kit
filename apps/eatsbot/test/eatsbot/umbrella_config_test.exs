defmodule Eatsbot.UmbrellaConfigTest do
  @moduledoc """
  The umbrella shares one configuration, so a global key eatsbot sets reaches every
  app. eatsbot's Ash tracer depends on `opentelemetry_ash`, which only eatsbot
  carries, so it is installed when eatsbot starts rather than configured globally.
  """
  use ExUnit.Case, async: true

  @config Path.expand("../../../../config/config.exs", __DIR__)

  test "the umbrella's configuration sets no Ash tracer for the other apps" do
    for env <- [:dev, :test, :prod] do
      config = Config.Reader.read!(@config, env: env)
      assert get_in(config, [:ash, :tracer]) in [nil, []], "#{env} sets a global Ash tracer"
    end
  end

  test "eatsbot traces its own Ash actions once it has started" do
    assert OpentelemetryAsh in Application.get_env(:ash, :tracer, [])
  end

  # Ash loads every known type for operator overloading at runtime. `custom_types`
  # stays in shared config: Ash reads it at compile time, as a name lookup only.
  test "the umbrella's configuration registers no runtime Ash types for the other apps" do
    for env <- [:dev, :test, :prod] do
      config = Config.Reader.read!(@config, env: env)
      assert get_in(config, [:ash, :known_types]) in [nil, []], "#{env} sets known_types"
    end
  end

  test "eatsbot registers Money with Ash once it has started" do
    assert AshMoney.Types.Money in Application.get_env(:ash, :known_types, [])
  end

  # Global Ash behaviour flags change every app's resources: forbidden reads that
  # error in spruce_goose would be filtered to an empty result. Shared config holds
  # only what the other apps already set, plus eatsbot's compile-time type names.
  @shared_ash_keys [:default_string_length_count, :disable_async?, :custom_types]

  test "the umbrella's configuration sets no Ash behaviour flags for the other apps" do
    for env <- [:dev, :test, :prod] do
      config = Config.Reader.read!(@config, env: env)
      keys = config |> Keyword.get(:ash, []) |> Keyword.keys()
      assert keys -- @shared_ash_keys == [], "#{env} sets #{inspect(keys -- @shared_ash_keys)}"
    end
  end

  test "eatsbot keeps its own read behaviour once it has started" do
    assert Application.get_env(:ash, :policies)[:no_filter_static_forbidden_reads?] == false
    assert Application.get_env(:ash, :default_page_type) == :keyset
    assert Application.get_env(:ash, :show_keysets_for_all_actions?) == false
  end
end

defmodule BizKit.Identity.Providers.DevelopmentTest do
  @moduledoc """
  The development provider signs in as one configured person, without a real
  provider, for local runs and end-to-end tests. It refuses to work unless
  `:allow_development_provider` is set, which only development configuration does.
  """
  use ExUnit.Case, async: false

  alias BizKit.Identity.Providers.Development

  setup do
    previous = Application.get_env(:biz_kit_identity, :allow_development_provider)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:biz_kit_identity, :allow_development_provider),
        else: Application.put_env(:biz_kit_identity, :allow_development_provider, previous)
    end)

    :ok
  end

  @config [subject: "driver-1"]

  test "allowed, it sends the browser straight back with the configured person" do
    Application.put_env(:biz_kit_identity, :allow_development_provider, true)

    url = Development.authorize_url(@config, "st&1", "http://127.0.0.1:4001/auth/driver/callback")

    assert %URI{path: "/auth/driver/callback", query: query} = URI.parse(url)
    assert URI.decode_query(query) == %{"code" => "driver-1", "state" => "st&1"}

    assert {:ok, %{issuer: "biz-kit-development", subject: "driver-1"}} =
             Development.authenticate(@config, "driver-1", "ignored")

    assert {:error, :rejected} = Development.authenticate(@config, "someone-else", "ignored")
  end

  test "not allowed, it signs no one in" do
    Application.delete_env(:biz_kit_identity, :allow_development_provider)

    assert {:error, :development_provider_disallowed} =
             Development.authenticate(@config, "driver-1", "ignored")

    assert_raise RuntimeError, fn -> Development.authorize_url(@config, "s", "http://x/cb") end
  end
end

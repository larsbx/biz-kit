defmodule Eatsbot.AssetPathsTest do
  @moduledoc """
  The asset build reaches into dependencies by path: Tailwind scans
  ash_authentication_phoenix's templates and reads heroicons, and esbuild resolves
  phoenix's JavaScript through NODE_PATH. In the umbrella every dependency lives in
  the root `deps/`, and a wrong path fails either loudly (heroicons) or silently
  (an empty content glob ships the sign-in pages unstyled).
  """
  use ExUnit.Case, async: true

  @assets Path.expand("../../assets", __DIR__)

  test "every dependency path in tailwind.config.js exists" do
    config = File.read!(Path.join(@assets, "tailwind.config.js"))
    paths = Regex.scan(~r{"((?:\.\./)+deps/[^"*]+)}, config, capture: :all_but_first)

    assert paths != []

    for [path] <- paths do
      dir = Path.expand(path, @assets)
      assert File.dir?(dir), "tailwind.config.js points at #{path}, which is not #{dir}"
    end

    heroicons = Path.expand("../../../deps/heroicons/optimized/24/outline", @assets)
    assert heroicons |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".svg"))

    auth_templates =
      Path.wildcard(Path.expand("../../../deps/ash_authentication_phoenix/**/*.*ex", @assets))

    assert auth_templates != [], "Tailwind would scan no ash_authentication_phoenix templates"
  end

  test "esbuild's NODE_PATH holds phoenix's JavaScript" do
    node_path = Application.fetch_env!(:esbuild, :eatsbot)[:env]["NODE_PATH"]
    assert File.exists?(Path.join([node_path, "phoenix", "package.json"])), node_path
    assert File.exists?(Path.join([node_path, "phoenix_live_view", "package.json"])), node_path
  end
end

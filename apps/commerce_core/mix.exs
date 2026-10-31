defmodule CommerceCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :commerce_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:ex_money, "~> 6.2"}] ++ json_polyfill()
    ] ++ umbrella_paths()
  end

  # ex_money's localize needs OTP 27's :json module. Hosts still on OTP 26
  # (Eatsbot's toolchain) get the polyfill; the umbrella, on OTP 27, does not,
  # so its lock is unchanged.
  defp json_polyfill do
    if String.to_integer(System.otp_release()) < 27,
      do: [{:json_polyfill, "~> 0.2 or ~> 1.0"}],
      else: []
  end

  # In the biz-kit umbrella all apps share one _build, deps, config and lock.
  # A source package copied or fetched into an unrelated Mix host must not
  # refer to ../../mix.lock or another project's config/dependency directory.
  defp umbrella_paths do
    if Path.basename(Path.dirname(__DIR__)) == "apps" and
         File.regular?(Path.expand("../../mix.exs", __DIR__)) and
         File.dir?(Path.expand("../../apps", __DIR__)) do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end

  def application, do: [extra_applications: [:logger]]
end

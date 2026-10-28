defmodule Eatsbot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if System.get_env("ECTO_IPV6") do
      :httpc.set_option(:ipfamily, :inet6fb4)
    end

    # Registered here rather than in config: the umbrella shares one
    # configuration, and the other apps carry neither opentelemetry_ash nor
    # ash_money, whose modules Ash loads from these keys at runtime.
    register_with_ash(:tracer, OpentelemetryAsh)
    register_with_ash(:known_types, AshMoney.Types.Money)

    # eatsbot's read behaviour. Other apps rely on Ash's defaults: in spruce_goose
    # a statically forbidden read must error, not come back filtered and empty.
    Application.put_env(
      :ash,
      :policies,
      Keyword.put(
        Application.get_env(:ash, :policies, []),
        :no_filter_static_forbidden_reads?,
        false
      )
    )

    Application.put_env(:ash, :default_page_type, :keyset)
    Application.put_env(:ash, :show_keysets_for_all_actions?, false)

    :ok = OpentelemetryBandit.setup()
    :ok = OpentelemetryPhoenix.setup(adapter: :bandit)

    :ok =
      Eatsbot.Repo.config()
      |> Keyword.fetch!(:telemetry_prefix)
      |> OpentelemetryEcto.setup()

    extensions = Application.get_env(:eatsbot, :extensions, [])

    children =
      [
        EatsbotWeb.Telemetry,
        Eatsbot.Repo,
        {DNSCluster, query: Application.get_env(:eatsbot, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Eatsbot.PubSub},
        # Start the Finch HTTP client for sending emails
        {Finch, name: Eatsbot.Finch},
        EatsbotWeb.Endpoint,
        {AshAuthentication.Supervisor, [otp_app: :eatsbot]},
        EatsbotCore.Deliveries.StaleCleaner,
        {Task, fn -> load_config() end}
      ] ++ extensions

    Eatsbot.GeocodingStore.init()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Eatsbot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EatsbotWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  def load_config do
    %{latitude: lat, longitude: lng, name: name} =
      case EatsbotCore.Brands.Branch.read() do
        {:ok, branch_config} -> branch_config
        _ -> %{latitude: 0, longitude: 0, name: "A business"}
      end

    Application.put_env(:eatsbot, :from_location, {lat, lng})
    Application.put_env(:eatsbot, :business_name, name)
  end

  defp register_with_ash(key, module),
    do: Application.put_env(:ash, key, Enum.uniq([module | Application.get_env(:ash, key, [])]))
end

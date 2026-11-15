# Test-only peer for the packaged procurement lifecycle. Run from staged
# apps/dispatch with MIX_ENV=test mix run --no-start <script> <private-config>.
# Every invocation owns a fresh VM and commits Dispatch operations to PostgreSQL.
# The packaged procurement host remains the only canonical business appender.
defmodule ProcurementAcceptance.DispatchPeer do
  import Bitwise, only: [band: 2]
  import Plug.Conn
  import Plug.Test
  require Ash.Query

  alias Dispatch.Accounts.{Organization, Participant, RoleAssignment, User}
  alias Dispatch.Fleet.{Assignment, Load}
  alias Dispatch.{Repo, RestaurantAutomation, RestaurantDelivery}
  alias Dispatch.Support.{ConcurrentSessions, Fixtures, PortalIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  @prefix "PROCUREMENT_DISPATCH_PEER_JSON="
  @schema "procurement-dispatch-peer-v1"
  @scope_fields ~w(origin chapter cooperative key_id seed_file site pickup dropoff)
  @common_fields ["action", "state_file" | @scope_fields]
  @id_fields ~w(tenant_id user_id courier_id courier_role_id service_role_id service_principal_id)
  @portal_path "/ui/restaurant-receipts"
  @session Plug.Session.init(
             store: :cookie,
             key: "_dispatch_session",
             signing_salt: "5xJq0pQe",
             encryption_salt: "Nn4vT2kA"
           )

  def main(argv) do
    try do
      result = run(argv)

      emit(
        Map.merge(result, %{ok: true, source_os_pid: System.pid(), no_canonical_appender: true})
      )
    rescue
      error ->
        # Exceptions can contain private parameters. Keep the runner diagnostic
        # bounded; never print a login token, handoff code, signing seed or URL credentials.
        emit(%{
          ok: false,
          source_os_pid: System.pid(),
          stage: Process.get(:peer_stage, "guard"),
          error: inspect(error.__struct__)
        })

        System.halt(1)
    catch
      kind, _reason ->
        emit(%{
          ok: false,
          source_os_pid: System.pid(),
          stage: Process.get(:peer_stage, "guard"),
          error: Atom.to_string(kind)
        })

        System.halt(1)
    end
  end

  defp run([config_file]) do
    Process.put(:peer_stage, "guard")
    ensure!(Mix.env() == :test and Mix.Project.config()[:app] == :dispatch)
    ensure!(System.get_env("PROCUREMENT_DISPATCH_ACCEPTANCE") == "disposable-local-postgres")
    ensure!(System.get_env("MIX_TEST_PARTITION") in [nil, ""])

    for variable <-
          ~w(PROCUREMENT_ENABLED RESTAURANT_DISPATCH_AUTOMATED PROCUREMENT_DISPATCH_AUTOMATED) do
      ensure!(System.get_env(variable) in [nil, "false"])
    end

    # --no-start is required: validate every input before starting the peer.
    ensure!(:dispatch not in started_apps())
    no_ledger!()
    # The adapter must register its own signing schema. A co-resident host or
    # a previous test must not supply that dependency for this fresh VM.
    ensure!(not CoopSubstrate.Protocol.TypeRegistry.registered?("ProcurementDispatchStepV1"))
    database = database_scope!()
    config = config_file |> private_json!() |> validate_config!()
    scope = scope(config, database)
    state = if config["action"] == "bootstrap", do: nil, else: load_state!(config, scope)

    Process.put(:peer_stage, "start_dispatch")
    {:ok, _} = Application.ensure_all_started(:dispatch)
    no_ledger!()
    ensure!(database_scope!() == database)
    :ok = Sandbox.mode(Repo, :manual)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok = Sandbox.mode(Repo, {:shared, self()})

    try do
      Process.put(:peer_stage, config["action"])

      result =
        case config["action"] do
          "bootstrap" ->
            bootstrap(config, scope)

          "cleanup" ->
            cleanup(config, state)

          action when action in ["worker", "receipt"] ->
            world = owned_world!(state)
            configure_route(config, state)
            if action == "worker", do: worker(config, state), else: receipt(config, state, world)
        end

      no_ledger!()
      result
    after
      Sandbox.checkin(Repo)
    end
  end

  defp run(_), do: raise(ArgumentError, "one private configuration file is required")

  defp validate_config!(config) when is_map(config) do
    extras =
      case config["action"] do
        "bootstrap" -> []
        "cleanup" -> []
        "worker" -> ["order_id"]
        "receipt" -> ~w(order_id phase handoff_token)
        _ -> raise ArgumentError, "invalid peer action"
      end

    ensure!(Enum.sort(Map.keys(config)) == Enum.sort(@common_fields ++ extras))
    ensure!(Path.type(config["state_file"]) == :absolute)
    ensure!(Path.type(config["seed_file"]) == :absolute)
    ensure!(Path.expand(config["state_file"]) == config["state_file"])
    ensure!(Path.expand(config["seed_file"]) == config["seed_file"])
    private_directory!(Path.dirname(config["state_file"]))
    private_file!(config["seed_file"], 256)
    {:ok, <<_::256>>} = config["seed_file"] |> File.read!() |> String.trim() |> Base.decode64()

    for key <- ~w(chapter cooperative key_id), do: ensure!(token?(config[key]))

    for key <- ~w(site pickup dropoff),
        do: ensure!(text?(config[key], if(key == "site", do: 120, else: 500)))

    ensure!(is_binary(config["origin"]))

    %URI{
      scheme: "http",
      host: "127.0.0.1",
      port: port,
      path: path,
      query: nil,
      fragment: nil,
      userinfo: nil
    } = URI.parse(config["origin"])

    ensure!(port in 1..65_535 and path in [nil, ""])
    ensure!(config["origin"] == "http://127.0.0.1:#{port}")

    if config["action"] in ["worker", "receipt"], do: ensure!(order_id?(config["order_id"]))

    if config["action"] == "receipt" do
      ensure!(config["phase"] in ["picked_up", "delivered"])
      ensure!(is_binary(config["handoff_token"]) and byte_size(config["handoff_token"]) == 22)
      {:ok, <<_::128>>} = Base.url_decode64(config["handoff_token"], padding: false)
    end

    config
  end

  defp validate_config!(_), do: raise(ArgumentError, "invalid peer configuration")

  defp database_scope! do
    url = System.get_env("DATABASE_URL")
    ensure!(is_binary(url))
    uri = URI.parse(url)
    ensure!(uri.scheme in ["ecto", "postgres", "postgresql"])
    ensure!(uri.host in ["localhost", "127.0.0.1", "::1"])
    ensure!(uri.path == "/dispatch_test" and uri.port in [nil, 5432])
    ensure!(is_nil(uri.query) and is_nil(uri.fragment))
    config = Repo.config()
    ensure!(config[:database] == "dispatch_test")
    ensure!(config[:hostname] in ["localhost", "127.0.0.1", "::1"])
    ensure!(config[:port] in [nil, 5432] and config[:pool] == Sandbox)
    %{"host" => config[:hostname], "port" => config[:port] || 5432, "database" => "dispatch_test"}
  end

  defp scope(config, database) do
    # Pin the seed file contents without retaining the key in fixture metadata.
    fingerprint =
      :crypto.hash(:sha256, File.read!(config["seed_file"])) |> Base.encode16(case: :lower)

    config
    |> Map.take(@scope_fields)
    |> Map.merge(%{"database" => database, "seed_file_sha256" => fingerprint})
  end

  defp bootstrap(config, scope) do
    id = Ash.UUID.generate()

    state = %{
      "schema" => @schema,
      "status" => "creating",
      "fixture_id" => id,
      "marker" => "procurement-package-peer-" <> id,
      "scope" => scope
    }

    {:ok, file} = File.open(config["state_file"], [:write, :binary, :exclusive])

    try do
      :ok = File.chmod(config["state_file"], 0o600)
      persist(file, state)

      # All fixture rows commit together. Flush their IDs before commit, so a
      # process loss after commit still leaves enough evidence for scoped cleanup.
      {:ok, saved} =
        Repo.transaction(fn ->
          carrier =
            Organization
            |> Ash.Changeset.for_create(:register, %{name: state["marker"], kind: :CARRIER})
            |> Ash.create!(authorize?: false)

          %{user: user, participant: courier} =
            Fixtures.person(carrier.id, carrier, display_name: state["marker"])

          driver = Fixtures.assignment(carrier.id, carrier, courier, "DRIVER")
          service = service_role(carrier.id)

          saved =
            Map.merge(state, %{
              "status" => "ready",
              "tenant_id" => carrier.id,
              "user_id" => user.id,
              "courier_id" => courier.id,
              "courier_role_id" => driver.id,
              "service_role_id" => service.id,
              "service_principal_id" => service.principal_id
            })

          persist(file, saved)
          saved
        end)

      Map.merge(Map.take(saved, @id_fields), %{"action" => "bootstrap"})
    after
      File.close(file)
    end
  end

  defp load_state!(config, scope) do
    state = private_json!(config["state_file"])
    ensure!(is_map(state) and state["schema"] == @schema and state["scope"] == scope)
    {:ok, fixture_id} = Ecto.UUID.cast(state["fixture_id"])
    ensure!(state["marker"] == "procurement-package-peer-" <> fixture_id)

    ensure!(
      state["status"] == "ready" or
        (config["action"] == "cleanup" and state["status"] == "creating")
    )

    if state["status"] == "ready" do
      for key <- @id_fields do
        {:ok, id} = Ecto.UUID.cast(state[key])
        ensure!(id == state[key])
      end
    end

    state
  end

  defp owned_world!(state) do
    tenant = state["tenant_id"]
    carrier = Ash.get!(Organization, tenant, authorize?: false)
    user = Ash.get!(User, state["user_id"], authorize?: false)
    courier = Ash.get!(Participant, state["courier_id"], tenant: tenant, authorize?: false)

    driver =
      Ash.get!(RoleAssignment, state["courier_role_id"],
        tenant: tenant,
        authorize?: false,
        load: [:role_definition]
      )

    service =
      Ash.get!(RoleAssignment, state["service_role_id"],
        tenant: tenant,
        authorize?: false,
        load: [:role_definition]
      )

    ensure!(carrier.kind == :CARRIER and carrier.name == state["marker"])
    ensure!(user.display_name == state["marker"])
    ensure!(courier.user_id == user.id and courier.home_organization_id == tenant)
    ensure!(driver.principal_type == :PARTICIPANT and driver.principal_id == courier.id)

    ensure!(
      driver.organization_id == tenant and driver.scope_type == :SELF and
        driver.role_definition.key == "DRIVER"
    )

    ensure!(
      service.principal_type == :SERVICE and service.principal_id == state["service_principal_id"]
    )

    ensure!(service.organization_id == tenant and service.scope_type == :ORGANIZATION)
    ensure!(service.role_definition.key == "DISPATCHER")
    %{carrier: carrier, user: user, courier: courier, driver: driver, service: service}
  end

  defp configure_route(config, state) do
    System.put_env(%{
      "PROCUREMENT_DISPATCH_AUTOMATED" => "true",
      "PROCUREMENT_DISPATCH_CHAPTER" => config["chapter"],
      "PROCUREMENT_DISPATCH_COOPERATIVE" => config["cooperative"],
      "PROCUREMENT_DISPATCH_TENANT" => state["tenant_id"],
      "PROCUREMENT_DISPATCH_KEY_ID" => config["key_id"],
      "PROCUREMENT_DISPATCH_SEED_FILE" => config["seed_file"],
      "PROCUREMENT_DISPATCH_URL" => config["origin"],
      "PROCUREMENT_DISPATCH_SERVICE_ROLE" => state["service_role_id"],
      "PROCUREMENT_DISPATCH_COURIER" => state["courier_id"],
      "PROCUREMENT_DISPATCH_SITE" => config["site"],
      "PROCUREMENT_DISPATCH_PICKUP" => config["pickup"],
      "PROCUREMENT_DISPATCH_DROPOFF" => config["dropoff"]
    })
  end

  defp worker(config, state) do
    {:ok, worker} = RestaurantAutomation.start_link(:procurement)

    try do
      # Same-sender ordering supplies a barrier after a real worker poll; the
      # timer's initial poll may also execute. Both must use durable state.
      send(worker, :poll)
      {:procurement, ""} = :sys.get_state(worker, 15_000)
    after
      GenServer.stop(worker, :normal, 15_000)
    end

    Map.put(trip_snapshot!(config, state), :action, "worker")
  end

  defp receipt(config, state, world) do
    identity = Application.fetch_env!(:dispatch, :identity)

    Application.put_env(
      :dispatch,
      :identity,
      Keyword.put(identity, :token_verifier, Dispatch.Identity.Tokens.BizKitSession)
    )

    snapshot = trip_snapshot!(config, state)
    page = login(world.user, world.driver)

    response =
      portal(
        :post,
        @portal_path,
        %{
          "_csrf_token" => csrf(page),
          "assignment_id" => snapshot.assignment_id,
          "phase" => config["phase"],
          "handoff_token" => config["handoff_token"]
        },
        page
      )

    ensure!(response.status in [200, 422])
    ensure!(response.status == 200 == String.contains?(response.resp_body, "Handoff recorded."))

    # The controller does not expose or persist the remote proof ID locally.
    # Only offline inspection of the packaged business ledger establishes it.
    trip_snapshot!(config, state)
    |> Map.merge(%{action: "receipt", portal_status: response.status, phase: config["phase"]})
  end

  defp trip_snapshot!(config, state) do
    tenant = state["tenant_id"]

    reference =
      RestaurantDelivery.load_reference(
        config["chapter"],
        config["cooperative"],
        config["order_id"],
        :procurement
      )

    loads = Ash.read!(Load, tenant: tenant, authorize?: false)
    assignments = Ash.read!(Assignment, tenant: tenant, authorize?: false)
    [load] = Enum.filter(loads, &(&1.external_reference == reference))
    ensure!(load.carrier_organization_id == tenant)
    [trip] = Enum.filter(assignments, &(&1.load_id == load.id))
    ensure!(trip.operator_participant_id == state["courier_id"])

    %{
      tenant_id: tenant,
      order_id: config["order_id"],
      load_id: load.id,
      assignment_id: trip.id,
      courier_id: trip.operator_participant_id,
      status: Atom.to_string(trip.status),
      external_reference: reference,
      load_count: length(loads),
      assignment_count: length(assignments)
    }
  end

  defp cleanup(config, %{"status" => "creating"} = state) do
    # A creating-only checkpoint cannot have committed: the complete checkpoint
    # is flushed inside the one fixture transaction before its commit.
    marker = state["marker"]
    [] = Organization |> Ash.Query.filter(name == ^marker) |> Ash.read!(authorize?: false)
    :ok = File.rm(config["state_file"])
    %{action: "cleanup", cleaned_up: true, fixture_committed: false}
  end

  defp cleanup(config, state) do
    tenant = state["tenant_id"]
    user_id = state["user_id"]

    case Organization |> Ash.Query.filter(id == ^tenant) |> Ash.read!(authorize?: false) do
      [] ->
        # A transaction failure after flushing complete IDs also leaves a
        # recoverable checkpoint. Refuse orphaned state instead of deleting
        # identities outside the validated fixture tenant.
        [] = User |> Ash.Query.filter(id == ^user_id) |> Ash.read!(authorize?: false)
        [] = Ash.read!(Participant, tenant: tenant, authorize?: false)
        [] = Ash.read!(RoleAssignment, tenant: tenant, authorize?: false)

      [_carrier] ->
        world = owned_world!(state)
        :ok = Sandbox.checkin(Repo)
        :ok = Sandbox.mode(Repo, :manual)
        :ok = ConcurrentSessions.cleanup(world.carrier, [world.user])

      _ ->
        raise "fixture tenant could not be inspected"
    end

    :ok = File.rm(config["state_file"])
    %{action: "cleanup", cleaned_up: true, tenant_id: tenant}
  end

  defp service_role(tenant) do
    definition = Fixtures.role_definition(tenant, "DISPATCHER")

    RoleAssignment
    |> Ash.Changeset.for_create(:grant, %{
      tenant_id: tenant,
      principal_type: :SERVICE,
      principal_id: Ash.UUID.generate(),
      organization_id: tenant,
      role_definition_id: definition.id,
      scope_type: :ORGANIZATION,
      starts_at: DateTime.add(DateTime.utc_now(), -60)
    })
    |> Ash.create!(authorize?: false, tenant: tenant)
    |> Ash.load!([:role_definition], authorize?: false, tenant: tenant)
  end

  defp login(user, role) do
    form = portal(:get, "/login")
    ensure!(form.status == 200)

    signed_in =
      portal(
        :post,
        "/session",
        %{"_csrf_token" => csrf(form), "token" => PortalIdentity.token_for(user.oidc_subject)},
        form
      )

    ensure!(signed_in.status == 302)
    choose = portal(:get, "/select-role", %{}, signed_in)
    ensure!(choose.status == 200)

    selected =
      portal(
        :post,
        "/select-role",
        %{"_csrf_token" => csrf(choose), "role_assignment_id" => role.id},
        choose
      )

    ensure!(selected.status == 302)
    page = portal(:get, @portal_path, %{}, selected)
    ensure!(page.status == 200)
    page
  end

  defp portal(method, path, params \\ %{}, previous \\ nil) do
    Plug.CSRFProtection.delete_csrf_token()
    request = conn(method, path, params)

    request = %{
      request
      | secret_key_base: Application.fetch_env!(:dispatch, DispatchWeb.Endpoint)[:secret_key_base]
    }

    request = if previous, do: recycle_cookies(request, previous), else: request

    request
    |> Plug.RequestId.call(Plug.RequestId.init(assign_as: :correlation_id))
    |> Plug.Session.call(@session)
    |> fetch_session()
    |> DispatchWeb.Router.call(DispatchWeb.Router.init([]))
  end

  defp csrf(page) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)
    token
  end

  defp private_json!(path) do
    ensure!(is_binary(path) and Path.type(path) == :absolute)
    private_file!(path, 16_384)
    Jason.decode!(File.read!(path))
  end

  defp private_file!(path, maximum) do
    {:ok, info} = File.lstat(path)
    ensure!(info.type == :regular and info.size in 1..maximum and band(info.mode, 0o077) == 0)
  end

  defp private_directory!(path) do
    {:ok, info} = File.lstat(path)
    ensure!(info.type == :directory and band(info.mode, 0o077) == 0)
  end

  defp persist(file, state) do
    {:ok, 0} = :file.position(file, 0)
    :ok = :file.truncate(file)
    :ok = IO.binwrite(file, Jason.encode!(state))
    :ok = :file.sync(file)
  end

  defp no_ledger! do
    ensure!(Enum.all?([:coop_substrate, :procurement_host], &(&1 not in started_apps())))
    ensure!(is_nil(Process.whereis(CoopSubstrate.Supervisor)))
    ensure!(is_nil(Process.whereis(ProcurementHost.Supervisor)))
    ensure!(is_nil(Process.whereis(CoopSubstrate.Log)))
    ensure!(is_nil(GenServer.whereis(CoopSubstrate.Log.server())))
  end

  defp started_apps, do: Enum.map(Application.started_applications(), &elem(&1, 0))
  defp ensure!(true), do: :ok
  defp ensure!(_), do: raise(ArgumentError, "peer precondition failed")

  defp text?(value, size),
    do: is_binary(value) and byte_size(value) in 1..size and String.trim(value) != ""

  defp token?(value), do: text?(value, 128) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value)

  defp order_id?(value),
    do: text?(value, 128) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value)

  defp emit(result) do
    encoded = Jason.encode!(result)
    ensure!(byte_size(encoded) <= 4096)
    IO.puts(@prefix <> encoded)
  end
end

ProcurementAcceptance.DispatchPeer.main(System.argv())

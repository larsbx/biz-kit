defmodule HawalaCapability.EndpointOrchestrationTest do
  use ExUnit.Case, async: false
  alias HawalaCapability.{SignedTestPort, TestCheckoutOutbox}
  @response "hawala/TEST-endpoints/response/v1\0"
  defp config(socket) do
    %{
      seed: :binary.copy(<<1>>, 32),
      service: SignedTestPort.public(:binary.copy(<<2>>, 32)),
      grant: :binary.copy(<<3>>, 32),
      epoch: 1,
      attempt: :binary.copy(<<4>>, 32),
      binding: :binary.copy(<<5>>, 32),
      socket: socket
    }
  end

  defp directory do
    root =
      Path.join(
        System.tmp_dir!(),
        "hawala-endpoint-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp signed_view(c, request, stage, held, authority, paid) do
    b =
      @response <>
        c.service <>
        SignedTestPort.hash(request) <>
        c.attempt <>
        c.binding <>
        <<stage, held, authority, paid, c.epoch::64>>

    b <> :crypto.sign(:eddsa, :none, b, [:binary.copy(<<2>>, 32), :ed25519])
  end

  test "independent Node vectors pin both exact signing domains and all fields" do
    [_, row] =
      File.read!(Path.join(__DIR__, "fixtures/testEndpoints.tsv"))
      |> String.split("\n", trim: true)

    [request, reply] = row |> String.split("\t") |> Enum.map(&Base.decode16!(&1, case: :lower))
    c = config("unused")
    assert request == SignedTestPort.request(c, 1, 1, 100)
    assert {:ok, %{stage: 1, held: false}} = SignedTestPort.verify_response(reply, request, c)
  end

  test "reply verification rejects wrong call, foreign scope and even signed financial claims" do
    c = config("unused")
    request = SignedTestPort.request(c, 1, 1, 100)
    response = signed_view(c, request, 1, 0, 0, 0)
    assert {:ok, %{stage: 1, held: false}} = SignedTestPort.verify_response(response, request, c)
    other = SignedTestPort.request(c, 4, 2, 100)
    assert {:error, _} = SignedTestPort.verify_response(response, other, c)

    for {stage, authority, paid} <- [{4, 0, 0}, {3, 1, 0}, {3, 0, 1}] do
      assert {:error, _} =
               SignedTestPort.verify_response(
                 signed_view(c, request, stage, 0, authority, paid),
                 request,
                 c
               )
    end

    assert {:error, _} =
             SignedTestPort.verify_response(response, request, %{
               c
               | binding: :binary.copy(<<9>>, 32)
             })

    assert {:error, _} =
             SignedTestPort.verify_request(request, %{c | grant: :binary.copy(<<8>>, 32)}, 1)

    assert {:error, _} = SignedTestPort.verify_request(request, c, 2)
  end

  test "unreachable endpoint persists an outbox and blocks replacement mutations across restart" do
    root = directory()
    c = config(Path.join(root, "absent.sock"))
    path = Path.join(root, "outbox.log")
    {:ok, pid} = TestCheckoutOutbox.start(path, c, true)

    assert %{status: :held, pending: true, mutations: 1, paid: false} =
             TestCheckoutOutbox.submit(pid, :create)

    assert {:hold, :query_original_attempt} = TestCheckoutOutbox.submit(pid, :create)
    TestCheckoutOutbox.close(pid)
    {:ok, restored} = TestCheckoutOutbox.start(path, c, false)
    assert %{status: :held, pending: true, mutations: 1} = TestCheckoutOutbox.status(restored)
    assert {:hold, :query_original_attempt} = TestCheckoutOutbox.submit(restored, :prepare)
    assert %{status: :held, pending: true, mutations: 1} = TestCheckoutOutbox.query(restored)
    TestCheckoutOutbox.close(restored)
    assert {:error, _} = TestCheckoutOutbox.start(path, %{c | epoch: 2}, false)
  end

  test "uncertain dispatch append stops the outbox before any network send" do
    root = directory()
    c = config(Path.join(root, "absent.sock"))
    path = Path.join(root, "outbox.log")
    {:ok, pid} = TestCheckoutOutbox.start(path, c, true)
    monitor = Process.monitor(pid)
    log = :sys.get_state(pid).log
    :ok = :disk_log.change_size(log, File.stat!(path).size)
    assert {:hold, _} = TestCheckoutOutbox.submit(pid, :create)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :hold_uncertain_outbox}
    {:ok, restored} = TestCheckoutOutbox.start(path, c, false)
    assert %{stage: 0, mutations: 0, pending: false} = TestCheckoutOutbox.status(restored)
    TestCheckoutOutbox.close(restored)
  end

  @tag :rust_endpoint
  test "real Rust socket lost reply is recovered only by signed status, without another mutation" do
    bin = System.fetch_env!("HAWALA_TEST_SERVICE_BIN")
    root = directory()
    store = Path.join(root, "service")
    socket = Path.join(store, "port")
    c = config(socket)

    args = [
      "--synthetic-only",
      "--initialize",
      "--store",
      store,
      "--loopback-port-file",
      socket,
      "--host-public",
      Base.encode16(SignedTestPort.public(c.seed), case: :lower),
      "--service-seed",
      String.duplicate("02", 32),
      "--grant",
      String.duplicate("03", 32),
      "--epoch",
      "1",
      "--max-requests",
      "4",
      "--drop-first-commit-reply"
    ]

    port =
      Port.open({:spawn_executable, bin}, [:binary, :exit_status, :stderr_to_stdout, args: args])

    on_exit(fn ->
      try do
        Port.close(port)
      catch
        :error, _ -> :ok
      end
    end)

    await_socket(socket, 100)
    c = %{c | socket: {:loopback, socket |> File.read!() |> String.trim() |> String.to_integer()}}
    path = Path.join(root, "outbox.log")
    {:ok, pid} = TestCheckoutOutbox.start(path, c, true)

    assert %{status: :test_proposed, stage: 1, paid: false} =
             TestCheckoutOutbox.submit(pid, :create)

    assert %{status: :test_prepared, stage: 2, paid: false} =
             TestCheckoutOutbox.submit(pid, :prepare)

    assert %{status: :held, stage: 2, pending: true, mutations: 3, paid: false} =
             TestCheckoutOutbox.submit(pid, :commit_intent)

    assert {:hold, :query_original_attempt} = TestCheckoutOutbox.submit(pid, :commit_intent)
    TestCheckoutOutbox.close(pid)
    {:ok, restored} = TestCheckoutOutbox.start(path, c, false)
    assert %{status: :held, pending: true, mutations: 3} = TestCheckoutOutbox.status(restored)

    assert %{
             status: :test_reserved,
             stage: 3,
             pending: false,
             mutations: 3,
             paid: false,
             financial_authority: false
           } = TestCheckoutOutbox.query(restored)

    assert {:error, :phase} = TestCheckoutOutbox.submit(restored, :commit_intent)
    TestCheckoutOutbox.close(restored)
    assert_receive {^port, {:exit_status, 0}}, 3000
  end

  defp await_socket(_path, 0), do: flunk("Rust service did not create its private socket")

  defp await_socket(path, n) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(20)
          await_socket(path, n - 1)
        )
  end
end

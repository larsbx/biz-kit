defmodule CoopSubstrate.WriterFenceTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Log, WriterFence}

  @chapter "chapter-genesis"

  setup do
    gov = new_member("governance")

    {:ok, _} =
      Log.append(
        signed_event(gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.signer.key_id,
          "pubkey" => {:bytes, gov.signer.pubkey}
        })
      )

    {:ok, admin} = raw_conn()
    db = "writer_fence_#{System.unique_integer([:positive])}"
    Postgrex.query!(admin, "CREATE DATABASE #{db}", [])
    opts = Keyword.put(admin_opts(), :database, db)
    {:ok, legacy} = Postgrex.start_link(opts)
    Postgrex.query!(legacy, "CREATE TABLE orders (id int PRIMARY KEY, state text)", [])
    Postgrex.query!(legacy, "CREATE SCHEMA deliveries", [])
    Postgrex.query!(legacy, "CREATE TABLE deliveries.history (id int)", [])
    Postgrex.query!(legacy, "INSERT INTO orders VALUES (1, 'placed')", [])

    on_exit(fn ->
      {:ok, admin} = raw_conn()
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS #{db} WITH (FORCE)", [])
    end)

    %{gov: gov, legacy: legacy, opts: opts, signer: Map.put(gov.signer, :seed, gov.seed)}
  end

  defp admin_opts do
    Application.fetch_env!(:coop_substrate, CoopSubstrate.EventStore)
    |> Keyword.take([:hostname, :port, :username, :password])
  end

  defp refused?(conn, sql) do
    match?(
      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}},
      Postgrex.query(conn, sql, [])
    )
  end

  test "only governance may order a fence, only for a known writer", %{signer: signer} do
    assert {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)

    assert {:error, {:reject, 0, {:unknown_writer, "dispatch"}}} =
             WriterFence.declare(@chapter, "dispatch", "not in the set", signer)

    rogue = new_member("governance")

    assert {:error, {:reject, 0, {:role_key_not_declared, "governance", _}}} =
             WriterFence.declare(
               @chapter,
               "eatsbot",
               "x",
               Map.put(rogue.signer, :seed, rogue.seed)
             )
  end

  test "a chapter without declared governance cannot order a fence" do
    stranger = new_member("governance")
    signer = Map.put(stranger.signer, :seed, stranger.seed)
    head = Log.head()

    assert {:error, {:reject, 0, :no_governance}} =
             WriterFence.declare("chapter-other", "eatsbot", "x", signer)

    assert Log.head() == head
  end

  test "without a ledger order nothing is installed and writes go on", %{legacy: l, opts: opts} do
    assert {:error, :not_ordered} = WriterFence.install(@chapter, "eatsbot", opts)
    assert {:ok, _} = Postgrex.query(l, "INSERT INTO orders VALUES (2, 'placed')", [])
    assert %{rows: [[nil]]} = Postgrex.query!(l, "SELECT to_regclass('biz_kit_writer_fence')", [])
  end

  test "after the fence every write is refused, reads go on, and it is idempotent",
       %{legacy: l, opts: opts, signer: signer} do
    {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)
    {:ok, order} = WriterFence.order(@chapter, "eatsbot")

    assert {:ok, %{tables: 3, event_id: event_id}} =
             WriterFence.install(@chapter, "eatsbot", opts)

    assert event_id == order.event_id

    for sql <- [
          "INSERT INTO orders VALUES (2, 'placed')",
          "UPDATE orders SET state = 'ready'",
          "DELETE FROM orders",
          "TRUNCATE orders",
          "INSERT INTO deliveries.history VALUES (1)",
          "DELETE FROM biz_kit_writer_fence"
        ],
        do: assert(refused?(l, sql), sql)

    assert %{rows: [[1, "placed"]]} = Postgrex.query!(l, "SELECT * FROM orders", [])

    assert %{rows: [["eatsbot", @chapter, ^event_id]]} =
             Postgrex.query!(
               l,
               "SELECT writer, chapter_id, event_id FROM biz_kit_writer_fence",
               []
             )

    Postgrex.query!(l, "CREATE TABLE later (id int)", [])
    assert {:ok, %{tables: 4}} = WriterFence.install(@chapter, "eatsbot", opts)
    assert refused?(l, "INSERT INTO later VALUES (1)")
  end

  test "a write in flight at cutover commits before the fence; none after it",
       %{legacy: l, opts: opts, signer: signer} do
    {:ok, _} = WriterFence.declare(@chapter, "eatsbot", "R5 cutover", signer)
    parent = self()

    writer =
      Task.async(fn ->
        Postgrex.transaction(l, fn conn ->
          Postgrex.query!(conn, "INSERT INTO orders VALUES (2, 'placed')", [])
          send(parent, :writing)
          receive do: (:commit -> :ok)
        end)
      end)

    assert_receive :writing
    fence = Task.async(fn -> WriterFence.install(@chapter, "eatsbot", opts) end)
    refute Task.yield(fence, 300), "the fence must wait for the writer holding the table"
    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)
    assert {:ok, %{tables: 3}} = Task.await(fence)

    assert %{rows: [[2]]} = Postgrex.query!(l, "SELECT count(*) FROM orders", [])
    assert refused?(l, "INSERT INTO orders VALUES (3, 'placed')")
  end

  test "mix coop.fence_writer signs the order with the governance key and fences", %{
    gov: existing,
    legacy: l,
    opts: opts
  } do
    dir = Path.join(System.tmp_dir!(), "fence-keys-#{System.unique_integer([:positive])}")
    previous = System.get_env("HARNESS_KEYS_DIR")
    System.put_env("HARNESS_KEYS_DIR", dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      File.rm_rf!(dir)
      Mix.shell(Mix.Shell.IO)

      if previous,
        do: System.put_env("HARNESS_KEYS_DIR", previous),
        else: System.delete_env("HARNESS_KEYS_DIR")
    end)

    {:ok, _} = CoopSubstrate.Harness.Ops.gen_key("governance")
    {:ok, gov} = CoopSubstrate.Harness.Ops.load_signer("governance")

    {:ok, _} =
      Log.append(
        signed_event(existing, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.key_id,
          "pubkey" => {:bytes, gov.pubkey}
        })
      )

    url =
      "postgres://#{URI.encode_www_form(opts[:username])}:#{URI.encode_www_form(opts[:password] || "")}" <>
        "@#{opts[:hostname]}:#{opts[:port] || 5432}/#{opts[:database]}"

    run =
      &Mix.Tasks.Coop.FenceWriter.run([
        "eatsbot",
        "--chapter",
        @chapter,
        "--database-url",
        url | &1
      ])

    assert_raise Mix.Error, ~r/--reason is required/, fn -> run.(["--yes"]) end
    assert {:error, :not_ordered} = WriterFence.order(@chapter, "eatsbot")

    run.(["--reason", "R5 cutover", "--yes"])
    assert_received {:mix_shell, :info, ["Order the fence of eatsbot" <> _]}
    assert_received {:mix_shell, :info, ["fenced: eatsbot, 3 tables, order " <> _]}
    assert {:ok, %{signers: [%{key_id: key_id}]}} = WriterFence.order(@chapter, "eatsbot")
    assert key_id == gov.key_id
    assert refused?(l, "INSERT INTO orders VALUES (2, 'placed')")
  end
end

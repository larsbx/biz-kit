defmodule FederationService.TestHelpers do
  alias FederationCore.Marketplace, as: M
  def key, do: :public_key.generate_key({:rsa, 2048, 65537})

  def metadata(actor \\ "https://alpha.example/actors/shop", revision \\ 0, overrides \\ %{}) do
    {:ok, m} =
      M.metadata(
        Map.merge(
          %{
            seller_actor: actor,
            listing_id: "https://" <> URI.parse(actor).host <> "/listings/part",
            revision: revision,
            title: "Part",
            summary: "Public listing",
            category: "parts",
            price: %{currency: "USD", minor_units: 1250}
          },
          overrides
        )
      )

    m
  end

  def activity(m, id \\ "one", kind \\ :create) do
    {:ok, a} = M.publish(kind, m, m["seller"] <> "/activities/" <> id, m["id"] <> ".json")
    a
  end

  def stop_store(store) do
    try do
      GenServer.stop(store)
    catch
      :exit, _ -> :ok
    end
  end

  def temp do
    p = Path.join(System.tmp_dir!(), "federation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(p)
    p
  end

  def enqueue(store, a, at \\ 1000) do
    {:ok, c} = M.decode_verified(a, %{verified_actor: a["actor"]})

    FederationService.Store.call(
      store,
      {:enqueue, a, c, :crypto.hash(:sha256, Jason.encode!(a)), at}
    )
  end

  # Literal transaction format written by #154/#155 (before subscription_outbox).
  # Do not use the current planner to create this upgrade fixture.
  def legacy_follow_journal(dir, follow, status \\ :pending) do
    id = follow["id"]

    row = %{
      direction: :outgoing,
      follower: follow["actor"],
      target: follow["object"],
      follow: follow,
      status: :pending,
      started_at: 1000,
      authority: nil
    }

    receipt = fn activity ->
      {:subscription_events, activity["id"],
       %{hash: :crypto.hash(:sha256, :erlang.term_to_binary(activity)), follow_id: id}}
    end

    first = {:transaction, [{:subscriptions, id, row}, receipt.(follow)]}

    entries =
      if status == :pending do
        [first]
      else
        {:ok, activity} =
          case status do
            :withdrawn ->
              FederationCore.Subscriptions.undo(row.follower, follow, id <> "-undo")

            decision when decision in [:accepted, :rejected] ->
              FederationCore.Subscriptions.respond(
                if(decision == :accepted, do: :accept, else: :reject),
                row.target,
                follow,
                row.target <>
                  "/activities/legacy-reply-" <>
                  Base.encode16(:crypto.hash(:sha256, id), case: :lower)
              )
          end

        row = %{
          row
          | status: status,
            authority: if(status == :withdrawn, do: "legacy-host-receipt", else: nil)
        }

        [first, {:transaction, [{:subscriptions, id, row}, receipt.(activity)]}]
      end

    append_journal(dir, entries)
    follow
  end

  def append_journal(dir, entries) do
    File.mkdir_p!(dir)
    log = {:legacy_fixture, dir}
    {:ok, ^log} = :disk_log.open(name: log, file: String.to_charlist(dir <> "/discovery.log"))
    :ok = :disk_log.log_terms(log, entries)
    :ok = :disk_log.sync(log)
    :ok = :disk_log.close(log)
  end

  def certs(dir) do
    # Ephemeral test CA/leaf only. No fixture private key enters the repository.
    {_, 0} =
      System.cmd(
        "openssl",
        ~w(req -x509 -newkey rsa:2048 -nodes -keyout) ++
          [
            dir <> "/ca.key",
            "-out",
            dir <> "/ca.pem",
            "-days",
            "1",
            "-subj",
            "/CN=Federation harness CA"
          ],
        stderr_to_stdout: true
      )

    for name <- ["alpha.example", "beta.example"] do
      {_, 0} =
        System.cmd(
          "openssl",
          [
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            dir <> "/#{name}.key",
            "-out",
            dir <> "/#{name}.csr",
            "-subj",
            "/CN=#{name}"
          ],
          stderr_to_stdout: true
        )

      File.write!(dir <> "/ext", "subjectAltName=DNS:#{name}\n")

      {_, 0} =
        System.cmd(
          "openssl",
          [
            "x509",
            "-req",
            "-in",
            dir <> "/#{name}.csr",
            "-CA",
            dir <> "/ca.pem",
            "-CAkey",
            dir <> "/ca.key",
            "-CAcreateserial",
            "-out",
            dir <> "/#{name}.pem",
            "-days",
            "1",
            "-extfile",
            dir <> "/ext"
          ],
          stderr_to_stdout: true
        )
    end

    [entry] = :public_key.pem_decode(File.read!(dir <> "/ca.pem"))
    elem(entry, 1)
  end
end

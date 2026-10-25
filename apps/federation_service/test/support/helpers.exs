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

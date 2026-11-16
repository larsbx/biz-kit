defmodule ScfHost.HTTPTest do
  @moduledoc "Real HTTP forms, cookie session, CSRF and bearer API over the canonical Log."
  use CoopSubstrate.LogCase, async: false
  import Plug.Test
  alias CoopSubstrate.{Log, ProcurementTestClock, Scf}
  alias ScfHost.Web

  @now 1_800_000_000_000
  @chapter "scf-http"
  @entity "sarl-atlas"
  @token String.duplicate("t", 48)
  @api_token String.duplicate("a", 48)

  setup do
    ProcurementTestClock.set(@now)
    :ok = Scf.register_types!()
    gov = new_member("governance", "gov")
    accountant = new_member("scf_accountant", "accountant-key")

    gov_event =
      &signed_event(gov, &1, Map.put(&2, "entity_id", @entity),
        chapter_id: @chapter,
        timestamp_ms: @now
      )

    {:ok, [_]} =
      Log.append(
        signed_event(
          gov,
          "RoleKeyDeclared",
          %{"role" => "governance", "key_id" => "gov", "pubkey" => {:bytes, gov.signer.pubkey}},
          chapter_id: @chapter,
          timestamp_ms: @now
        )
      )

    {:ok, [_]} = Log.append(gov_event.("ScfBookOpenedV1", %{"first_year" => 2026}))

    grant = fn active, version ->
      Log.append(
        gov_event.("ScfAccountantGrantedV1", %{
          "accountant_id" => "comptable",
          "key_id" => accountant.signer.key_id,
          "pubkey" => {:bytes, accountant.signer.pubkey},
          "active" => active,
          "expires_at_ms" => @now + 7_200_000,
          "expected_version" => version
        })
      )
    end

    {:ok, [_]} = grant.(true, 0)

    Application.put_env(:scf_host, :settings, %{
      chapter_id: @chapter,
      entity_id: @entity,
      accountant_id: "comptable",
      key_id: accountant.signer.key_id,
      seed: accountant.seed,
      grant_version: 1,
      login_digest: :crypto.hash(:sha256, @token),
      api_digest: :crypto.hash(:sha256, @api_token),
      secret_key_base: String.duplicate("s", 64)
    })

    {:ok, revoke: fn -> grant.(false, 1) end}
  end

  defp request(method, path, params \\ %{}, previous \\ nil, headers \\ []) do
    Plug.CSRFProtection.delete_csrf_token()
    c = conn(method, path, params) |> Map.put(:scheme, :https)
    c = Enum.reduce(headers, c, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    c = if previous, do: recycle_cookies(c, previous), else: c
    Web.call(c, Web.init([]))
  end

  defp csrf(c), do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, c.resp_body) |> Enum.at(1)

  defp field(c, name),
    do: Regex.run(~r/name="#{name}" value="([^"]+)"/, c.resp_body) |> Enum.at(1)

  defp login do
    form = request(:get, "/login")
    request(:post, "/login", %{"token" => @token, "_csrf_token" => csrf(form)}, form)
  end

  defp upload(content) do
    path = Path.join(System.tmp_dir!(), "piece-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    %Plug.Upload{path: path, filename: "piece.pdf", content_type: "application/pdf"}
  end

  defp api(method, path, body \\ %{}) do
    c = conn(method, path, Jason.encode!(body)) |> Map.put(:scheme, :https)

    c =
      c
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @api_token)

    r = Web.call(c, Web.init([]))
    {r.status, Jason.decode!(r.resp_body)}
  end

  defp put_piece(bytes, claimed \\ nil) do
    digest = claimed || Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    c =
      conn(:put, "/api/v1/pieces", bytes)
      |> Map.put(:scheme, :https)
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_req_header("x-content-sha256", digest)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @api_token)

    r = Web.call(c, Web.init([]))
    {r.status, Jason.decode!(r.resp_body)}
  end

  test "unauthenticated pages redirect to sign-in; wrong tokens are refused; headers are strict" do
    assert %{status: 303} = c = request(:get, "/journal")
    assert Plug.Conn.get_resp_header(c, "location") == ["/login"]
    form = request(:get, "/login")
    assert Plug.Conn.get_resp_header(form, "cache-control") == ["no-store"]
    assert [csp] = Plug.Conn.get_resp_header(form, "content-security-policy")
    assert csp =~ "default-src 'none'"

    refused =
      request(
        :post,
        "/login",
        %{"token" => String.duplicate("x", 48), "_csrf_token" => csrf(form)},
        form
      )

    assert refused.status == 401
    refute refused.resp_body =~ @token
  end

  test "a form écriture with an uploaded pièce is signed, admitted and reported", %{
    revoke: revoke
  } do
    session = login()
    assert session.status == 303
    form = request(:get, "/ecriture", %{}, session)
    assert form.status == 200

    params = %{
      "_csrf_token" => csrf(form),
      "command_id" => field(form, "command_id"),
      "journal" => "OD",
      "date" => "2026-03-05",
      "label" => "<script>alert(1)</script>",
      "piece" => "statuts",
      "document" => upload("statuts signés"),
      "lines" => %{
        "0" => %{"account" => "512", "debit" => "1 000 000,00", "credit" => ""},
        "1" => %{"account" => "101", "debit" => "", "credit" => "1 000 000,00"},
        "2" => %{"account" => "", "debit" => "", "credit" => ""}
      }
    }

    assert %{status: 303} = request(:post, "/ecriture", params, form)
    # Resubmitting the same form is an idempotent retry, not a second écriture.
    assert %{status: 303} = request(:post, "/ecriture", params, form)

    journal = request(:get, "/journal", %{}, session)
    assert journal.resp_body =~ "1 000 000,00 DA"
    assert journal.resp_body =~ "&lt;script&gt;"
    refute journal.resp_body =~ "<script>alert"
    assert length(Regex.scan(~r/Contrepasser l'écriture/, journal.resp_body)) == 1

    # The pièce stays on this machine and opens from the journal.
    hex = Base.encode16(:crypto.hash(:sha256, "statuts signés"), case: :lower)
    assert journal.resp_body =~ ~s(href="/pieces/#{hex}")
    piece = request(:get, "/pieces/#{hex}", %{}, session)
    assert piece.status == 200 and piece.resp_body == "statuts signés"
    assert ["attachment" <> _] = Plug.Conn.get_resp_header(piece, "content-disposition")

    # Only pièces this book cites are served, and only to the accountant.
    {:ok, other} = CoopSubstrate.Harness.Artifacts.put("autre chose")

    assert %{status: 404} =
             request(:get, "/pieces/#{Base.encode16(other, case: :lower)}", %{}, session)

    assert %{status: 303} = request(:get, "/pieces/#{hex}")

    balance = request(:get, "/balance", %{}, session)
    assert balance.resp_body =~ "Capital émis"
    etats = request(:get, "/etats", %{}, session)
    assert etats.resp_body =~ "Total actif"

    # The ledger grant, not the cookie, is authoritative.
    {:ok, [_]} = revoke.()
    assert %{status: 303} = request(:get, "/journal", %{}, session)
  end

  test "SCF refusals are shown to the accountant and nothing is appended" do
    session = login()
    form = request(:get, "/ecriture", %{}, session)
    head = Log.head()

    unbalanced = %{
      "_csrf_token" => csrf(form),
      "command_id" => field(form, "command_id"),
      "journal" => "OD",
      "date" => "2026-03-05",
      "label" => "x",
      "piece" => "p",
      "document" => upload("p"),
      "lines" => %{
        "0" => %{"account" => "512", "debit" => "10", "credit" => ""},
        "1" => %{"account" => "101", "debit" => "", "credit" => "9"}
      }
    }

    refused = request(:post, "/ecriture", unbalanced, form)
    assert refused.status == 422
    assert refused.resp_body =~ "≠ total crédit"
    assert Log.head() == head

    missing_csrf = Map.delete(unbalanced, "_csrf_token")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      request(:post, "/ecriture", missing_csrf, form)
    end
  end

  test "contrepassation from the journal, and the JSON API end to end" do
    lines = [
      %{"side" => "debit", "account" => "60", "amount_minor" => 300_00},
      %{"side" => "debit", "account" => "4456", "amount_minor" => 57_00},
      %{"side" => "credit", "account" => "401", "amount_minor" => 357_00}
    ]

    entry = %{
      "kind" => "entry",
      "command_id" => "api-1",
      "journal" => "AC",
      "date" => "2026-03-05",
      "label" => "Achat",
      "piece" => "FA-1",
      "document_sha256" => String.duplicate("0f", 32),
      "lines" => lines
    }

    # Citing bytes this machine does not hold is refused by the Log itself.
    assert {422, %{"error" => "{:scf_document_unavailable, :not_found}"}} =
             api(:post, "/api/v1/commands", entry)

    assert {422, %{"error" => "digest_mismatch"}} =
             put_piece("facture FA-1", String.duplicate("0", 64))

    assert {201, %{"sha256" => sha}} = put_piece("facture FA-1")
    assert {201, %{"sha256" => ^sha}} = put_piece("facture FA-1")
    entry = %{entry | "document_sha256" => sha}

    assert {201, %{"status" => "admitted"}} = api(:post, "/api/v1/commands", entry)
    assert {201, _} = api(:post, "/api/v1/commands", entry)

    assert {422, %{"error" => ":scf_idempotency_conflict"}} =
             api(:post, "/api/v1/commands", %{entry | "label" => "autre"})

    assert {422, %{"error" => "invalid_entry"}} =
             api(:post, "/api/v1/commands", %{
               entry
               | "command_id" => "api-2",
                 "lines" => tl(lines)
             })

    assert {200, %{"journal" => [%{"sequence" => seq, "lines" => [%{"account" => "60"} | _]}]}} =
             api(:get, "/api/v1/journal")

    assert {200, %{"g50" => %{"deductible" => 5_700}, "bilan" => bilan}} =
             api(:get, "/api/v1/statements?mois=2026-03")

    assert bilan["total_actif"] == bilan["total_passif"]

    session = login()
    journal = request(:get, "/journal", %{}, session)

    reversal = %{
      "_csrf_token" => csrf(journal),
      "command_id" => "rev-#{seq}",
      "date" => "2026-03-06",
      "piece" => "AV-1",
      "document" => upload("avoir")
    }

    assert %{status: 303} = request(:post, "/journal/#{seq}/contrepasser", reversal, journal)
    assert {200, %{"trial_balance" => %{"rows" => rows}}} = api(:get, "/api/v1/statements")
    assert Enum.all?(rows, &(&1["balance"] == 0))

    assert {401, _} =
             (fn ->
                r =
                  Web.call(
                    conn(:get, "/api/v1/journal") |> Map.put(:scheme, :https),
                    Web.init([])
                  )

                {r.status, r.resp_body}
              end).()
  end
end

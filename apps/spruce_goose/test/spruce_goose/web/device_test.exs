defmodule SpruceGoose.Web.DeviceTest do
  @moduledoc """
  Self-service device enrolment over HTTP
  (docs/architecture/2026-10-19-device-enrolment.md): the person's device asks
  and proves its key; the administrator approves by code with the governance
  key, through the same client `mix coop.enrol` uses, against a running server.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Canonical, Crypto, Feed}
  alias CoopSubstrate.Enrolments.Approver

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    bind([{"https://idp.test", "sub-person", person}])

    Map.merge(w, %{
      person: person,
      device: member("operator"),
      session: session!("second", "sub-person"),
      base: serve!()
    })
  end

  defp devices_path(w),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/devices"

  defp post_json(path, cookie, body) do
    headers = [
      {"content-type", "application/json"} | if(cookie, do: [{"cookie", cookie}], else: [])
    ]

    conn = call(:post, path, headers, Jason.encode!(body))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp status(w) do
    conn = call(:get, devices_path(w) <> "/" <> w.device.signer.key_id, [{"cookie", w.session}])
    Jason.decode!(conn.resp_body)
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp ask(w, member \\ nil, label \\ "Work laptop") do
    member = member || w.device

    post_json(devices_path(w), w.session, %{
      "key_id" => member.signer.key_id,
      "public_key" => b64(member.signer.pubkey),
      "label" => label
    })
  end

  # What the device does: decode the statement, sign it.
  defp prove(w, %{"id" => id, "statement" => statement}, member) do
    bytes = Base.url_decode64!(statement, padding: false)

    post_json("/api/v1/devices/challenges/#{id}", w.session, %{
      "signature" => b64(Crypto.sign(bytes, member.seed))
    })
  end

  defp request!(w) do
    {201, challenge} = ask(w)
    {201, request} = prove(w, challenge, w.device)
    request
  end

  defp governance(w),
    do: %{key_id: w.gov.signer.key_id, pubkey: w.gov.signer.pubkey, seed: w.gov.seed}

  test "a device asks, an administrator approves by code, the person can read", w do
    assert status(w) == %{"status" => "none"}

    assert Feed.authorize_principal(w.person, {w.chapter, tenant(), "project-1"}) ==
             {:error, :no_grant}

    {201, challenge} = ask(w)

    {:ok, statement} =
      challenge["statement"] |> Base.url_decode64!(padding: false) |> Canonical.decode()

    assert %{"schema" => "CoopDeviceEnrolmentV1", "principal_id" => principal} = statement
    assert principal == w.person

    {201, %{"code" => code}} = prove(w, challenge, w.device)
    assert %{"status" => "pending", "code" => ^code} = status(w)

    assert {:ok, details} = Approver.fetch(w.base, code)
    assert details["principal_id"] == w.person
    assert details["identity"] == %{"issuer" => "https://idp.test", "subject" => "sub-person"}
    assert details["label"] == "Work laptop"

    assert {:ok, %{"event_id" => _}} = Approver.approve(w.base, details, governance(w))
    assert status(w) == %{"status" => "enrolled"}
    assert {:ok, _reader} = Feed.authorize_principal(w.person, {w.chapter, tenant(), "project-1"})
  end

  test "mix coop.enrol approves with the governance key on this machine", w do
    %{"code" => code} = request!(w)
    dir = Path.join(System.tmp_dir!(), "coop-enrol-" <> code)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "governance.seed"), Base.encode16(w.gov.seed, case: :lower))
    System.put_env("HARNESS_KEYS_DIR", dir)

    on_exit(fn ->
      System.delete_env("HARNESS_KEYS_DIR")
      File.rm_rf!(dir)
    end)

    output =
      capture_io(fn ->
        Mix.Task.rerun("coop.enrol", [code, "--server", w.base, "--yes"])
      end)

    assert output =~ "principal  #{w.person}"
    assert output =~ "device     Work laptop"
    assert output =~ "granted: event"
    assert status(w) == %{"status" => "enrolled"}
  end

  describe "refused" do
    test "without a session", w do
      assert {401, _} =
               post_json(devices_path(w), nil, %{
                 "key_id" => w.device.signer.key_id,
                 "public_key" => b64(w.device.signer.pubkey),
                 "label" => "x"
               })
    end

    test "for a key ID that does not name the key, a bad key or label", w do
      assert {400, %{"error" => "key_id_mismatch"}} =
               post_json(devices_path(w), w.session, %{
                 "key_id" => "k-00000000",
                 "public_key" => b64(w.device.signer.pubkey),
                 "label" => "x"
               })

      assert {400, _} = ask(w, nil, "")

      assert {400, _} =
               post_json(devices_path(w), w.session, %{
                 "key_id" => 1,
                 "public_key" => "!",
                 "label" => "x"
               })
    end

    test "a proof by another key", w do
      {201, challenge} = ask(w)
      assert {422, %{"error" => "bad_proof"}} = prove(w, challenge, w.agent)
    end

    test "an unknown code, or a key that is not governance", w do
      assert {:error, {404, _}} = Approver.fetch(w.base, "AAAA-AAAA-AAAA")

      {:ok, details} = Approver.fetch(w.base, request!(w)["code"])
      impostor = member("governance")

      signer = %{
        key_id: impostor.signer.key_id,
        pubkey: impostor.signer.pubkey,
        seed: impostor.seed
      }

      assert {:error, {422, _}} = Approver.approve(w.base, details, signer)
      assert %{"status" => "pending"} = status(w)
    end
  end

  test "the approver signs only the grant it was shown", w do
    {:ok, details} = Approver.fetch(w.base, request!(w)["code"])
    signer = governance(w)

    grant = %{
      "type" => "TaskOperatorGrantedV1",
      "chapter_id" => details["chapter_id"],
      "signers" => [
        %{"role" => "governance", "key_id" => signer.key_id, "pubkey" => {:bytes, signer.pubkey}}
      ],
      "payload" => %{
        "tenant_id" => details["tenant_id"],
        "project_id" => details["project_id"],
        "principal_id" => details["principal_id"],
        "key_id" => details["key_id"],
        "pubkey" => {:bytes, Base.url_decode64!(details["public_key"], padding: false)}
      }
    }

    assert Approver.matches(grant, details, signer) == :ok

    for tampered <- [
          put_in(grant, ["payload", "principal_id"], "prn_someoneelse"),
          put_in(grant, ["payload", "project_id"], "project-2"),
          put_in(grant, ["payload", "pubkey"], {:bytes, w.agent.signer.pubkey}),
          Map.put(grant, "type", "TaskSuggesterGrantedV1"),
          Map.update!(grant, "signers", &(&1 ++ &1))
        ] do
      assert Approver.matches(tampered, details, signer) ==
               {:error, :grant_does_not_match_request}
    end
  end
end

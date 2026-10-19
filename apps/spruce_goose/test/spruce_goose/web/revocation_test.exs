defmodule SpruceGoose.Web.RevocationTest do
  @moduledoc """
  Revoking devices over HTTP (docs/architecture/2026-10-19-device-revocation.md):
  a person revokes a lost device from another of theirs, signed by that
  device; an administrator revokes any grant with the governance key, through
  the client `mix coop.revoke` uses, against a running server.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Feed}
  alias CoopSubstrate.Devices.Revoker
  alias CoopSubstrate.Governance.Client

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    bind([{"https://idp.test", "sub-person", person}])
    laptop = member("operator")
    phone = member("operator")

    Map.merge(w, %{
      person: person,
      laptop: laptop,
      phone: phone,
      laptop_grant: device!(w, laptop, person, "Laptop"),
      phone_grant: device!(w, phone, person, "Phone"),
      session: session!("second", "sub-person"),
      base: serve!()
    })
  end

  defp devices_path(w),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/devices"

  defp post_json(path, cookie, body) do
    conn =
      call(
        :post,
        path,
        [{"content-type", "application/json"}, {"cookie", cookie}],
        Jason.encode!(body)
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp devices(w) do
    conn = call(:get, devices_path(w), [{"cookie", w.session}])
    conn.resp_body |> Jason.decode!() |> Enum.map(& &1["label"]) |> Enum.sort()
  end

  # From the device `signing`: prepare, decode-and-sign, submit.
  defp revoke(w, target, signing) do
    with {201, held} <-
           post_json("#{devices_path(w)}/#{target.event_id}/revocation", w.session, %{
             "key_id" => signing.signer.key_id
           }) do
      bytes = Base.url_decode64!(held["signing_bytes"], padding: false)
      signature = Base.url_encode64(Crypto.sign(bytes, signing.seed), padding: false)
      post_json("/api/v1/commands/#{held["id"]}", w.session, %{"signature" => signature})
    end
  end

  test "a person lists their devices and revokes a lost one from another", w do
    assert devices(w) == ["Laptop", "Phone"]

    assert {201, _} = revoke(w, w.laptop_grant, w.phone)

    assert devices(w) == ["Phone"]

    assert {:ok, %{grant_id: grant}} =
             Feed.authorize_principal(w.person, {w.chapter, tenant(), "project-1"})

    assert grant == w.phone_grant.event_id
  end

  test "a device can retire itself; the person then has none", w do
    assert {201, _} = revoke(w, w.laptop_grant, w.laptop)
    assert {201, _} = revoke(w, w.phone_grant, w.phone)
    assert devices(w) == []
  end

  test "never another person's device, nor from a device that is not enrolled", w do
    other = device!(w, member("operator"), Principal.new_id(), "Not mine")

    assert {404, %{"error" => "unknown_device"}} = revoke(w, other, w.phone)
    assert {403, %{"error" => "no_device"}} = revoke(w, w.laptop_grant, w.agent)
    assert devices(w) == ["Laptop", "Phone"]
  end

  test "an administrator revokes with mix coop.revoke", w do
    governance_keys!(w)

    output =
      capture_io(fn ->
        Mix.Task.rerun("coop.revoke", [w.laptop_grant.event_id, "--server", w.base, "--yes"])
      end)

    assert output =~ "principal  #{w.person}"
    assert output =~ "device     Laptop"
    assert output =~ "revoked: event"
    assert devices(w) == ["Phone"]

    assert {:error, {409, _}} =
             Revoker.revoke(w.base, %{"grant_id" => w.laptop_grant.event_id}, governance(w))
  end

  test "only a declared governance key, and only the revocation it was shown", w do
    {:ok, details} = Revoker.fetch(w.base, w.laptop_grant.event_id)
    assert {details["label"], details["active"]} == {"Laptop", true}

    impostor = member("governance")

    signer = %{
      key_id: impostor.signer.key_id,
      pubkey: impostor.signer.pubkey,
      seed: impostor.seed
    }

    assert {:error, {422, _}} = Revoker.revoke(w.base, details, signer)

    revocation = %{
      "type" => "TaskOperatorRevokedV1",
      "chapter_id" => details["chapter_id"],
      "payload" => %{
        "tenant_id" => details["tenant_id"],
        "project_id" => details["project_id"],
        "authorization_event_id" => details["grant_id"]
      }
    }

    assert Revoker.revokes?(revocation, details)

    refute Revoker.revokes?(
             put_in(revocation, ["payload", "authorization_event_id"], w.phone_grant.event_id),
             details
           )

    refute Revoker.revokes?(Map.put(revocation, "type", "TaskOperatorGrantedV1"), details)
    refute Client.signed_by?(%{"signers" => []}, governance(w))

    assert {:error, {404, _}} = Revoker.fetch(w.base, "no-such-grant")
    assert devices(w) == ["Laptop", "Phone"]
  end

  test "mix coop.revoke also revokes a reviewer device", w do
    reviewer = member("reviewer")

    grant =
      grant!(w, "TaskReviewerGrantedV1", reviewer, w.person, "project-1", %{
        "device_label" => "Review tablet"
      })

    governance_keys!(w)

    output =
      capture_io(fn ->
        Mix.Task.rerun("coop.revoke", [grant.event_id, "--server", w.base, "--yes"])
      end)

    assert output =~ "Reviewer grant #{grant.event_id}"
    assert output =~ "device     Review tablet"
    assert output =~ "revoked: event"
    refute CoopSubstrate.Log.gate().orchestration.dod_grants[grant.event_id].active
  end

  describe "own devices of every kind (docs/architecture/2026-10-19-own-devices.md)" do
    test "a reviewer device revokes itself; an operator device the person's administrator key",
         w do
      tablet = member("reviewer")

      reviewer_grant =
        grant!(w, "TaskReviewerGrantedV1", tablet, w.person, "project-1", %{
          "device_label" => "Tablet"
        })

      browser = member("governance")

      [_] =
        append!(
          event(w, w.gov, "RoleKeyDeclared", %{
            "role" => "governance",
            "key_id" => browser.signer.key_id,
            "pubkey" => {:bytes, browser.signer.pubkey},
            "member_id" => w.person
          })
        )

      assert devices(w) == [nil, "Laptop", "Phone", "Tablet"]

      assert {201, _} = revoke(w, %{event_id: reviewer_grant.event_id}, tablet)
      refute CoopSubstrate.Log.gate().orchestration.dod_grants[reviewer_grant.event_id].active

      assert {201, _} = revoke(w, %{event_id: browser.signer.key_id}, w.laptop)

      refute Map.has_key?(
               CoopSubstrate.Log.gate().role_keys[{w.chapter, "governance"}],
               browser.signer.key_id
             )

      assert devices(w) == ["Laptop", "Phone"]
    end
  end
end

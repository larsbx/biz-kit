defmodule SpruceGoose.Web.AdministrationTest do
  @moduledoc """
  Administration from a browser key (docs/architecture/2026-10-19-administration.md):
  the first administrator's browser is approved by the holder of the
  governance seed (`mix coop.enrol`, the bootstrap); from then on its key
  signs as governance through the same endpoints, lists and revokes the
  chapter's administrators, and lists its projects.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}
  alias CoopSubstrate.Governance.Client

  setup do
    providers!()
    w = world()
    admin = Principal.new_id()
    bind([{"https://idp.test", "sub-admin", admin}])

    Map.merge(w, %{
      admin: admin,
      browser: member("governance"),
      session: session!("second", "sub-admin"),
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

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp status(w) do
    conn =
      call(:get, devices_path(w) <> "/" <> w.browser.signer.key_id <> "?role=governance", [
        {"cookie", w.session}
      ])

    Jason.decode!(conn.resp_body)
  end

  defp signer(member),
    do: %{key_id: member.signer.key_id, pubkey: member.signer.pubkey, seed: member.seed}

  # The browser asks for administrator access and proves its key; the seed
  # holder approves the code with `mix coop.enrol`.
  defp administrator!(w) do
    {201, challenge} =
      post_json(devices_path(w), w.session, %{
        "key_id" => w.browser.signer.key_id,
        "public_key" => b64(w.browser.signer.pubkey),
        "label" => "Office browser",
        "role" => "governance"
      })

    statement = Base.url_decode64!(challenge["statement"], padding: false)

    {201, %{"code" => code}} =
      post_json("/api/v1/devices/challenges/#{challenge["id"]}", w.session, %{
        "signature" => b64(Crypto.sign(statement, w.browser.seed))
      })

    assert %{"status" => "pending"} = status(w)
    governance_keys!(w)

    capture_io(fn -> Mix.Task.rerun("coop.enrol", [code, "--server", w.base, "--yes"]) end)
  end

  test "the seed holder approves the first administrator's browser; its key then governs", w do
    output = administrator!(w)
    assert output =~ "Grant it governance access"
    assert output =~ "granted: event"
    assert status(w) == %{"status" => "enrolled"}

    url = w.base <> "/api/v1/chapters/#{w.chapter}/administrators"

    assert {:ok, keys} = Client.get_signed(url, signer(w.browser))

    assert %{"principal_id" => admin} =
             Enum.find(keys, &(&1["key_id"] == w.browser.signer.key_id))

    assert admin == w.admin

    # As governance, it offboards someone: the same signed endpoints as ever.
    someone = member("operator")
    grant!(w, "TaskOperatorGrantedV1", someone, "prn_someone", "project-1")
    principal = w.base <> "/api/v1/principals/prn_someone"
    assert {:ok, %{"projects" => [_]}} = Client.get_signed(principal, signer(w.browser))

    scope = %{"chapter_id" => w.chapter, "tenant_id" => tenant(), "project_id" => "project-1"}

    assert {:ok, %{"event_id" => _}} =
             Client.sign_held(
               principal <> "/offboarding",
               signer(w.browser),
               &(&1["type"] == "TaskPrincipalOffboardedV1"),
               scope
             )

    # Revoking the seed's key leaves the browser's; revoking the last is refused.
    revoke = fn target, by ->
      Client.sign_held(
        url <> "/#{target.signer.key_id}/revocation",
        signer(by),
        &(&1["type"] == "RoleKeyRevoked" and &1["payload"]["key_id"] == target.signer.key_id),
        %{"reason" => "Rotated"}
      )
    end

    assert {:ok, _} = revoke.(w.gov, w.browser)
    refute Map.has_key?(Log.gate().role_keys[{w.chapter, "governance"}], w.gov.signer.key_id)

    assert {:error, {409, body}} = revoke.(w.browser, w.browser)
    assert body =~ "cannot_orphan_governance"
  end

  test "administrators are listed and revoked only with a governance key of that chapter", w do
    url = w.base <> "/api/v1/chapters/#{w.chapter}/administrators"
    assert {:error, {401, _}} = Client.get(url)
    assert {:error, {401, _}} = Client.get_signed(url, signer(w.browser))

    assert {:error, {401, _}} =
             Client.sign_held(url <> "/k-x/revocation", signer(w.browser), fn _ -> true end, %{
               "reason" => "Mine now"
             })

    assert {:ok, [%{"key_id" => key, "principal_id" => nil}]} =
             Client.get_signed(url, governance(w))

    assert key == w.gov.signer.key_id
  end

  test "an administrator's browser follows the chapter's feed; nobody else does", w do
    path = "/api/v1/chapters/#{w.chapter}/feed"
    assert call(:get, path, [{"cookie", w.session}]).status == 401

    append!(
      event(w, w.gov, "RoleKeyDeclared", %{
        "role" => "governance",
        "key_id" => w.browser.signer.key_id,
        "pubkey" => {:bytes, w.browser.signer.pubkey},
        "member_id" => w.admin
      })
    )

    resp = open(w, {path, [{"cookie", w.session}]})
    assert {_seq, %{"changes" => changes}} = next(resp)

    assert for(%{"kind" => "projects", "id" => id} <- changes, do: id) ==
             ["#{tenant()}/project-1", "#{tenant()}/project-2"]

    # A task in another project reaches it at once.
    create!(w, w.op_grant_2, "task-9", "project-2")

    assert {_seq,
            %{"changes" => [%{"kind" => "projects", "value" => %{"tasks" => %{"inbox" => 1}}}]}} =
             next(resp)

    # Agents sign their reads of a project; a chapter's feed is for people.
    signed = [{"authorization", ~s(CoopFeed grant="g", key="k", ts="1", nonce="n", sig="s")}]
    assert call(:get, path, signed).status == 401
  end

  test "an administrator lists the chapter's projects, signed by a governance key of it", w do
    url = w.base <> "/api/v1/chapters/#{w.chapter}/projects"
    assert {:error, {401, _}} = Client.get(url)
    assert {:error, {401, _}} = Client.get_signed(url, signer(w.browser))

    assert {:ok,
            [
              %{"project_id" => "project-1", "tasks" => %{}, "people" => ["alice", "bot"]},
              %{"project_id" => "project-2", "tasks" => %{}, "people" => ["alice"]}
            ]} = Client.get_signed(url, governance(w))
  end
end

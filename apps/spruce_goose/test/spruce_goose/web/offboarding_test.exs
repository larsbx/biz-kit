defmodule SpruceGoose.Web.OffboardingTest do
  @moduledoc """
  Offboarding over HTTP (docs/architecture/2026-10-19-offboarding.md): an
  administrator lists what a principal holds with a read signed by the
  governance key, then ends it in every project with `mix coop.offboard`,
  against a running server. A person's open feed ends with it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Feed
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Offboarding.Offboarder

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    bind([{"https://idp.test", "sub-person", person}])
    laptop = member("operator")

    Map.merge(w, %{
      person: person,
      laptop: device!(w, laptop, person, "Laptop"),
      reviewer: grant!(w, "TaskReviewerGrantedV1", member("operator"), person, "project-2"),
      session: session!("second", "sub-person"),
      base: serve!()
    })
  end

  defp holds?(w, project),
    do: match?({:ok, _}, Feed.authorize_principal(w.person, {w.chapter, tenant(), project}))

  defp offboard!(w) do
    capture_io(fn ->
      Mix.Task.rerun("coop.offboard", [w.person, "--server", w.base, "--yes"])
    end)
  end

  test "mix coop.offboard ends everything, in every project; the person's feed ends", w do
    governance_keys!(w)
    resp = open(w, {feed_path(w), [{"cookie", w.session}]})
    _snapshot = next(resp)

    output = offboard!(w)

    assert output =~ "Principal #{w.person} holds"
    assert output =~ "#{w.chapter} / #{tenant()} / project-1"
    assert output =~ "operator  Laptop  key #{w.laptop.payload["key_id"]}"
    assert output =~ "reviewer  -"
    assert output =~ "offboarded: #{w.chapter} / #{tenant()} / project-2"
    assert next(resp) == :done

    refute holds?(w, "project-1")
    assert {:ok, %{"projects" => []}} = Offboarder.fetch(w.base, w.person, governance(w))
    assert offboard!(w) =~ "nothing to offboard"

    # Alice, in the same chapter, keeps her grants.
    assert {:ok, _} = Feed.authorize_principal("alice", {w.chapter, tenant(), "project-1"})
  end

  test "a principal ID with reserved URL characters is one path segment", w do
    governance_keys!(w)
    odd = "agent/team?x#y%2F"
    grant!(w, "TaskSuggesterGrantedV1", member("suggester"), odd, "project-1")
    grant!(w, "TaskSuggesterGrantedV1", member("suggester"), "agent", "project-1")

    assert {:ok, %{"principal_id" => ^odd, "projects" => [_]}} =
             Offboarder.fetch(w.base, odd, governance(w))

    output =
      capture_io(fn -> Mix.Task.rerun("coop.offboard", [odd, "--server", w.base, "--yes"]) end)

    assert output =~ "offboarded: #{w.chapter} / #{tenant()} / project-1"

    assert Feed.authorize_principal(odd, {w.chapter, tenant(), "project-1"}) ==
             {:error, :no_grant}

    assert {:ok, _} = Feed.authorize_principal("agent", {w.chapter, tenant(), "project-1"})
  end

  test "what a principal holds is shown only to a governance key", w do
    path = "/api/v1/principals/#{w.person}"
    assert call(:get, path, []).status == 401

    # Nor, by preparing an offboarding, whether it holds anything.
    body = %{
      "governance_key_id" => w.gov.signer.key_id,
      "chapter_id" => w.chapter,
      "tenant_id" => tenant(),
      "project_id" => "project-1"
    }

    assert call(
             :post,
             path <> "/offboarding",
             [{"content-type", "application/json"}],
             Jason.encode!(body)
           ).status == 401

    impostor = member("governance")

    signer = %{
      key_id: impostor.signer.key_id,
      pubkey: impostor.signer.pubkey,
      seed: impostor.seed
    }

    assert {:error, {401, _}} = Client.get_signed(w.base <> path, signer)

    assert {:ok, %{"projects" => [p1, p2]}} = Client.get_signed(w.base <> path, governance(w))
    assert {p1["project_id"], p2["project_id"]} == {"project-1", "project-2"}

    # Another chapter's governance sees nothing of this one.
    other = world()
    assert {:ok, %{"projects" => []}} = Client.get_signed(w.base <> path, governance(other))
  end

  test "the administrator signs only the offboarding it was shown", w do
    {:ok, details} = Offboarder.fetch(w.base, w.person, governance(w))
    [p1 | _] = details["projects"]
    scope = Map.take(p1, ~w(chapter_id tenant_id project_id))

    core = %{
      "type" => "TaskPrincipalOffboardedV1",
      "chapter_id" => w.chapter,
      "payload" => %{
        "tenant_id" => tenant(),
        "project_id" => "project-1",
        "principal_id" => w.person
      }
    }

    assert Offboarder.offboards?(core, w.person, scope)

    refute Offboarder.offboards?(
             put_in(core, ["payload", "principal_id"], "alice"),
             w.person,
             scope
           )

    refute Offboarder.offboards?(
             put_in(core, ["payload", "project_id"], "project-2"),
             w.person,
             scope
           )

    refute Offboarder.offboards?(Map.put(core, "type", "TaskOperatorRevokedV1"), w.person, scope)

    impostor = member("governance")

    signer = %{
      key_id: impostor.signer.key_id,
      pubkey: impostor.signer.pubkey,
      seed: impostor.seed
    }

    assert {:error, {401, _}} = Offboarder.offboard(w.base, details, signer)
    assert {:error, {401, _}} = Offboarder.offboard(w.base, details, governance(world()))
    assert holds?(w, "project-1")
  end
end

defmodule CoopSubstrate.LiveViewTest do
  @moduledoc """
  The feed drives what the view shows of access
  (docs/architecture/2026-10-19-live-view.md): a project's feed carries its
  reader's own devices, and a chapter's feed, for its administrators only,
  carries the chapter's projects and administrators, each as they change.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Feed, Log}

  @project {"chapter-genesis", "tenant-1", "project-1"}
  @chapter {"chapter-genesis"}

  setup do
    gov = new_member("governance")
    laptop = new_member("operator")

    {:ok, [_, grant]} =
      Log.append([declare_governance(gov), operator_grant(gov, laptop, "alice")])

    %{gov: gov, laptop: laptop, grant: grant}
  end

  defp notified do
    assert_receive {:coop_ledger, envelopes}
    envelopes
  end

  defp changes(%{changes: changes}, kind),
    do: for(%{kind: ^kind, id: id, value: value} <- changes, do: {id, value})

  defp administrator(gov, key, principal) do
    signed_event(gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => key.signer.key_id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "member_id" => principal
    })
  end

  test "a project's feed carries its reader's own devices, as they are granted and revoked", w do
    {:ok, reader} = Feed.authorize_principal("alice", @project)
    {:ok, session, frame} = Feed.open(@project, 0, reader)

    assert [{id, %{kind: "operator", grant_id: id, key_id: key}}] = changes(frame, :devices)
    assert {id, key} == {w.grant.event_id, w.laptop.signer.key_id}

    # Bob's new device is not Alice's to see; her reviewer device is.
    tablet = new_member("reviewer")

    {:ok, [_bob, reviewer]} =
      Log.append([
        operator_grant(w.gov, new_member("operator"), "bob"),
        reviewer_grant(w.gov, tablet, "alice")
      ])

    {frame, session} = Feed.advance(session, notified())
    assert [{id, %{kind: "reviewer", key_id: key}}] = changes(frame, :devices)
    assert {id, key} == {reviewer.event_id, tablet.signer.key_id}

    {:ok, _} =
      Log.append(
        signed_event(w.gov, "TaskReviewerRevokedV1", %{
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "authorization_event_id" => reviewer.event_id
        })
      )

    {frame, _session} = Feed.advance(session, notified())
    assert changes(frame, :devices) == [{reviewer.event_id, nil}]
  end

  test "an administrator's key is among its devices in every project of the chapter", w do
    browser = new_member("governance")
    {:ok, _} = Log.append(administrator(w.gov, browser, "alice"))
    other = {"chapter-genesis", "tenant-2", "elsewhere"}

    {:ok, reader} = Feed.authorize_principal("alice", other)
    {:ok, _session, frame} = Feed.open(other, 0, reader)

    assert changes(frame, :devices) == [
             {browser.signer.key_id,
              %{kind: "administrator", grant_id: nil, key_id: browser.signer.key_id, label: nil}}
           ]
  end

  test "a chapter's feed is for its administrators: its projects and administrators, live", w do
    assert Feed.authorize_principal("alice", @chapter) == {:error, :no_grant}

    browser = new_member("governance")
    {:ok, _} = Log.append(administrator(w.gov, browser, "alice"))
    {:ok, reader} = Feed.authorize_principal("alice", @chapter)
    {:ok, session, frame} = Feed.open(@chapter, 0, reader)

    assert [{"tenant-1/project-1", %{tasks: %{}, people: ["alice"]}}] = changes(frame, :projects)

    assert Enum.sort(changes(frame, :administrators)) ==
             Enum.sort([
               {w.gov.signer.key_id, %{principal_id: nil}},
               {browser.signer.key_id, %{principal_id: "alice"}}
             ])

    # Work in a project changes its counts.
    {:ok, _} = Log.append(create(w.laptop, w.grant, "task-1", unscheduled()))
    {frame, session} = Feed.advance(session, notified())
    assert [{"tenant-1/project-1", %{tasks: %{"inbox" => 1}}}] = changes(frame, :projects)

    # So does any change in access, even one that leaves the same people.
    {:ok, [second]} = Log.append(reviewer_grant(w.gov, new_member("reviewer"), "alice"))
    {frame, session} = Feed.advance(session, notified())
    assert [{_, %{grants: 2, people: ["alice"]}}] = changes(frame, :projects)

    {:ok, _} =
      Log.append(
        signed_event(w.gov, "TaskReviewerRevokedV1", %{
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "authorization_event_id" => second.event_id
        })
      )

    {frame, session} = Feed.advance(session, notified())
    assert [{_, %{grants: 1}}] = changes(frame, :projects)

    # Revoking the reader's key ends the stream, as revoking a grant does.
    {:ok, _} =
      Log.append(
        signed_event(w.gov, "RoleKeyRevoked", %{
          "role" => "governance",
          "key_id" => browser.signer.key_id
        })
      )

    assert {:revoked, _} = Feed.advance(session, notified())
    assert Feed.authorize_principal("alice", @chapter) == {:error, :no_grant}
  end

  test "an administrator's feed ends when its key comes to name someone else", w do
    browser = new_member("governance")
    {:ok, _} = Log.append(administrator(w.gov, browser, "alice"))
    {:ok, reader} = Feed.authorize_principal("alice", @chapter)
    {:ok, session, _frame} = Feed.open(@chapter, 0, reader)

    # Revoked and declared again for Bob, in one batch: still declared, not Alice's.
    revoke =
      signed_event(w.gov, "RoleKeyRevoked", %{
        "role" => "governance",
        "key_id" => browser.signer.key_id
      })

    {:ok, _} = Log.append([revoke, administrator(w.gov, browser, "bob")])
    assert {:revoked, _} = Feed.advance(session, notified())
  end

  test "a chapter's feed is not for a project's readers, nor its view for another chapter" do
    assert {:ok, project_reader} = Feed.authorize_principal("alice", @project)
    assert Feed.open(@chapter, 0, project_reader) == {:error, :scope_mismatch}

    {:ok, _session, frame} = Feed.open({"chapter-other"}, 0)
    assert frame.changes == []
  end
end

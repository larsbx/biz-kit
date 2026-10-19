defmodule BizKit.Identity.ClusterSessionsTest do
  @moduledoc """
  Sessions are one for the cluster (docs/architecture/2026-10-19-cluster.md):
  a session issued on one node works on another, and revoking it on either
  revokes it everywhere.
  """
  use ExUnit.Case, async: false

  alias BizKit.Cluster.Peers
  alias BizKit.Identity.Sessions

  setup_all do
    Peers.distribute!()
  end

  test "a session issued here works there, and revoking it there ends it here" do
    {_, peer} = Peers.start!()
    Peers.mesh!([peer])
    now = System.system_time(:millisecond)
    identity = %{issuer: "https://idp.test", subject: "sub-alice"}

    id = Sessions.create("prn_alice", identity)
    assert {:ok, %{principal: "prn_alice"}} = :erpc.call(peer, Sessions, :fetch, [id, now])

    :ok = :erpc.call(peer, Sessions, :revoke_principal, ["prn_alice"])
    assert Sessions.fetch(id, now) == {:error, :unknown_session}
  end
end

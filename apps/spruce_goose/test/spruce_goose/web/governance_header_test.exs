defmodule SpruceGoose.Web.GovernanceHeaderTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Governance.Authorization
  alias SpruceGoose.Web.Requests

  test "malformed governance headers are refused before reaching the ledger" do
    request = %{
      method: "GET",
      path: "/api/v1/principals/alice/holdings",
      timestamp_ms: 1_700_000_000_000,
      nonce: String.duplicate("n", 16),
      key_id: "k-governance"
    }

    header = Authorization.encode(request, :binary.copy(<<7>>, 64))

    for invalid <- [
          header <> ~s(, key="duplicate"),
          String.replace(
            header,
            ~s(ts="#{request.timestamp_ms}"),
            ~s(ts="999999999999999999999999")
          )
        ] do
      conn =
        Plug.Test.conn(:get, request.path)
        |> Plug.Conn.put_req_header("authorization", invalid)

      assert {:unauthorized, :malformed_authorization} = Requests.governance_read(conn)
    end
  end
end

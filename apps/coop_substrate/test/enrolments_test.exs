defmodule CoopSubstrate.EnrolmentsTest do
  @moduledoc """
  Self-service device enrolment (docs/architecture/2026-10-19-device-enrolment.md):
  a signed-in person's device proves it holds its key and asks for access; an
  administrator approves by code; the operator grant is signed with the
  governance key and admitted by the ledger like any other.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Canonical, Crypto, Enrolments, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}
  @identity %{issuer: "https://idp.test", subject: "sub-alice"}

  setup do
    gov = new_member("governance")
    {:ok, _} = Log.append(declare_governance(gov))
    %{gov: gov, device: new_member("operator")}
  end

  defp begin(w, opts \\ []) do
    Enrolments.begin(
      Keyword.get(opts, :principal, "alice"),
      @identity,
      Keyword.get(opts, :scope, @scope),
      Keyword.get(opts, :key_id, w.device.signer.key_id),
      Keyword.get(opts, :pubkey, w.device.signer.pubkey),
      Keyword.get(opts, :label, "Alice's laptop")
    )
  end

  # The device signs the statement it was given.
  defp sign(%{statement: bytes}, member), do: Crypto.sign(bytes, member.seed)

  defp request!(w) do
    {:ok, challenge} = begin(w)
    {:ok, request} = Enrolments.prove("alice", challenge.id, sign(challenge, w.device))
    request
  end

  defp approve!(w, code) do
    {:ok, pending} = Enrolments.prepare_approval(code, w.gov.signer.key_id)
    Enrolments.approve(code, pending.id, Crypto.sign(pending.signing_bytes, w.gov.seed))
  end

  defp status(w, opts \\ []),
    do:
      Enrolments.status(
        Keyword.get(opts, :principal, "alice"),
        @scope,
        Keyword.get(opts, :key_id, w.device.signer.key_id)
      )

  describe "requesting" do
    test "the device signs an enrolment statement, not a command", w do
      {:ok, challenge} = begin(w)
      {:ok, statement} = Canonical.decode(challenge.statement)

      assert %{
               "schema" => "CoopDeviceEnrolmentV1",
               "principal_id" => "alice",
               "chapter_id" => "chapter-genesis",
               "tenant_id" => "tenant-1",
               "project_id" => "project-1",
               "key_id" => key_id,
               "pubkey" => {:bytes, pubkey},
               "label" => "Alice's laptop"
             } = statement

      assert {key_id, pubkey} == {w.device.signer.key_id, w.device.signer.pubkey}
      refute Map.has_key?(statement, "type")
    end

    test "proving possession yields a code the request is found by", w do
      assert status(w) == :none

      request = request!(w)
      assert request.code =~ ~r/^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}$/
      assert status(w) == {:pending, request.code, request.expires_at}

      assert {:ok, details} = Enrolments.fetch(request.code)
      assert details.principal_id == "alice"
      assert details.identity == @identity

      assert {details.scope, details.key_id, details.label} ==
               {@scope, w.device.signer.key_id, "Alice's laptop"}
    end

    test "asking again for the same key returns the same request", w do
      first = request!(w)
      assert request!(w).code == first.code
    end

    test "refused for a key ID that does not name the key, or a bad label", w do
      assert begin(w, key_id: "k-00000000") == {:error, :key_id_mismatch}
      assert begin(w, pubkey: <<1, 2, 3>>) == {:error, :invalid_pubkey}
      assert begin(w, label: "") == {:error, :invalid_label}
      assert begin(w, label: String.duplicate("x", 81)) == {:error, :invalid_label}
    end

    test "refused without proof by that key, or by another principal", w do
      {:ok, challenge} = begin(w)

      assert Enrolments.prove("alice", challenge.id, sign(challenge, w.gov)) ==
               {:error, :bad_proof}

      {:ok, challenge} = begin(w)

      assert Enrolments.prove("mallory", challenge.id, sign(challenge, w.device)) ==
               {:error, :unknown_challenge}

      assert status(w) == :none
    end
  end

  describe "approving" do
    test "issues the operator grant for exactly the requested key, principal and project", w do
      request = request!(w)

      {:ok, pending} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
      assert pending.type == "TaskOperatorGrantedV1"

      assert %{
               "principal_id" => "alice",
               "tenant_id" => "tenant-1",
               "project_id" => "project-1",
               "key_id" => key_id,
               "pubkey" => {:bytes, pubkey}
             } = pending.payload

      assert {key_id, pubkey} == {w.device.signer.key_id, w.device.signer.pubkey}

      assert {:ok, grant} =
               Enrolments.approve(
                 request.code,
                 pending.id,
                 Crypto.sign(pending.signing_bytes, w.gov.seed)
               )

      assert grant.type == "TaskOperatorGrantedV1"
      assert status(w) == :enrolled
      assert Enrolments.fetch(request.code) == {:error, :unknown_code}

      assert {:ok, %{principal_id: "alice"}} =
               CoopSubstrate.Feed.authorize_principal("alice", @scope)
    end

    test "only a declared governance key can sign it", w do
      request = request!(w)
      other = new_member("governance")

      assert Enrolments.prepare_approval(request.code, other.signer.key_id) ==
               {:error, :unknown_governance_key}

      {:ok, pending} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)

      assert {:error, {:invalid_signature, _}} =
               Enrolments.approve(
                 request.code,
                 pending.id,
                 Crypto.sign(pending.signing_bytes, other.seed)
               )

      assert status(w) == {:pending, request.code, request.expires_at}
    end

    test "an approval is held for its own code only", w do
      request = request!(w)
      bob = new_member("operator")

      {:ok, bob_challenge} =
        begin(w, principal: "bob", key_id: bob.signer.key_id, pubkey: bob.signer.pubkey)

      {:ok, bob_request} = Enrolments.prove("bob", bob_challenge.id, sign(bob_challenge, bob))

      {:ok, pending} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
      signature = Crypto.sign(pending.signing_bytes, w.gov.seed)

      assert Enrolments.approve(bob_request.code, pending.id, signature) ==
               {:error, :unknown_command}

      assert {:ok, _} = Enrolments.approve(request.code, pending.id, signature)
    end

    test "an enrolled key is not requested again; codes are single-use", w do
      request = request!(w)
      {:ok, _} = approve!(w, request.code)

      assert begin(w) == {:error, :already_enrolled}

      assert Enrolments.prepare_approval(request.code, w.gov.signer.key_id) ==
               {:error, :unknown_code}
    end

    test "an expired request is no longer pending and cannot be approved", w do
      request = request!(w)
      later = request.expires_at + 1
      assert Enrolments.status("alice", @scope, w.device.signer.key_id, later) == :none

      assert Enrolments.fetch(request.code, request.expires_at + 1) == {:error, :unknown_code}

      assert Enrolments.prepare_approval(
               request.code,
               w.gov.signer.key_id,
               request.expires_at + 1
             ) ==
               {:error, :unknown_code}
    end

    test "a revoked enrolment can be requested afresh", w do
      request = request!(w)
      {:ok, grant} = approve!(w, request.code)
      {:ok, _} = Log.append(operator_revoke(w.gov, grant))

      assert status(w) == :none
      assert %{code: _} = request!(w)
    end
  end
end

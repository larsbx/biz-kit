defmodule SpruceGoose.LedgerFixtures do
  @moduledoc """
  Ledger fixtures for SpruceGoose's tests of the feed and sign-in: signed
  envelopes appended through `CoopSubstrate.Log`, each world in its own
  chapter so the shared ledger needs no reset, and a client for live SSE
  streams.
  """

  import ExUnit.Assertions

  alias CoopSubstrate.{Crypto, Log, ULID}
  alias CoopSubstrate.Protocol.Envelope

  @tenant "tenant-1"

  def tenant, do: @tenant

  def now, do: System.system_time(:millisecond)

  def member(role) do
    {pubkey, seed} = Crypto.generate_keypair()
    key_id = "k-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
    %{seed: seed, signer: %{role: role, pubkey: pubkey, key_id: key_id}}
  end

  def event(w, member, type, payload) do
    {:ok, env} =
      Envelope.new(%{
        event_id: ULID.generate(),
        chapter_id: w.chapter,
        type: type,
        payload: payload,
        signers: [member.signer],
        auth_ref: nil,
        timestamp_ms: now()
      })

    {:ok, signed} = Envelope.sign(env, member.signer.key_id, member.seed)
    signed
  end

  def append!(envs) do
    {:ok, appended} = Log.append(envs)
    appended
  end

  def grant!(w, type, member, principal, project, extra \\ %{}) do
    [grant] =
      append!(
        event(
          w,
          w.gov,
          type,
          Map.merge(
            %{
              "tenant_id" => @tenant,
              "project_id" => project,
              "principal_id" => principal,
              "key_id" => member.signer.key_id,
              "pubkey" => {:bytes, member.signer.pubkey}
            },
            extra
          )
        )
      )

    grant
  end

  @doc "A person's device, enrolled in project-1 under `label`."
  def device!(w, member, principal, label),
    do:
      grant!(w, "TaskOperatorGrantedV1", member, principal, "project-1", %{
        "device_label" => label
      })

  @doc "The world's governance seed in a keys directory, as `mix coop.*` tasks expect, for this test."
  def governance_keys!(w) do
    dir = Path.join(System.tmp_dir!(), "coop-keys-" <> w.chapter)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "governance.seed"), Base.encode16(w.gov.seed, case: :lower))
    System.put_env("HARNESS_KEYS_DIR", dir)

    ExUnit.Callbacks.on_exit(fn ->
      System.delete_env("HARNESS_KEYS_DIR")
      File.rm_rf!(dir)
    end)
  end

  @doc "The world's governance key as a `CoopSubstrate.Governance.Client` signer."
  def governance(w),
    do: %{key_id: w.gov.signer.key_id, pubkey: w.gov.signer.pubkey, seed: w.gov.seed}

  def create!(w, grant, task_id, project \\ "project-1", signer \\ nil) do
    [env] =
      append!(
        event(w, signer || w.op, "TaskCreatedV1", %{
          "tenant_id" => @tenant,
          "project_id" => project,
          "principal_id" => grant.payload["principal_id"],
          "authorization_event_id" => grant.event_id,
          "lifecycle_version" => 1,
          "task_id" => task_id,
          "title" => "Task #{task_id}",
          "timing" => %{"schedule" => nil, "due_ms" => nil}
        })
      )

    env
  end

  @doc "An agent's timing suggestion for a task, under its suggester grant."
  def suggest!(w, grant, task_id, timing, base),
    do:
      suggest_change!(w, grant, task_id, %{"kind" => "timing", "timing" => timing}, %{
        "base_timing_version" => base
      })

  @doc "An agent's suggestion to create a task."
  def suggest_create!(w, grant, task_id, title, timing),
    do:
      suggest_change!(w, grant, task_id, %{
        "kind" => "create",
        "title" => title,
        "timing" => timing
      })

  defp suggest_change!(w, grant, task_id, change, extra \\ %{}) do
    [env] =
      append!(
        event(
          w,
          w.agent,
          "TaskChangeSuggestedV1",
          Map.merge(
            %{
              "tenant_id" => @tenant,
              "project_id" => grant.payload["project_id"],
              "principal_id" => grant.payload["principal_id"],
              "authorization_event_id" => grant.event_id,
              "task_id" => task_id,
              "change" => change,
              "rationale" => "Fits the free slot"
            },
            extra
          )
        )
      )

    env
  end

  def revoke!(w, type, grant) do
    append!(
      event(w, w.gov, type, %{
        "tenant_id" => @tenant,
        "project_id" => grant.payload["project_id"],
        "authorization_event_id" => grant.event_id
      })
    )
  end

  @doc "A fresh chapter with its governance key, an operator and an agent."
  def world do
    w = %{chapter: "chapter-sg-" <> ULID.generate(), gov: member("governance")}
    w = Map.merge(w, %{op: member("operator"), agent: member("suggester")})

    append!(
      event(w, w.gov, "RoleKeyDeclared", %{
        "role" => "governance",
        "key_id" => w.gov.signer.key_id,
        "pubkey" => {:bytes, w.gov.signer.pubkey}
      })
    )

    Map.merge(w, %{
      op_grant: grant!(w, "TaskOperatorGrantedV1", w.op, "alice", "project-1"),
      op_grant_2: grant!(w, "TaskOperatorGrantedV1", w.op, "alice", "project-2"),
      agent_grant: grant!(w, "TaskSuggesterGrantedV1", w.agent, "bot", "project-1")
    })
  end

  def feed_path(w, project \\ "project-1"),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{@tenant}/projects/#{project}/feed"

  def call(method, path, headers, body \\ nil) do
    method
    |> Plug.Test.conn(path, body)
    |> then(
      &Enum.reduce(headers, &1, fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    )
    |> SpruceGoose.Web.Router.call(SpruceGoose.Web.Router.init([]))
  end

  # -- live streams --------------------------------------------------------------------

  @doc "Serve the real endpoint on an ephemeral port for this test; its base URL."
  def serve! do
    config = Application.fetch_env!(:spruce_goose, SpruceGoose.Web.Endpoint)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:spruce_goose, SpruceGoose.Web.Endpoint, config)
    end)

    Application.put_env(
      :spruce_goose,
      SpruceGoose.Web.Endpoint,
      Keyword.merge(config, server: true, http: [ip: {127, 0, 0, 1}, port: 0])
    )

    ExUnit.Callbacks.start_supervised!(SpruceGoose.Web.Endpoint)
    {:ok, {_ip, port}} = SpruceGoose.Web.Endpoint.server_info(:http)
    "http://127.0.0.1:#{port}"
  end

  @doc "Open a stream; its frames arrive through `next/1`."
  def open(w, {path, headers}) do
    Req.get!(w.base <> path,
      headers: headers,
      into: :self,
      retry: false,
      receive_timeout: 5_000
    )
  end

  # The next `changes` event, skipping heartbeats; :done when the server ends
  # the stream.
  def next(resp) do
    buffer = Process.get(resp.body.ref, "")

    case String.split(buffer, "\n\n", parts: 2) do
      [": heartbeat", rest] ->
        Process.put(resp.body.ref, rest)
        next(resp)

      [event, rest] ->
        Process.put(resp.body.ref, rest)
        ["id: " <> id, "event: changes", "data: " <> data] = String.split(event, "\n")
        {String.to_integer(id), Jason.decode!(data)}

      [_partial] ->
        receive do
          message ->
            case Req.parse_message(resp, message) do
              {:ok, parts} ->
                Enum.reduce_while(parts, nil, fn
                  {:data, data}, _ ->
                    Process.put(resp.body.ref, Process.get(resp.body.ref, "") <> data)
                    {:cont, nil}

                  :done, _ ->
                    {:halt, :done}

                  _other, _ ->
                    {:cont, nil}
                end) || next(resp)

              :unknown ->
                next(resp)
            end
        after
          3_000 -> flunk("no event within 3s")
        end
    end
  end

  @doc "The kinds a frame changes, each once."
  def kinds({_seq, %{"changes" => changes}}), do: changes |> Enum.map(& &1["kind"]) |> Enum.uniq()

  def tasks({_seq, %{"changes" => changes}}),
    do: for(%{"kind" => "tasks", "id" => id} <- changes, do: id) |> Enum.sort()
end

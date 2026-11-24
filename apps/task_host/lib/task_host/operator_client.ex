defmodule TaskHost.OperatorClient do
  @moduledoc """
  Client of the running task host. Reads prove possession of one scoped
  grant. Commands use the existing native session and sign only the
  canonical envelope that matches an independently reviewed intent.
  """

  alias CoopSubstrate.{Canonical, Constants, Crypto, Enrolments, ULID}
  alias CoopSubstrate.Feed.Access
  alias CoopSubstrate.Governance.Client, as: Governance
  alias TaskCore.Admission

  @operator_types %{
    "propose" => "TaskProposedV1",
    "queue" => "TaskQueuedV1",
    "acknowledge_sop" => "TaskSOPAcknowledgedV1",
    "ready" => "TaskReadyV1",
    "start" => "TaskStartedV1",
    "cancel" => "TaskCancelledV1",
    "reopen" => "TaskReopenedV1",
    "complete" => "TaskCompletedV1",
    "instantiate" => "TaskWorkflowInstantiatedV1",
    "record_custody" => "ArtifactCustodyRecordedV1",
    "submit_evidence" => "TaskEvidenceSubmittedV2",
    "add_todo" => "TaskTodoAddedV1",
    "revise_todo" => "TaskTodoRevisedV1",
    "complete_todo" => "TaskTodoCompletedV1",
    "drop_todo" => "TaskTodoDroppedV1"
  }
  @bound_fields ~w(tenant_id project_id principal_id authorization_event_id)

  def scope(value) do
    with [chapter, tenant, project] = ids <- String.split(value, "/"),
         true <- Enum.all?(ids, &Admission.segment?/1) do
      {:ok, {chapter, tenant, project}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def project_path({chapter, tenant, project}),
    do: "/api/v1/chapters/#{chapter}/tenants/#{tenant}/projects/#{project}"

  def signer(opts) do
    with true <- ULID.valid?(opts[:grant]) or {:error, :invalid_grant_id},
         key when is_binary(key) <- opts[:key_id],
         true <- Regex.match?(~r/\A[A-Za-z0-9._:-]{1,128}\z/, key) or {:error, :invalid_key_id},
         {:ok, seed} <- seed(opts[:seed_file]) do
      {:ok, %{grant: opts[:grant], key: key, seed: seed}}
    else
      {:error, _} = error -> error
      nil -> {:error, :missing_key_id}
      _ -> {:error, :invalid_private_seed_file}
    end
  end

  def seed(path) do
    with {:ok, hex} <- private_file(path, 66, :invalid_private_seed_file),
         {:ok, <<_::256>> = seed} <- Base.decode16(hex, case: :mixed) do
      {:ok, seed}
    else
      _ -> {:error, :invalid_private_seed_file}
    end
  end

  def keygen(path) do
    {pubkey, seed} = Crypto.generate_keypair()

    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(io, Base.encode16(seed, case: :lower)) do
          {:ok, %{"key_id" => Enrolments.key_id(pubkey)}}
        end
      after
        File.close(io)
      end
    end
  end

  def devices(base, scope, session) do
    case request(:get, base <> project_path(scope) <> "/devices", [session], []) do
      {:ok, rows} when is_list(rows) -> {:ok, %{"devices" => rows}}
      {:ok, _} -> {:error, :invalid_devices_response}
      error -> error
    end
  end

  def projects(base, session, params) do
    query = if map_size(params) == 0, do: "", else: "?" <> URI.encode_query(params)
    request(:get, base <> "/api/v1/projects" <> query, [session], [])
  end

  def enrol(base, {chapter, tenant, project} = scope, session, seed, label, role)
      when role in ~w(operator reviewer) do
    pubkey = Crypto.pubkey_from_seed(seed)
    key = Enrolments.key_id(pubkey)

    body = %{
      "public_key" => Base.url_encode64(pubkey, padding: false),
      "key_id" => key,
      "label" => label,
      "role" => role
    }

    with {:ok, %{"principal" => principal}} when is_binary(principal) <-
           request(:get, base <> "/auth/me", [session], []),
         {:ok, %{"id" => id, "statement" => encoded}}
         when is_binary(id) and is_binary(encoded) <-
           request(:post, base <> project_path(scope) <> "/devices", [session], json: body),
         true <-
           Regex.match?(~r/\A[A-Za-z0-9_-]{32}\z/, id) or {:error, :invalid_enrolment_challenge},
         {:ok, statement} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"nonce" => nonce} = shown} when is_binary(nonce) <- Canonical.decode(statement),
         expected = %{
           "schema" => "CoopDeviceEnrolmentV1",
           "principal_id" => principal,
           "chapter_id" => chapter,
           "tenant_id" => tenant,
           "project_id" => project,
           "key_id" => key,
           "pubkey" => {:bytes, pubkey},
           "label" => label,
           "role" => role
         },
         true <- Map.delete(shown, "nonce") === expected or {:error, :not_what_was_reviewed} do
      signature = statement |> Crypto.sign(seed) |> Base.url_encode64(padding: false)

      request(:post, base <> "/api/v1/devices/challenges/" <> id, [session],
        json: %{"signature" => signature}
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_enrolment_challenge}
    end
  end

  def enrol(_, _, _, _, _, _), do: {:error, :invalid_role}

  def session(opts) do
    with {:ok, token} <- private_file(opts[:session_file], 256, :invalid_private_session_file),
         true <-
           Regex.match?(~r/\Anat_[A-Za-z0-9_-]+\z/, token) or {:error, :invalid_session_token},
         do: {:ok, {"authorization", "Bearer " <> token}}
  end

  def server(opts) do
    url = opts[:server] || Governance.default_server()

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" and path in [nil, "/"] ->
        if scheme == "https" or (scheme == "http" and host in ~w(localhost 127.0.0.1 ::1)),
          do: {:ok, String.trim_trailing(url, "/")},
          else: {:error, :https_required}

      _ ->
        {:error, :invalid_server}
    end
  end

  def get(base, {chapter, tenant, project} = scope, suffix, signer, params \\ %{}) do
    path = project_path(scope) <> suffix
    query = if map_size(params) == 0, do: "", else: "?" <> URI.encode_query(params)

    read = %{
      method: "GET",
      path: path,
      scope: scope,
      cursor: 0,
      timestamp_ms: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      authorization_event_id: signer.grant,
      key_id: signer.key
    }

    signature =
      read
      |> Access.signing_bytes()
      |> Crypto.sign(signer.seed)
      |> Base.url_encode64(padding: false)

    header =
      ~s(CoopFeed grant="#{signer.grant}", key="#{signer.key}", ) <>
        ~s(ts="#{read.timestamp_ms}", nonce="#{read.nonce}", sig="#{signature}")

    case request(:get, base <> path <> query, [{"authorization", header}], []) do
      {:ok, %{"chapter_id" => ^chapter, "tenant_id" => ^tenant, "project_id" => ^project} = body} ->
        {:ok, body}

      {:ok, _} ->
        {:error, :wrong_response_scope}

      error ->
        error
    end
  end

  @doc "Review a held command against the local request and the complete expected payload."
  def prepare(base, scope, session, signer, %{"request" => request, "expect" => expected})
      when is_map(request) and is_map(expected) do
    with {:ok, role, type} <- command(request["action"]),
         true <-
           Enum.all?(@bound_fields, &(not Map.has_key?(expected, &1))) or {:error, :bad_intent},
         {:ok, %{"principal" => principal}} when is_binary(principal) <-
           request(:get, base <> "/auth/me", [session], []),
         request = Map.merge(request, %{"key_id" => signer.key, "grant_event_id" => signer.grant}),
         {:ok, held} <-
           request(:post, base <> project_path(scope) <> "/commands", [session], json: request) do
      check_held(held, scope, principal, signer, role, type, expected)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_session_response}
    end
  end

  def prepare(_, _, _, _, _), do: {:error, :bad_intent}

  defp command("review"), do: {:ok, "reviewer", "TaskDoDReviewedV1"}
  defp command("attest_artifact"), do: {:ok, "reviewer", "TaskArtifactSourceAttestedV1"}

  defp command(action) do
    case Map.fetch(@operator_types, action) do
      {:ok, type} -> {:ok, "operator", type}
      :error -> {:error, :unsupported_action}
    end
  end

  defp check_held(
         %{"id" => id, "signing_bytes" => encoded},
         {chapter, tenant, project},
         principal,
         signer,
         role,
         type,
         expected
       )
       when is_binary(id) and is_binary(encoded) do
    expected =
      Map.merge(expected, %{
        "tenant_id" => tenant,
        "project_id" => project,
        "principal_id" => principal,
        "authorization_event_id" => signer.grant
      })

    signers = [
      %{
        "role" => role,
        "key_id" => signer.key,
        "pubkey" => {:bytes, Crypto.pubkey_from_seed(signer.seed)}
      }
    ]

    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]{32}\z/, id),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{} = core} <- Canonical.decode(bytes),
         %{
           "type" => ^type,
           "chapter_id" => ^chapter,
           "auth_ref" => nil,
           "signers" => ^signers,
           "payload" => actual,
           "event_id" => event_id
         } <- core,
         true <- ULID.valid?(event_id),
         true <- core["canonical_profile"] == Constants.canonical_profile(),
         true <- core["schema_version"] == Constants.envelope_schema_version(),
         true <- json_value(actual) === expected do
      {:ok, %{held_id: id, event_id: event_id, type: type, signing_bytes: bytes}}
    else
      _ -> {:error, :not_what_was_reviewed}
    end
  end

  defp check_held(_, _, _, _, _, _, _), do: {:error, :not_what_was_reviewed}

  @doc "Submit the matching device signature. An uncertain response preserves the event ID."
  def submit(base, session, signer, held) do
    signature =
      held.signing_bytes |> Crypto.sign(signer.seed) |> Base.url_encode64(padding: false)

    id = held.event_id
    url = base <> "/api/v1/commands/" <> held.held_id

    case request(:post, url, [session], json: %{"signature" => signature}) do
      {:ok, %{"event_id" => ^id, "global_seq" => seq} = result} when is_integer(seq) ->
        {:ok, result}

      {:error, {:http, code, _}} = error when code in 400..499 ->
        error

      _ ->
        {:error, {:submission_unconfirmed, id}}
    end
  end

  def upload(base, scope, session, file, task_id) do
    with {:ok, bytes} <- artifact_bytes(file),
         true <- task_id == nil or Admission.segment?(task_id) or {:error, :invalid_task_id} do
      digest = digest_hex(bytes)
      size = byte_size(bytes)
      query = if task_id, do: "?" <> URI.encode_query(%{"evidence_for" => task_id}), else: ""

      headers = [
        session,
        {"content-type", "application/octet-stream"},
        {"x-content-sha256", digest}
      ]

      case request(:post, base <> project_path(scope) <> "/artifacts" <> query, headers,
             body: bytes
           ) do
        {:ok, %{"digest" => ^digest, "size" => ^size} = stored} -> {:ok, stored}
        {:ok, _} -> {:error, :upload_response_mismatch}
        error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :not_regular_file}
    end
  end

  @doc "Compare local bytes with the SOP pinned by the current task readiness event."
  def verify_sop(%{"readiness" => %{"sop_digest" => digest} = readiness}, file) do
    with {:ok, bytes} <- artifact_bytes(file),
         true <- digest_hex(bytes) == digest or {:error, :sop_digest_mismatch} do
      {:ok, Map.take(readiness, ~w(event_id sop_digest sop_version))}
    end
  end

  def verify_sop(_, _), do: {:error, :readiness_not_defined}

  defp artifact_bytes(file) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(file),
         true <- size <= CoopSubstrate.ArtifactCustody.limit() or {:error, :artifact_too_large},
         {:ok, bytes} <- File.read(file),
         true <- byte_size(bytes) == size or {:error, :artifact_changed} do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_regular_file}
    end
  end

  defp digest_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp request(method, url, headers, body) do
    options = [
      method: method,
      url: url,
      headers: headers,
      redirect: false,
      retry: false,
      receive_timeout: 15_000
    ]

    with {:ok, _} <- Application.ensure_all_started(:req) do
      request(options ++ body)
    end
  end

  defp request(options) do
    case Req.request(options) do
      {:ok, %{status: status, body: result}}
      when status in 200..299 and (is_map(result) or is_list(result)) ->
        {:ok, result}

      {:ok, %{status: status, body: %{"error" => code}}} when is_binary(code) ->
        {:error, {:http, status, code}}

      {:ok, %{status: status}} ->
        {:error, {:http, status, nil}}

      {:error, _} ->
        {:error, :task_host_unavailable}
    end
  end

  defp private_file(path, limit, error) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, mode: mode, size: size}}
         when Bitwise.band(mode, 0o077) == 0 and size >= 1 and size <= limit <- File.lstat(path),
         {:ok, bytes} when byte_size(bytes) == size <- File.read(path) do
      {:ok, String.trim(bytes)}
    else
      _ -> {:error, error}
    end
  end

  defp private_file(_, _, error), do: {:error, error}

  defp json_value({:bytes, bytes}), do: %{"$bytes" => Base.url_encode64(bytes, padding: false)}
  defp json_value(%{} = map), do: Map.new(map, fn {key, value} -> {key, json_value(value)} end)
  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(value), do: value
end

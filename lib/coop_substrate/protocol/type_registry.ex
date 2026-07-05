defmodule CoopSubstrate.Protocol.TypeRegistry do
  @moduledoc """
  Minimal event-type registry for Phase 1A (phase1a_plan step 4).

  Per type: payload schema, required signer roles, stream assignment, and
  disclosure class (08 §5 — carried as data now, enforced by later phases).

  Type specs are pure data (no functions) so the registry can later be
  extended or gated by prior log events (09 gated-N) without rework:
  `validity_check/2` is that hook — it receives the envelope and a log
  reader and is a no-op in 1A.

  Bootstrap types only; everything else arrives with its phase. Extension
  types can be injected through the `:extra_event_types` application env
  (tests use this; production registration workflow is a later phase).
  """

  import Bitwise

  @type disclosure_class :: :commons | :telemetry | :edges

  # Field checkers: :string | :int | :bytes | :hash | :pubkey | :bool | :any
  # Stream spec: {:chapter_scoped, prefix} => "<chapter_id>/<prefix>"
  #              {:payload_field, prefix, field} => "<chapter_id>/<prefix>/<payload[field]>"
  @builtin_types %{
    "TestProjectionEvent" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "test"},
      payload: %{
        required: %{"note" => :string, "amount_minor" => :int},
        optional: %{}
      }
    },
    "CorrectionRecorded" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "corrections"},
      payload: %{
        required: %{"target_event_hash" => :hash, "reason" => :string},
        optional: %{}
      }
    },
    "KeyRotated" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:payload_field, "keys", "member_id"},
      payload: %{
        required: %{
          "member_id" => :string,
          "old_key_id" => :string,
          "new_key_id" => :string,
          "new_pubkey" => :pubkey
        },
        optional: %{}
      }
    },
    "CharterConstantDeclared" => %{
      required_roles: ["author"],
      disclosure_class: :commons,
      stream: {:chapter_scoped, "charter"},
      payload: %{
        required: %{"name" => :string, "value" => :any},
        optional: %{"note" => :string}
      }
    }
  }

  @spec spec(String.t()) :: {:ok, map()} | {:error, :unknown_type}
  def spec(type) when is_binary(type) do
    case Map.fetch(all_types(), type) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :unknown_type}
    end
  end

  @spec registered?(String.t()) :: boolean()
  def registered?(type), do: match?({:ok, _}, spec(type))

  @spec types() :: [String.t()]
  def types, do: all_types() |> Map.keys() |> Enum.sort()

  @doc """
  Stream identity, derivable from `type` + `payload` + `chapter_id` alone
  (08 §1, 07 P7) — signers bind to the stream implicitly by signing the core.
  """
  @spec stream_id(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_id(type, chapter_id, payload) do
    with {:ok, spec} <- spec(type) do
      case spec.stream do
        {:chapter_scoped, prefix} ->
          {:ok, chapter_id <> "/" <> prefix}

        {:payload_field, prefix, field} ->
          case payload do
            %{^field => value} when is_binary(value) ->
              {:ok, chapter_id <> "/" <> prefix <> "/" <> value}

            _ ->
              {:error, {:stream_field_missing, field}}
          end
      end
    end
  end

  @doc "Every required field present and typed; unknown fields rejected (§1.3)."
  @spec validate_payload(String.t(), term()) :: :ok | {:error, term()}
  def validate_payload(type, payload) do
    with {:ok, spec} <- spec(type) do
      %{required: required, optional: optional} = spec.payload

      cond do
        not is_map(payload) ->
          {:error, {:payload_invalid, :not_a_map}}

        (missing = Map.keys(required) -- Map.keys(payload)) != [] ->
          {:error, {:payload_invalid, {:missing_fields, Enum.sort(missing)}}}

        (unknown = Map.keys(payload) -- (Map.keys(required) ++ Map.keys(optional))) != [] ->
          {:error, {:payload_invalid, {:unknown_fields, Enum.sort(unknown)}}}

        true ->
          checkers = Map.merge(optional, required)

          Enum.find_value(payload, :ok, fn {field, value} ->
            unless field_valid?(Map.fetch!(checkers, field), value) do
              {:error, {:payload_invalid, {:bad_field, field}}}
            end
          end)
      end
    end
  end

  @doc """
  Hook for log-dependent validity (09 gated-N): a type's acceptance may later
  depend on prior log events. Phase 1A performs no log-dependent checks.
  """
  @spec validity_check(struct(), term()) :: :ok
  def validity_check(_envelope, _log_reader), do: :ok

  defp field_valid?(:string, v), do: is_binary(v) and String.valid?(v)

  defp field_valid?(:int, v),
    do: is_integer(v) and v >= -(1 <<< 63) and v < 1 <<< 63

  defp field_valid?(:bytes, v), do: match?({:bytes, b} when is_binary(b), v)
  defp field_valid?(:hash, v), do: match?({:bytes, <<_::256>>}, v)
  defp field_valid?(:pubkey, v), do: match?({:bytes, <<_::256>>}, v)
  defp field_valid?(:bool, v), do: is_boolean(v)
  defp field_valid?(:any, _v), do: true

  defp all_types do
    Map.merge(@builtin_types, Application.get_env(:coop_substrate, :extra_event_types, %{}))
  end
end

defmodule CoopSubstrate.AgentEventEffects do
  @moduledoc """
  Pure, conservative discovery derivation over an accepted envelope and a
  pinned registry snapshot. Each known event requests reconciliation of its
  project, or its chapter when no project scope exists. The inert test event
  has a durable zero-effect receipt. Unknown types/versions fail closed.

  These identifiers do NOT authorize work. A reconciliation must use CURRENT
  signed TaskCore replay, approved profiles, consent and PostgreSQL lease CAS.
  No payload contents, prompts or credentials enter the discovery projection.
  """
  alias CoopSubstrate.Protocol.Envelope

  def derive(%Envelope{} = env, known_types) when is_list(known_types) do
    with true <- env.type in known_types or {:error, :unknown_event_type},
         true <-
           (is_integer(env.global_seq) and env.global_seq > 0) or {:error, :uncommitted_event},
         :ok <- Envelope.verify(env),
         {:ok, hash} <- Envelope.event_hash(env) do
      no_effect = env.type == "TestProjectionEvent"
      tenant = env.payload["tenant_id"]
      project = env.payload["project_id"]
      scoped = is_binary(tenant) and is_binary(project)

      {:ok,
       %{
         seq: env.global_seq,
         event_id: env.event_id,
         prev_hash: env.prev_global_hash,
         hash: hash,
         effect_id: if(no_effect, do: nil, else: "agent-event:" <> env.event_id),
         chapter_id: if(no_effect, do: nil, else: env.chapter_id),
         tenant_id: if(not no_effect and scoped, do: tenant, else: nil),
         project_id: if(not no_effect and scoped, do: project, else: nil)
       }}
    end
  end

  def derive(_, _), do: {:error, :invalid_event}

  def page(envelopes, checkpoint, known_types) when is_list(envelopes) do
    Enum.reduce_while(envelopes, {:ok, [], checkpoint}, fn env, {:ok, acc, previous} ->
      with {:ok, bundle} <- derive(env, known_types),
           true <-
             (bundle.seq == previous.seq + 1 and bundle.prev_hash == previous.hash) or
               {:error, :event_prefix_gap} do
        {:cont, {:ok, [bundle | acc], %{seq: bundle.seq, hash: bundle.hash}}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bundles, last} -> {:ok, Enum.reverse(bundles), last}
      error -> error
    end
  end
end

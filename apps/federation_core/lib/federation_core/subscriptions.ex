defmodule FederationCore.Subscriptions do
  @moduledoc """
  A narrow, dependency-free ActivityPub Follow/Accept/Reject/Undo wire profile.

  Only a transport that has authenticated the claimed actor may call
  decode_verified/2. Its output is an *untrusted subscription candidate*.
  It neither changes followers nor grants authority. The receiving host must
  durably correlate Accept/Reject/Undo with an original authenticated Follow,
  enforce local approval and policy, and commit delivery work separately.
  """

  @context "https://www.w3.org/ns/activitystreams"
  @keys ~w(@context id type actor to object)
  @follow_type "Follow"

  @doc "Create an outbound Follow request, not an authorized subscription."
  def follow(follower, target, activity_id) do
    with :ok <- actor_uri(follower),
         :ok <- actor_uri(target),
         :ok <- actor_uri(activity_id),
         :ok <- owner(activity_id, follower),
         true <- follower != target do
      {:ok, envelope(@follow_type, activity_id, follower, target, target)}
    else
      _ -> {:error, :invalid_follow}
    end
  end

  @doc "Prepare an Accept or Reject from a target; the host must authorize it."
  def respond(decision, target, follow_activity, activity_id)
      when decision in [:accept, :reject] do
    with {:ok, follower, ^target, _} <- validate_follow(follow_activity),
         :ok <- actor_uri(activity_id),
         :ok <- owner(activity_id, target) do
      type = if decision == :accept, do: "Accept", else: "Reject"
      {:ok, envelope(type, activity_id, target, follower, follow_activity)}
    else
      _ -> {:error, :invalid_subscription_reply}
    end
  end

  def respond(_, _, _, _), do: {:error, :invalid_subscription_reply}

  @doc "Undo a Follow using the same originating follower actor."
  def undo(follower, follow_activity, activity_id) do
    with {:ok, ^follower, target, _} <- validate_follow(follow_activity),
         :ok <- actor_uri(activity_id),
         :ok <- owner(activity_id, follower) do
      {:ok, envelope("Undo", activity_id, follower, target, follow_activity)}
    else
      _ -> {:error, :invalid_subscription_undo}
    end
  end

  @doc """
  Validate an authenticated *incoming* activity addressed to local_actor.

  Verified actor is a trusted transport result, NOT taken from the activity.
  The returned candidate must still be correlated against a durable local
  follow request or pending remote follow before taking effect.
  """
  def decode_verified(%{} = event, %{verified_actor: actor, local_actor: local_actor}) do
    with :ok <- actor_uri(actor),
         :ok <- actor_uri(local_actor),
         true <- actor != local_actor,
         :ok <- shape(event),
         true <- event["actor"] == actor,
         :ok <- owner(event["id"], actor),
         true <- event["to"] == [local_actor] do
      case event["type"] do
        "Follow" ->
          with {:ok, ^actor, ^local_actor, follow_id} <- validate_follow(event) do
            {:ok, candidate(:request, actor, actor, local_actor, follow_id, event["id"])}
          else
            _ -> {:error, :invalid_subscription_activity}
          end

        "Undo" ->
          with {:ok, ^actor, ^local_actor, follow_id} <- validate_follow(event["object"]) do
            {:ok, candidate(:withdraw, actor, actor, local_actor, follow_id, event["id"])}
          else
            _ -> {:error, :invalid_subscription_activity}
          end

        decision when decision in ["Accept", "Reject"] ->
          with {:ok, ^local_actor, ^actor, follow_id} <- validate_follow(event["object"]) do
            kind = if decision == "Accept", do: :accepted, else: :rejected
            {:ok, candidate(kind, actor, local_actor, actor, follow_id, event["id"])}
          else
            _ -> {:error, :invalid_subscription_activity}
          end

        _ ->
          {:error, :unsupported_subscription_activity}
      end
    else
      _ -> {:error, :invalid_subscription_activity}
    end
  end

  def decode_verified(_, _), do: {:error, :invalid_subscription_activity}

  defp candidate(kind, actor, follower, target, follow_id, activity_id) do
    %{
      kind: kind,
      remote_actor: actor,
      follower: follower,
      target: target,
      follow_id: follow_id,
      activity_id: activity_id,
      authoritative: false
    }
  end

  defp validate_follow(%{} = event) do
    with :ok <- shape(event),
         true <- event["type"] == @follow_type,
         follower <- event["actor"],
         target <- event["object"],
         :ok <- actor_uri(follower),
         :ok <- actor_uri(target),
         true <- follower != target,
         :ok <- owner(event["id"], follower),
         true <- event["to"] == [target] do
      {:ok, follower, target, event["id"]}
    else
      _ -> {:error, :invalid_follow}
    end
  end

  defp validate_follow(_), do: {:error, :invalid_follow}

  defp shape(%{} = activity) do
    if Enum.sort(Map.keys(activity)) == Enum.sort(@keys) and
         activity["@context"] == @context and
         is_binary(activity["type"]) and
         is_binary(activity["actor"]) and
         is_binary(activity["id"]) and
         is_list(activity["to"]),
       do: :ok,
       else: {:error, :invalid_shape}
  end

  defp envelope(type, id, actor, target, object) do
    %{
      "@context" => @context,
      "type" => type,
      "id" => id,
      "actor" => actor,
      "to" => [target],
      "object" => object
    }
  end

  defp owner(id, actor) do
    if URI.parse(id).host == URI.parse(actor).host,
      do: :ok,
      else: {:error, :foreign_activity_id}
  end

  # Structural HTTP URI policy only. Never pass these values to a fetcher
  # without separate DNS/IP/redirect/size controls and key provenance.
  defp actor_uri(value) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        port: port,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when is_binary(host) and is_binary(path) and byte_size(path) > 1 and
             port in [nil, 443] ->
        host = String.downcase(host)

        if Regex.match?(~r/\A[a-z0-9.-]+\z/, host) and
             String.contains?(host, ".") and
             not String.contains?(host, "..") and
             not String.ends_with?(host, ".local") and
             not String.ends_with?(host, ".internal") and
             match?({:error, _}, :inet.parse_address(String.to_charlist(host))),
           do: :ok,
           else: {:error, :unsafe_actor_uri}

      _ ->
        {:error, :unsafe_actor_uri}
    end
  end

  defp actor_uri(_), do: {:error, :unsafe_actor_uri}
end

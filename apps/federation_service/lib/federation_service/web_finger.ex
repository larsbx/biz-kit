defmodule FederationService.WebFinger do
  @moduledoc """
  Opt-in WebFinger resolution of the single configured public ActivityPub actor.

  This is public account discovery only: the advertised acct URI is not a
  BizKit principal, a login or a marketplace authorization grant.
  """

  @doc "Validate an explicitly disclosed public local handle; nil disables discovery."
  def handle!(nil), do: nil

  def handle!(handle) when is_binary(handle) do
    if byte_size(handle) in 1..32 and
         Regex.match?(~r/\A[a-z][a-z0-9_.-]*\z/, handle) and
         not String.contains?(handle, "..") and
         not String.ends_with?(handle, "."),
       do: handle,
       else: raise(ArgumentError, "invalid public WebFinger handle")
  end

  def handle!(_), do: raise(ArgumentError, "invalid public WebFinger handle")

  @doc "Resolve exactly this node's opted-in acct handle or canonical actor URI."
  def document(%{actor: actor, handle: handle, private_key: key}, resource)
      when is_binary(handle) and not is_nil(key) and is_binary(resource) do
    host = URI.parse(actor).host
    account = "acct:" <> handle <> "@" <> host

    if resource == account or resource == actor do
      {:ok,
       %{
         "subject" => account,
         "aliases" => [actor],
         "links" => [
           %{"rel" => "self", "type" => "application/activity+json", "href" => actor}
         ]
       }}
    else
      {:error, :unknown_resource}
    end
  end

  def document(_, _), do: {:error, :disabled}
end

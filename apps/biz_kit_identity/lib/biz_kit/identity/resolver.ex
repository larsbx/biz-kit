defmodule BizKit.Identity.Resolver do
  @moduledoc """
  Verified `{issuer, subject}` → principal, through explicit bindings only.

  The bindings are administrator-controlled configuration
  (`:biz_kit_identity, :bindings`, a list of `%{issuer, subject, principal}`;
  `BIZKIT_IDENTITY_BINDINGS` in production). Nothing is matched on email or
  any other provider attribute. Malformed bindings refuse every resolution
  rather than resolve some, and refuse boot.

  Bindings are expected to move to governance-signed ledger events, with
  this module reading their projection.
  """

  alias BizKit.Identity.Principal

  @spec resolve(BizKit.Identity.identity()) :: {:ok, Principal.id()} | {:error, term()}
  def resolve(%{issuer: issuer, subject: subject}) do
    with :ok <- check() do
      case Enum.find(bindings(), &(&1.issuer == issuer and &1.subject == subject)) do
        %{principal: principal} -> {:ok, principal}
        nil -> {:error, :unbound}
      end
    end
  end

  @doc "Every binding names a nonempty issuer and subject, once, and a valid principal."
  @spec check() :: :ok | {:error, {:invalid_bindings, term()}}
  def check do
    bindings = bindings()

    cond do
      not Enum.all?(bindings, &well_formed?/1) ->
        {:error, {:invalid_bindings, :malformed}}

      length(Enum.uniq_by(bindings, &{&1.issuer, &1.subject})) != length(bindings) ->
        {:error, {:invalid_bindings, :duplicate_identity}}

      true ->
        :ok
    end
  end

  defp well_formed?(%{issuer: i, subject: s, principal: p}),
    do: nonempty?(i) and nonempty?(s) and Principal.valid?(p)

  defp well_formed?(_binding), do: false

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp bindings, do: Application.get_env(:biz_kit_identity, :bindings, [])
end

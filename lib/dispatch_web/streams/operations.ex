defmodule DispatchWeb.Streams.Operations do
  @moduledoc """
  The live carrier roster stream required by Section 24.5.

  Authorization is revalidated on every tick. Heartbeats do not rebuild the
  roster; refreshes rebuild only after the stream-level check succeeds. The
  latter intentionally duplicates the view model's check so this boundary does
  not inherit authority accidentally from what it happens to render.
  """

  alias Dispatch.Access.Actor
  alias Dispatch.Identity.PrincipalResolution
  alias DispatchWeb.Components.Operations, as: OperationsComponents
  alias DispatchWeb.Datastar
  alias DispatchWeb.ViewModels.OperationsView

  @retry_ms 3_000

  @enforce_keys [:actor, :organization_id]
  defstruct [:actor, :organization_id]

  @type t :: %__MODULE__{
          actor: Actor.t(),
          organization_id: Ash.UUID.t()
        }
  @type reason :: :heartbeat | :refresh

  @spec open(Actor.t()) :: {:ok, t(), iodata()} | {:error, :not_found}
  def open(%Actor{} = actor) do
    with {:ok, actor} <- revalidate(actor),
         {:ok, view} <- OperationsView.build(actor) do
      session = %__MODULE__{
        actor: actor,
        organization_id: actor.role_assignment.organization_id
      }

      {:ok, session, [Datastar.retry(@retry_ms), patch(view)]}
    else
      _nothing_to_stream -> {:error, :not_found}
    end
  end

  @spec tick(t(), reason()) :: {:emit, iodata(), t()} | {:close, :unauthorized}
  def tick(%__MODULE__{} = session, :heartbeat) do
    case revalidate(session.actor) do
      {:ok, actor} -> {:emit, Datastar.heartbeat(), %{session | actor: actor}}
      {:error, _gone} -> {:close, :unauthorized}
    end
  end

  def tick(%__MODULE__{} = session, :refresh) do
    with {:ok, actor} <- revalidate(session.actor),
         {:ok, view} <- OperationsView.build(actor) do
      {:emit, patch(view), %{session | actor: actor}}
    else
      _gone -> {:close, :unauthorized}
    end
  end

  defp revalidate(actor), do: PrincipalResolution.revalidate(actor)

  defp patch(view) do
    %{view: view}
    |> OperationsComponents.operations_roster()
    |> Phoenix.HTML.Safe.to_iodata()
    |> Datastar.patch_elements(id: Ash.UUID.generate())
  end
end

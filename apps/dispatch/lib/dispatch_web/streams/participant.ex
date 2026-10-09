defmodule DispatchWeb.Streams.Participant do
  @moduledoc """
  The live participant stream of Section 24.5.

  ## Authorization is per tick, not per connection

  A page authorizes once, answers, and is gone. A stream authorizes once and
  then keeps answering — for hours, if nobody closes the tab. So "authorized"
  has to be a claim about every tick rather than about the request that opened
  it. Section 33.2 requires revoked, expired, wrong-tenant and wrong-scope
  assignments to fail closed "across REST, Datastar, agent tools, jobs, and SSE
  reconnects", and acceptance criterion 16 requires a dispatcher to lose the
  stream *immediately* when the relationship ends.

  `tick/2` therefore revalidates before it renders, and returns `{:close,
  :unauthorized}` rather than an emptier fragment. The ordering is the whole
  point: rendering first and checking afterwards would send one last
  authorized-looking patch to somebody who is no longer authorized, and that
  patch is indistinguishable from a legitimate one at the browser.

  The two paths differ in what that check is worth. On a **heartbeat** it is the
  only thing standing between a revoked viewer and an indefinitely open socket,
  because nothing else on that path touches the database — a planted version
  that skips it fails the revocation test. On a **refresh** it duplicates a
  check `OperationsParticipantView.build/2` already performs, so removing it
  changes no test. That duplication is deliberate rather than overlooked: the
  view model lost its own revalidation once already, silently, and the layer
  that noticed was the one above it. A stream should not depend on an
  implementation detail of what it renders.

  ## A struct and two functions, not a process

  The transport loop — receiving outbox notifications, writing chunks, noticing
  a disconnect — lives in the controller. What lives here is the decision: given
  a session and something that happened, emit what, or stop.

  That split is what makes "immediately" testable. A test can drive tick after
  tick with a revocation in between and assert the very next one closes, rather
  than revoking, sleeping, and inspecting a socket — which passes whether the
  stream noticed or merely timed out.

  ## Fragments are authorized before they are encoded

  Section 24.5: "SSE content MUST already be field-authorized for the connected
  viewer. The browser never filters confidential fields." Every fragment here
  is rendered from `DispatchWeb.ViewModels.OperationsParticipantView`, which
  cannot carry what the viewer may not see — the same boundary the page uses,
  for the same reason.
  """

  alias Dispatch.Access.Actor
  alias Dispatch.Identity.PrincipalResolution
  alias DispatchWeb.Components.Operations
  alias DispatchWeb.Datastar
  alias DispatchWeb.ViewModels.OperationsParticipantView

  @retry_ms 3_000

  @enforce_keys [:actor, :participant_id]
  defstruct [:actor, :participant_id]

  @type t :: %__MODULE__{actor: Actor.t(), participant_id: Ash.UUID.t()}

  @typedoc "Why a tick happened: the heartbeat fired, or something changed."
  @type reason :: :heartbeat | :refresh

  @doc """
  Opens a stream, or reports nothing.

  Returns the initial snapshot Section 24.5 requires, so a client connecting to
  a quiet stream sees the current state rather than an empty region.

  `last_event_id` is accepted and deliberately not used to replay. Section 24.5
  permits exactly this: "If replay is unavailable, the server sends fresh
  snapshots for every subscribed region rather than attempting client-side
  reconciliation." A reconnect is a new authorization, not a resumption of an
  old one — the identifier a client presents was issued when it was entitled to
  the data, which says nothing about now.
  """
  @spec open(Actor.t(), Ash.UUID.t(), keyword()) ::
          {:ok, t(), iodata()} | {:error, :not_found}
  def open(%Actor{} = actor, participant_id, _opts \\ []) do
    with {:ok, actor} <- revalidate(actor),
         {:ok, view} <- OperationsParticipantView.build(actor, participant_id) do
      session = %__MODULE__{actor: actor, participant_id: participant_id}
      {:ok, session, [Datastar.retry(@retry_ms), patch(view)]}
    else
      _nothing_to_stream -> {:error, :not_found}
    end
  end

  @doc """
  Advances the stream.

  Revalidates first, every time, whatever the reason. A heartbeat is the cheap
  tick that keeps the connection alive; making it also the tick that re-checks
  authority means an idle stream cannot outlive the grant behind it, which is
  the case a stream-closing-on-the-next-event design quietly misses.
  """
  @spec tick(t(), reason()) :: {:emit, iodata(), t()} | {:close, :unauthorized}
  def tick(%__MODULE__{} = session, :heartbeat) do
    # The cheap tick, and the one that matters most for "immediately". A
    # heartbeat carries nothing, so it would be easy to let it pass without
    # asking anything — and then an idle stream outlives the grant behind it for
    # as long as nobody happens to change the data. Section 24.5 already
    # requires a beat every twenty seconds; making that beat the revalidation is
    # what bounds how long a revoked viewer can keep a socket open.
    case revalidate(session.actor) do
      {:ok, actor} -> {:emit, Datastar.heartbeat(), %{session | actor: actor}}
      {:error, _gone} -> {:close, :unauthorized}
    end
  end

  def tick(%__MODULE__{} = session, :refresh) do
    case rebuild(session) do
      {:ok, session, view} -> {:emit, patch(view), session}
      :error -> {:close, :unauthorized}
    end
  end

  # Both halves re-read: the assignment, because an `Actor` carries its
  # authority as a value, and the subject, because the relationship that made it
  # visible can end without the assignment changing at all.
  defp rebuild(session) do
    with {:ok, actor} <- revalidate(session.actor),
         {:ok, view} <- OperationsParticipantView.build(actor, session.participant_id) do
      {:ok, %{session | actor: actor}, view}
    else
      _gone -> :error
    end
  end

  defp revalidate(actor), do: PrincipalResolution.revalidate(actor)

  defp patch(view) do
    %{view: view}
    |> Operations.participant_page()
    |> Phoenix.HTML.Safe.to_iodata()
    |> Datastar.patch_elements(id: Ash.UUID.generate())
  end
end

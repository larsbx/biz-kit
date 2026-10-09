defmodule Dispatch.Communications do
  @moduledoc """
  Conversations, messages, calls, call turns, action proposals, approvals, and
  execution receipts.

  Section 27.6 gives all of it one priority class, processed in receipt order.
  There is no `priority`, `severity`, or `urgency` attribute on any resource in
  this domain, and Section 8.2 leaves no call state that could ring the
  driver's handset.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end

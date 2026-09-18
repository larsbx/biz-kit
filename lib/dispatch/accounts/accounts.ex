defmodule Dispatch.Accounts do
  @moduledoc """
  Users, organizations, memberships, participants, devices, contacts, and the
  role definitions and assignments of Section 23.2.

  Authorization is expressed here rather than in controllers: Section 23.3
  requires reusable named policy checks over capabilities and scope, so a role
  is data this domain validates, never a branch in a request handler.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end

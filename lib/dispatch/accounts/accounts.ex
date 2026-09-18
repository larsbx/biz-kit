defmodule Dispatch.Accounts do
  @moduledoc """
  Users, organizations, memberships, participants, devices, contacts, and the
  role definitions and assignments of Section 23.2.

  Authorization is expressed here rather than in controllers: Section 23.3
  requires reusable named policy checks over capabilities and scope, so a role
  is data this domain validates, never a branch in a request handler.

  """

  use Ash.Domain

  resources do
    resource Dispatch.Accounts.Organization
    resource Dispatch.Accounts.User
    resource Dispatch.Accounts.OrganizationMembership
    resource Dispatch.Accounts.Participant
    resource Dispatch.Accounts.RoleDefinition
    resource Dispatch.Accounts.RoleAssignment
    resource Dispatch.Accounts.Device
    resource Dispatch.Accounts.Contact
  end
end

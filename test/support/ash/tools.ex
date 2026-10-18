defmodule LiveRender.Test.SupportTools do
  @moduledoc false
  # The allowlist used by the AshAdapter tests. `Ticket.hidden_update` is deliberately absent.
  use LiveRender.OpenUI.AshAdapter

  alias LiveRender.Test.Support.Ticket

  tool("listTickets", Ticket, :list,
    description: "Tickets, filtered by status",
    load: [:shout, :comment_count, :comments]
  )

  tool("pagedTickets", Ticket, :list, pagination: true, limit: 2, fields: [:id, :title])
  tool("ticketList", Ticket, :list, result: :list, fields: [:title])
  tool("ticketByTitle", Ticket, :by_title)
  tool("createTicket", Ticket, :create)
  tool("closeTicket", Ticket, :close)
  tool("renameTicket", Ticket, :rename)
  tool("deleteTicket", Ticket, :destroy)
  tool("openTicketCount", Ticket, :open_count)
  tool("echo", Ticket, :echo)
end

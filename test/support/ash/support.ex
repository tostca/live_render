defmodule LiveRender.Test.Support do
  @moduledoc false
  # An Ash domain for the AshAdapter tests: tickets with policies and attribute multitenancy,
  # stored in private ETS tables (one set per test process).
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(LiveRender.Test.Support.Ticket)
    resource(LiveRender.Test.Support.Comment)
  end
end

defmodule LiveRender.Test.Support.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: LiveRender.Test.Support,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private?(true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
      description("A short summary")
      constraints(max_length: 120)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:open)
      constraints(one_of: [:open, :closed])
    end

    attribute :priority, :integer do
      public?(true)
      constraints(min: 1, max: 5)
    end

    attribute(:org_id, :string, allow_nil?: false, public?: true)
    attribute(:owner_id, :string, public?: true)

    # Never leaves the server: private ...
    attribute(:internal_notes, :string, public?: false)
    # ... or public but sensitive.
    attribute(:secret_token, :string, public?: true, sensitive?: true)
  end

  relationships do
    has_many(:comments, LiveRender.Test.Support.Comment, public?: true)
  end

  calculations do
    calculate(:shout, :string, expr(title <> "!"), public?: true)
    calculate(:hidden_calc, :string, expr(title), public?: false)
  end

  aggregates do
    count(:comment_count, :comments, public?: true)
  end

  actions do
    defaults([:read])

    # The ETS data layer cannot raise policy errors from atomic updates, so these actions run
    # on the loaded record instead.
    destroy :destroy do
      primary?(true)
      require_atomic?(false)
    end

    read :list do
      argument(:status, :atom, constraints: [one_of: [:open, :closed]])
      filter(expr(is_nil(^arg(:status)) or status == ^arg(:status)))
      pagination(offset?: true, required?: false, countable: true)
    end

    read :by_title do
      get?(true)
      argument(:title, :string, allow_nil?: false)
      filter(expr(title == ^arg(:title)))
    end

    create :create do
      primary?(true)
      accept([:title, :priority, :internal_notes, :secret_token])
      argument(:internal_flag, :boolean, public?: false)
      change(set_attribute(:owner_id, actor(:id)))
    end

    update :close do
      require_atomic?(false)
      accept([])
      change(set_attribute(:status, :closed))
    end

    update :rename do
      require_atomic?(false)
      accept([:title])
    end

    update :hidden_update do
      public?(false)
      accept([:title])
    end

    action :open_count, :integer do
      argument(:min_priority, :integer, default: 1)

      run(fn input, context ->
        LiveRender.Test.Support.Ticket
        |> Ash.Query.for_read(:list, %{status: :open}, Ash.Context.to_opts(context))
        |> Ash.read()
        |> case do
          {:ok, tickets} ->
            {:ok, Enum.count(tickets, &((&1.priority || 1) >= input.arguments.min_priority))}

          error ->
            error
        end
      end)
    end

    action :echo, :map do
      argument(:message, :string, allow_nil?: false)
      run(fn input, _context -> {:ok, %{message: input.arguments.message}} end)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_present())
    end

    policy action(:create) do
      authorize_if(actor_attribute_equals(:role, :agent))
    end

    policy action([:close, :rename, :destroy]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    policy action_type(:action) do
      authorize_if(actor_present())
    end
  end
end

defmodule LiveRender.Test.Support.Comment do
  @moduledoc false
  use Ash.Resource,
    domain: LiveRender.Test.Support,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  multitenancy do
    strategy(:attribute)
    attribute(:org_id)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true)
    attribute(:org_id, :string, allow_nil?: false, public?: true)
    attribute(:author_email, :string, public?: true, sensitive?: true)
  end

  relationships do
    belongs_to(:ticket, LiveRender.Test.Support.Ticket, public?: true, attribute_writable?: true)
  end

  actions do
    defaults([:read, create: [:body, :author_email, :ticket_id]])
  end
end

defmodule AshPostgres.Test.Rating do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  postgres do
    polymorphic?(true)
    repo AshPostgres.TestRepo
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:score, :integer)
    attribute(:resource_id, :uuid)
  end
end

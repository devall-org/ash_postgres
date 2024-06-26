defmodule AshPostgresTest do
  use AshPostgres.RepoCase, async: false

  test "transaction metadata is given to on_transaction_begin" do
    AshPostgres.Test.Post
    |> Ash.Changeset.new(%{title: "title"})
    |> AshPostgres.Test.Api.create!()

    assert_receive %{
      type: :create,
      metadata: %{action: :create, actor: nil, resource: AshPostgres.Test.Post}
    }
  end

  test "filter policies are applied" do
    post =
      AshPostgres.Test.Post
      |> Ash.Changeset.new(%{title: "good"})
      |> AshPostgres.Test.Api.create!()

    assert_raise Ash.Error.Forbidden, fn ->
      post
      |> Ash.Changeset.for_update(:update, %{title: "bad"},
        authorize?: true,
        actor: %{id: Ash.UUID.generate()}
      )
      |> AshPostgres.Test.Api.update!()
      |> Map.get(:title)
    end

    post
    |> Ash.Changeset.for_update(:update, %{title: "okay"}, authorize?: true)
    |> AshPostgres.Test.Api.update!()
    |> Map.get(:title)
  end
end

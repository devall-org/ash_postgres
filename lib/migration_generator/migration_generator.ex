defmodule AshPostgres.MigrationGenerator do
  @moduledoc """
  Generates migrations based on resource snapshots

  See `Mix.Tasks.AshPostgres.GenerateMigrations` for more information.
  """
  @default_snapshot_path "priv/resource_snapshots"

  import Mix.Generator

  alias AshPostgres.MigrationGenerator.{Operation, Phase}

  defstruct snapshot_path: @default_snapshot_path, migration_path: nil, quiet: false, format: true

  def generate(apis, opts \\ []) do
    apis = List.wrap(apis)
    opts = struct(__MODULE__, opts)

    snapshots =
      apis
      |> Enum.flat_map(&Ash.Api.resources/1)
      |> Enum.filter(&(Ash.Resource.data_layer(&1) == AshPostgres.DataLayer))
      |> Enum.filter(&AshPostgres.migrate?/1)
      |> Enum.map(&get_snapshot/1)

    snapshots
    |> Enum.group_by(& &1.repo)
    |> Enum.each(fn {repo, snapshots} ->
      deduped = deduplicate_snapshots(snapshots, opts)

      snapshots = Enum.map(deduped, &elem(&1, 0))

      deduped
      |> fetch_operations()
      |> Enum.uniq()
      |> case do
        [] ->
          Mix.shell().info(
            "No changes detected, so no migrations or snapshots have been created."
          )

          :ok

        operations ->
          operations
          |> sort_operations()
          |> streamline()
          |> group_into_phases()
          |> build_up_and_down()
          |> write_migration(snapshots, repo, opts)
      end
    end)
  end

  defp deduplicate_snapshots(snapshots, opts) do
    snapshots
    |> Enum.group_by(fn snapshot ->
      snapshot.table
    end)
    |> Enum.map(fn {_table, [snapshot | _] = snapshots} ->
      existing_snapshot = get_existing_snapshot(snapshot, opts)
      {primary_key, identities} = merge_primary_keys(existing_snapshot, snapshots)

      attributes = Enum.flat_map(snapshots, & &1.attributes)

      snapshot_identities =
        snapshots
        |> Enum.map(& &1.identities)
        |> Enum.concat()

      new_snapshot = %{
        snapshot
        | attributes: merge_attributes(attributes, snapshot.table),
          identities: snapshot_identities
      }

      all_identities =
        new_snapshot.identities
        |> Kernel.++(identities)
        |> Enum.sort_by(& &1.name)
        |> Enum.uniq_by(fn identity ->
          Enum.sort(identity.keys)
        end)

      new_snapshot = %{new_snapshot | identities: all_identities}

      {
        %{
          new_snapshot
          | attributes:
              Enum.map(new_snapshot.attributes, fn attribute ->
                if attribute.name in primary_key do
                  %{attribute | primary_key?: true}
                else
                  %{attribute | primary_key?: false}
                end
              end)
        },
        existing_snapshot
      }
    end)
  end

  defp merge_attributes(attributes, table) do
    attributes
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn
      {_name, [attribute]} ->
        attribute

      {name, attributes} ->
        %{
          name: name,
          type: merge_types(Enum.map(attributes, & &1.type), name, table),
          default: merge_defaults(Enum.map(attributes, & &1.default)),
          allow_nil?: Enum.any?(attributes, & &1.allow_nil?),
          references: merge_references(Enum.map(attributes, & &1.references), name, table),
          primary_key?: false
        }
    end)
  end

  defp merge_references(references, name, table) do
    references
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      [reference] ->
        reference

      references ->
        conflicting_table_field_names =
          Enum.map_join(references, "\n", fn reference ->
            "* #{reference.table}.#{reference.destination_field}"
          end)

        raise "Conflicting references for `#{table}.#{name}`:\n#{conflicting_table_field_names}"
    end
  end

  defp merge_types(types, name, table) do
    types
    |> Enum.uniq()
    |> case do
      [type] ->
        type

      types ->
        raise "Conflicting types for table `#{table}.#{name}`: #{inspect(types)}"
    end
  end

  defp merge_defaults(defaults) do
    defaults
    |> Enum.uniq()
    |> case do
      [default] -> default
      _ -> nil
    end
  end

  defp merge_primary_keys(nil, [snapshot | _] = snapshots) do
    snapshots
    |> Enum.map(&pkey_names(&1.attributes))
    |> Enum.uniq()
    |> case do
      [pkey_names] ->
        {pkey_names, []}

      unique_primary_keys ->
        unique_primary_key_names =
          unique_primary_keys
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {pkey, index} ->
            "#{index}: #{inspect(pkey)}"
          end)

        message = """
        Which primary key should be used for the table `#{snapshot.table}` (enter the number)?

        #{unique_primary_key_names}
        """

        choice =
          message
          |> Mix.shell().prompt()
          |> String.to_integer()

        identities =
          unique_primary_keys
          |> List.delete_at(choice)
          |> Enum.map(fn pkey_names ->
            pkey_name_string = Enum.join(pkey_names, "_")
            name = snapshot.table <> "_" <> pkey_name_string

            %{
              keys: pkey_names,
              name: name
            }
          end)

        primary_key = Enum.sort(Enum.at(unique_primary_keys, choice))

        identities =
          Enum.reject(identities, fn identity ->
            Enum.sort(identity.keys) == primary_key
          end)

        {primary_key, identities}
    end
  end

  defp merge_primary_keys(existing_snapshot, snapshots) do
    pkey_names = pkey_names(existing_snapshot.attributes)

    one_pkey_exists? =
      Enum.any?(snapshots, fn snapshot ->
        pkey_names(snapshot.attributes) == pkey_names
      end)

    if one_pkey_exists? do
      identities =
        snapshots
        |> Enum.map(&pkey_names(&1.attributes))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == pkey_names))
        |> Enum.map(fn pkey_names ->
          pkey_name_string = Enum.join(pkey_names, "_")
          name = existing_snapshot.table <> "_" <> pkey_name_string

          %{
            keys: pkey_names,
            name: name
          }
        end)

      {pkey_names, identities}
    else
      merge_primary_keys(nil, snapshots)
    end
  end

  defp pkey_names(attributes) do
    attributes
    |> Enum.filter(& &1.primary_key?)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp write_migration({up, down}, snapshots, repo, opts) do
    repo_name = repo |> Module.split() |> List.last() |> Macro.underscore()

    Enum.each(snapshots, fn snapshot ->
      snapshot_binary = snapshot_to_binary(snapshot)

      snapshot_file =
        opts.snapshot_path
        |> Path.join(repo_name)
        |> Path.join(snapshot.table <> ".json")

      File.mkdir_p(Path.dirname(snapshot_file))
      File.write!(snapshot_file, snapshot_binary, [])
    end)

    migration_path =
      if opts.migration_path do
        opts.migration_path
      else
        "priv/"
      end
      |> Path.join(repo_name)
      |> Path.join("migrations")

    count =
      migration_path
      |> Path.join("*_migrate_resources*")
      |> Path.wildcard()
      |> Enum.count()
      |> Kernel.+(1)

    migration_name = "#{timestamp()}_migrate_resources#{count}"

    migration_file =
      migration_path
      |> Path.join(migration_name <> ".exs")

    module_name = Module.concat([repo, Migrations, Macro.camelize("migrate_resources#{count}")])

    contents = """
    defmodule #{inspect(module_name)} do
      @moduledoc \"\"\"
      Updates resources based on their most recent snapshots.

      This file was autogenerated with `mix ash_postgres.generate_migrations`
      \"\"\"

      use Ecto.Migration

      def up() do
        #{up}
      end

      def down() do
        #{down}
      end
    end
    """

    create_file(migration_file, format(contents, opts))
  end

  defp build_up_and_down(phases) do
    up =
      Enum.map_join(phases, "\n", fn phase ->
        phase.__struct__.up(phase) <> "\n"
      end)

    down =
      phases
      |> Enum.reverse()
      |> Enum.map_join("\n", fn phase ->
        phase.__struct__.down(phase) <> "\n"
      end)

    {up, down}
  end

  defp format(string, opts) do
    if opts.format do
      Code.format_string!(string)
    else
      string
    end
  end

  defp streamline(ops, acc \\ [])
  defp streamline([], acc), do: Enum.reverse(acc)

  defp streamline(
         [
           %Operation.AddAttribute{
             attribute: %{
               name: name
             },
             table: table
           } = add,
           %AshPostgres.MigrationGenerator.Operation.AlterAttribute{
             new_attribute: %{
               name: name,
               references: references
             },
             old_attribute: %{
               name: name
             },
             table: table
           }
           | rest
         ],
         acc
       )
       when not is_nil(references) do
    new_attribute = Map.put(add.attribute, :references, references)

    streamline(
      rest,
      [%{add | attribute: new_attribute} | acc]
    )
  end

  defp streamline([first | rest], acc) do
    streamline(rest, [first | acc])
  end

  defp group_into_phases(ops, current \\ nil, acc \\ [])

  defp group_into_phases([], nil, acc), do: Enum.reverse(acc)

  defp group_into_phases([], phase, acc) do
    phase = %{phase | operations: Enum.reverse(phase.operations)}
    Enum.reverse([phase | acc])
  end

  defp group_into_phases([%Operation.CreateTable{table: table} | rest], nil, acc) do
    group_into_phases(rest, %Phase.Create{table: table}, acc)
  end

  defp group_into_phases(
         [%Operation.AddAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.AlterAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.RenameAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.RemoveAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases([operation | rest], nil, acc) do
    group_into_phases(rest, nil, [
      %Phase.Alter{operations: [operation], table: operation.table} | acc
    ])
  end

  defp group_into_phases(operations, phase, acc) do
    phase = %{phase | operations: Enum.reverse(phase.operations)}
    group_into_phases(operations, nil, [phase | acc])
  end

  defp sort_operations(ops, acc \\ [])
  defp sort_operations([], acc), do: acc

  defp sort_operations([op | rest], []), do: sort_operations(rest, [op])

  defp sort_operations([op | rest], acc) do
    acc = Enum.reverse(acc)

    after_index = Enum.find_index(acc, &after?(op, &1))

    new_acc =
      if after_index do
        acc
        |> List.insert_at(after_index, op)
        |> Enum.reverse()
      else
        [op | Enum.reverse(acc)]
      end

    sort_operations(rest, new_acc)
  end

  defp after?(
         %Operation.AddUniqueIndex{identity: %{keys: keys}, table: table},
         %Operation.AddAttribute{table: table, attribute: %{name: name}}
       ) do
    name in keys
  end

  defp after?(
         %Operation.AddUniqueIndex{identity: %{keys: keys}, table: table},
         %Operation.AlterAttribute{table: table, new_attribute: %{name: name}}
       ) do
    name in keys
  end

  defp after?(
         %Operation.AddUniqueIndex{identity: %{keys: keys}, table: table},
         %Operation.RenameAttribute{table: table, new_attribute: %{name: name}}
       ) do
    name in keys
  end

  defp after?(
         %Operation.RemoveUniqueIndex{identity: %{keys: keys}, table: table},
         %Operation.RemoveAttribute{table: table, attribute: %{name: name}}
       ) do
    name in keys
  end

  defp after?(
         %Operation.RemoveUniqueIndex{identity: %{keys: keys}, table: table},
         %Operation.RenameAttribute{table: table, old_attribute: %{name: name}}
       ) do
    name in keys
  end

  defp after?(%Operation.AddAttribute{table: table}, %Operation.CreateTable{table: table}) do
    true
  end

  defp after?(
         %Operation.AddAttribute{
           attribute: %{
             references: %{table: table, destination_field: name}
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{name: name}}
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: false
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{primary_key?: true}}
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         },
         %Operation.RemoveAttribute{table: table, attribute: %{primary_key?: true}}
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{primary_key?: true}
         },
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         }
       ),
       do: true

  defp after?(
         %Operation.RemoveAttribute{attribute: %{name: name}, table: table},
         %Operation.AlterAttribute{
           old_attribute: %{references: %{table: table, destination_field: name}}
         }
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           new_attribute: %{
             references: %{table: table, destination_field: name}
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{name: name}}
       ),
       do: true

  defp after?(%Operation.AddUniqueIndex{table: table}, %Operation.CreateTable{table: table}) do
    true
  end

  defp after?(%Operation.AlterAttribute{new_attribute: %{references: references}}, _)
       when not is_nil(references),
       do: true

  defp after?(_, _), do: false

  defp fetch_operations(snapshots) do
    Enum.flat_map(snapshots, fn {snapshot, existing_snapshot} ->
      do_fetch_operations(snapshot, existing_snapshot)
    end)
  end

  defp do_fetch_operations(snapshot, existing_snapshot, acc \\ [])

  defp do_fetch_operations(snapshot, nil, acc) do
    empty_snapshot = %{
      attributes: [],
      identities: [],
      table: snapshot.table,
      repo: snapshot.repo
    }

    do_fetch_operations(snapshot, empty_snapshot, [
      %Operation.CreateTable{table: snapshot.table} | acc
    ])
  end

  defp do_fetch_operations(snapshot, old_snapshot, acc) do
    attribute_operations = attribute_operations(snapshot, old_snapshot)

    unique_indexes_to_remove =
      old_snapshot.identities
      |> Enum.reject(fn old_identity ->
        Enum.find(snapshot.identities, fn identity ->
          Enum.sort(old_identity.keys) == Enum.sort(identity.keys)
        end)
      end)
      |> Enum.map(fn identity ->
        %Operation.RemoveUniqueIndex{identity: identity, table: snapshot.table}
      end)

    unique_indexes_to_add =
      snapshot.identities
      |> Enum.reject(fn identity ->
        Enum.find(old_snapshot.identities, fn old_identity ->
          Enum.sort(old_identity.keys) == Enum.sort(identity.keys)
        end)
      end)
      |> Enum.map(fn identity ->
        %Operation.AddUniqueIndex{identity: identity, table: snapshot.table}
      end)

    attribute_operations ++ unique_indexes_to_add ++ unique_indexes_to_remove ++ acc
  end

  defp attribute_operations(snapshot, old_snapshot) do
    attributes_to_add =
      Enum.reject(snapshot.attributes, fn attribute ->
        Enum.find(old_snapshot.attributes, &(&1.name == attribute.name))
      end)

    attributes_to_remove =
      Enum.reject(old_snapshot.attributes, fn attribute ->
        Enum.find(snapshot.attributes, &(&1.name == attribute.name))
      end)

    {attributes_to_add, attributes_to_remove, attributes_to_rename} =
      resolve_renames(attributes_to_add, attributes_to_remove)

    attributes_to_alter =
      snapshot.attributes
      |> Enum.map(fn attribute ->
        {attribute,
         Enum.find(old_snapshot.attributes, &(&1.name == attribute.name && &1 != attribute))}
      end)
      |> Enum.filter(&elem(&1, 1))

    rename_attribute_events =
      Enum.map(attributes_to_rename, fn {new, old} ->
        %Operation.RenameAttribute{new_attribute: new, old_attribute: old, table: snapshot.table}
      end)

    add_attribute_events =
      Enum.flat_map(attributes_to_add, fn attribute ->
        if attribute.references do
          [
            %Operation.AddAttribute{
              attribute: Map.delete(attribute, :references),
              table: snapshot.table
            },
            %Operation.AlterAttribute{
              old_attribute: Map.delete(attribute, :references),
              new_attribute: attribute,
              table: snapshot.table
            }
          ]
        else
          [
            %Operation.AddAttribute{
              attribute: attribute,
              table: snapshot.table
            }
          ]
        end
      end)

    alter_attribute_events =
      Enum.flat_map(attributes_to_alter, fn {new_attribute, old_attribute} ->
        if new_attribute.references do
          [
            %Operation.AlterAttribute{
              new_attribute: Map.delete(new_attribute, :references),
              old_attribute: old_attribute,
              table: snapshot.table
            },
            %Operation.AlterAttribute{
              new_attribute: new_attribute,
              old_attribute: Map.delete(new_attribute, :references),
              table: snapshot.table
            }
          ]
        else
          [
            %Operation.AlterAttribute{
              new_attribute: new_attribute,
              old_attribute: old_attribute,
              table: snapshot.table
            }
          ]
        end
      end)

    remove_attribute_events =
      Enum.map(attributes_to_remove, fn attribute ->
        %Operation.RemoveAttribute{attribute: attribute, table: snapshot.table}
      end)

    add_attribute_events ++
      alter_attribute_events ++ remove_attribute_events ++ rename_attribute_events
  end

  def get_existing_snapshot(snapshot, opts) do
    repo_name = snapshot.repo |> Module.split() |> List.last() |> Macro.underscore()
    folder = Path.join(opts.snapshot_path, repo_name)
    file = Path.join(folder, snapshot.table <> ".json")

    if File.exists?(file) do
      existing_snapshot =
        file
        |> File.read!()
        |> load_snapshot()

      existing_snapshot
    end
  end

  defp resolve_renames(adding, []), do: {adding, [], []}

  defp resolve_renames([adding], [removing]) do
    if Mix.shell().yes?("Are you renaming :#{removing.name} to :#{adding.name}?") do
      {[], [], [{adding, removing}]}
    else
      {[adding], [removing], []}
    end
  end

  defp resolve_renames(adding, [removing | rest]) do
    {new_adding, new_removing, new_renames} =
      if Mix.shell().yes?("Are you renaming :#{removing.name}?") do
        new_attribute = get_new_attribute(adding)

        {adding -- [new_attribute], [], [{new_attribute, removing}]}
      else
        {adding, [removing], []}
      end

    {rest_adding, rest_removing, rest_renames} = resolve_renames(new_adding, rest)

    {new_adding ++ rest_adding, new_removing ++ rest_removing, rest_renames ++ new_renames}
  end

  defp get_new_attribute(adding, tries \\ 3)

  defp get_new_attribute(_adding, 0) do
    raise "Could not get matching name after 3 attempts."
  end

  defp get_new_attribute(adding, tries) do
    name =
      Mix.shell().prompt(
        "What are you renaming it to?: #{Enum.map_join(adding, ", ", & &1.name)}"
      )

    case Enum.find(adding, &(to_string(&1.name) == name)) do
      nil -> get_new_attribute(adding, tries - 1)
      new_attribute -> new_attribute
    end
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  def get_snapshot(resource) do
    snapshot = %{
      attributes: attributes(resource),
      identities: identities(resource),
      table: AshPostgres.table(resource),
      repo: AshPostgres.repo(resource)
    }

    hash =
      :sha256
      |> :crypto.hash(inspect(snapshot))
      |> Base.encode16()

    Map.put(snapshot, :hash, hash)
  end

  def attributes(resource) do
    repo = AshPostgres.repo(resource)

    resource
    |> Ash.Resource.attributes()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&Map.take(&1, [:name, :type, :default, :allow_nil?, :primary_key?]))
    |> Enum.map(fn attribute ->
      default = default(attribute, repo)

      attribute
      |> Map.put(:default, default)
      |> Map.update!(:type, fn type ->
        type
        |> Ash.Type.storage_type()
        |> migration_type()
      end)
    end)
    |> Enum.map(fn attribute ->
      references = find_reference(resource, attribute)

      Map.put(attribute, :references, references)
    end)
  end

  defp find_reference(resource, attribute) do
    Enum.find_value(Ash.Resource.relationships(resource), fn relationship ->
      if attribute.name == relationship.source_field && relationship.type == :belongs_to &&
           foreign_key?(relationship) do
        %{
          destination_field: relationship.destination_field,
          table: AshPostgres.table(relationship.destination)
        }
      end
    end)
  end

  defp migration_type(:string), do: :text
  defp migration_type(:integer), do: :integer
  defp migration_type(:boolean), do: :boolean
  defp migration_type(:binary_id), do: :binary_id
  defp migration_type(other), do: raise("No migration_type set up for #{other}")

  defp foreign_key?(relationship) do
    Ash.Resource.data_layer(relationship.source) == AshPostgres.DataLayer &&
      AshPostgres.repo(relationship.source) == AshPostgres.repo(relationship.destination)
  end

  defp identities(resource) do
    resource
    |> Ash.Resource.identities()
    |> Enum.filter(fn identity ->
      Enum.all?(identity.keys, fn key ->
        Ash.Resource.attribute(resource, key)
      end)
    end)
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&Map.take(&1, [:name, :keys]))
  end

  if :erlang.function_exported(Ash, :uuid, 0) do
    @uuid_functions [&Ash.uuid/0, &Ecto.UUID.generate/0]
  else
    @uuid_functions [&Ecto.UUID.generate/0]
  end

  defp default(%{default: default}, repo) when is_function(default) do
    cond do
      default in @uuid_functions && "uuid-ossp" in (repo.config()[:installed_extensions] || []) ->
        ~S[fragment("uuid_generate_v4()")]

      default == (&DateTime.utc_now/0) ->
        ~S[fragment("now()")]

      true ->
        "nil"
    end
  end

  defp default(%{default: {_, _, _}}, _), do: "nil"

  defp default(%{default: value, type: type}, _) do
    case Ash.Type.dump_to_native(type, value) do
      {:ok, value} -> inspect(value)
      _ -> "nil"
    end
  end

  defp snapshot_to_binary(snapshot) do
    Jason.encode!(snapshot, pretty: true)
  end

  defp load_snapshot(json) do
    json
    |> Jason.decode!(keys: :atoms!)
    |> Map.update!(:identities, fn identities ->
      Enum.map(identities, &load_identity/1)
    end)
    |> Map.update!(:attributes, fn attributes ->
      Enum.map(attributes, &load_attribute/1)
    end)
    |> Map.update!(:repo, &String.to_atom/1)
  end

  defp load_attribute(attribute) do
    attribute
    |> Map.update!(:type, &String.to_atom/1)
    |> Map.update!(:name, &String.to_atom/1)
    |> Map.update!(:references, fn
      nil ->
        nil

      references ->
        Map.update!(references, :destination_field, &String.to_atom/1)
    end)
  end

  defp load_identity(identity) do
    identity
    |> Map.update!(:name, &String.to_atom/1)
    |> Map.update!(:keys, fn keys ->
      Enum.map(keys, &String.to_atom/1)
    end)
  end
end
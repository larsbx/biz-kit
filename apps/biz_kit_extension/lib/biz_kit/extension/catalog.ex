defmodule BizKit.Extension.Catalog do
  @moduledoc """
  Pure, fail-closed manifest catalog and deterministic activation *plan*.

  The host explicitly supplies already trusted modules. This module neither
  discovers arbitrary code nor loads a plugin from an untrusted manifest.
  Planning does not start apps, grant permissions or admit business commands.
  """

  alias BizKit.Extension.Manifest

  @spec build([module()]) :: {:ok, [map()]} | {:error, term()}
  def build(modules) when is_list(modules) do
    with {:ok, index} <- index(modules),
         :ok <- verify_dependencies(index),
         {:ok, ids} <- sort_dependencies(index) do
      {:ok, Enum.map(ids, &Map.fetch!(index, &1))}
    end
  end

  def build(_), do: {:error, :invalid_modules}

  @spec activation_plan([map()], [String.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def activation_plan(catalog, approved_ids) when is_list(catalog) and is_list(approved_ids) do
    index = Map.new(catalog, fn entry -> {entry.manifest.id, entry} end)
    approved = MapSet.new(approved_ids)

    cond do
      not Enum.all?(approved_ids, &is_binary/1) or
          length(approved_ids) != MapSet.size(approved) ->
        {:error, :invalid_approvals}

      Enum.any?(approved_ids, &(not Map.has_key?(index, &1))) ->
        {:error, :unknown_extension}

      true ->
        case Enum.find(catalog, fn entry ->
               MapSet.member?(approved, entry.manifest.id) and
                 Enum.any?(entry.manifest.dependencies, fn dep ->
                   not MapSet.member?(approved, dep.id)
                 end)
             end) do
          nil ->
            {:ok, Enum.filter(catalog, &MapSet.member?(approved, &1.manifest.id))}

          entry ->
            {:error, {:unapproved_dependency, entry.manifest.id}}
        end
    end
  end

  def activation_plan(_, _), do: {:error, :invalid_approvals}

  defp index(modules) do
    Enum.reduce_while(modules, {:ok, %{}}, fn module, {:ok, entries} ->
      with {:ok, manifest} <- load_manifest(module),
           false <- Map.has_key?(entries, manifest.id) do
        {:cont, {:ok, Map.put(entries, manifest.id, %{module: module, manifest: manifest})}}
      else
        true -> {:halt, {:error, :duplicate_extension}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_manifest(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :manifest, 0) do
      try do
        Manifest.validate(module.manifest())
      rescue
        _ -> {:error, {:manifest_callback_failed, module}}
      catch
        _, _ -> {:error, {:manifest_callback_failed, module}}
      end
    else
      {:error, {:not_an_extension, module}}
    end
  end

  defp load_manifest(module), do: {:error, {:not_an_extension, module}}

  defp verify_dependencies(index) do
    Enum.reduce_while(index, :ok, fn {id, entry}, :ok ->
      Enum.reduce_while(entry.manifest.dependencies, {:cont, :ok}, fn dep, _ ->
        case Map.fetch(index, dep.id) do
          :error ->
            {:halt, {:error, {:missing_dependency, id, dep.id}}}

          {:ok, actual} ->
            if Version.compare(actual.manifest.version, dep.min_version) in [:eq, :gt] do
              {:cont, :ok}
            else
              {:halt, {:error, {:outdated_dependency, id, dep.id}}}
            end
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sort_dependencies(index) do
    order(Map.keys(index) |> Enum.sort(), MapSet.new(), [], index)
  end

  defp order([], _done, reversed, _index), do: {:ok, Enum.reverse(reversed)}

  defp order(pending, done, reversed, index) do
    ready =
      Enum.find(pending, fn id ->
        Enum.all?(index[id].manifest.dependencies, &MapSet.member?(done, &1.id))
      end)

    if ready do
      order(List.delete(pending, ready), MapSet.put(done, ready), [ready | reversed], index)
    else
      {:error, :dependency_cycle}
    end
  end
end

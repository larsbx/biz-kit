alias BizKit.Extension.{Catalog, Registry}

# Explicit host allowlist: no module names from network or user manifests.
modules = [SchoolOps.Extension, Dispatch.Extension]

with {:ok, entries} <- Catalog.build(modules),
     {:ok, []} <- Catalog.activation_plan(entries, []),
     {:ok, registry} <- Registry.start_link(modules: modules) do
  [] = Registry.visible(registry)
  {:error, :not_visible} = Registry.lookup(registry, "dispatch")
  GenServer.stop(registry)
  ids = Enum.map_join(entries, ", ", & &1.manifest.id)

  case System.argv() do
    [] -> :ok
    [path] -> File.write!(path, Jason.encode!(Enum.map(entries, & &1.manifest)))
  end

  IO.puts("ExtensionV1 descriptors verified (activation disabled): " <> ids)
else
  error ->
    IO.inspect(error, label: "ExtensionV1 conformance failed")
    System.halt(1)
end

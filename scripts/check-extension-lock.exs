alias BizKit.Extension.{Registry, ReleaseLock}

# This check runs only after CI verifies a trusted exact-head checkout.
# A caller-supplied SHA by itself is never proof of source provenance.
source = System.fetch_env!("BIZKIT_SOURCE_COMMIT")
modules = [SchoolOps.Extension, Dispatch.Extension]
pins = %{"school_ops" => source, "dispatch" => source}

with {:ok, reviewed} <- ReleaseLock.build(modules, pins),
     {:ok, registry} <-
       Registry.start_link(
         modules: Enum.reverse(modules),
         reviewed_release: %{source_commits: pins, lock: reviewed}
       ),
     [] <- Registry.visible(registry),
     {:ok, ["dispatch", "school_ops"]} <-
       Registry.reconcile(registry, ["school_ops", "dispatch"]),
     :ok <- GenServer.stop(registry) do
  IO.puts("ExtensionV1 reviewed registry verified for Dispatch and SchoolOps")

  reviewed
  |> Enum.each(fn item ->
    IO.puts(item.id <> "@" <> item.source_commit <> " manifest sha256=" <> item.manifest_sha256)
  end)
else
  error ->
    IO.inspect(error, label: "ExtensionV1 release lock refused")
    System.halt(1)
end

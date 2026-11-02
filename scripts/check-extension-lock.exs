alias BizKit.Extension.ReleaseLock

# This check runs only after CI verifies a trusted exact-head checkout.
# A caller-supplied SHA by itself is never proof of source provenance.
source = System.fetch_env!("BIZKIT_SOURCE_COMMIT")
modules = [SchoolOps.Extension, Dispatch.Extension]
pins = %{"school_ops" => source, "dispatch" => source}

with {:ok, reviewed} <- ReleaseLock.build(modules, pins),
     {:ok, ^reviewed} <- ReleaseLock.verify(Enum.reverse(modules), pins, reviewed) do
  reviewed
  |> Enum.each(fn item ->
    IO.puts(item.id <> "@" <> item.source_commit <> " manifest sha256=" <> item.manifest_sha256)
  end)
else
  error ->
    IO.inspect(error, label: "ExtensionV1 release lock refused")
    System.halt(1)
end

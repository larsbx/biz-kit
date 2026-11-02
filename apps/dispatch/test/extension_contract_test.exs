defmodule Dispatch.ExtensionContractTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.{Catalog, Manifest}

  test "Dispatch descriptor cannot delegate or claim another domain's writer" do
    assert {:ok, descriptor} = Manifest.validate(Dispatch.Extension.manifest())
    assert descriptor.id == "dispatch"
    assert descriptor.commands == []
    assert descriptor.events == []
    assert descriptor.requested_grants == []
    assert {:ok, [%{module: Dispatch.Extension}]} = Catalog.build([Dispatch.Extension])
  end
end

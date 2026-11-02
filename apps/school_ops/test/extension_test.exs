defmodule SchoolOps.ExtensionTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.{Catalog, Manifest}

  test "SchoolOps is a validated but non-writing platform extension" do
    assert {:ok, descriptor} = Manifest.validate(SchoolOps.Extension.manifest())
    assert descriptor.id == "school_ops"
    assert descriptor.commands == []
    assert descriptor.events == []
    assert descriptor.requested_grants == []
    assert {:ok, [%{module: SchoolOps.Extension}]} = Catalog.build([SchoolOps.Extension])
  end
end

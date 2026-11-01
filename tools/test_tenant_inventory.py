"""Focused regression tests for the non-authoritative source inventory."""
import tempfile
import unittest
from pathlib import Path

from tenant_inventory import collect, inspect_source


class TenantInventoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.app = self.root / "apps" / "sample" / "lib"
        self.app.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, content):
        path = self.app / name
        path.write_text(content, encoding="utf-8")
        return inspect_source(path, self.root)

    def test_attribute_scoped_resource(self):
        row = self.write("tenant.ex", """
defmodule Sample.Tenant do
  use Ash.Resource, data_layer: AshPostgres.DataLayer
  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end
  attributes do
    attribute :tenant_id, :uuid
  end
end
""")
        self.assertEqual(row["kind"], "attribute_tenant_ash")
        self.assertTrue(row["has_tenant_attribute"])

    def test_unscoped_resource_requires_manual_review(self):
        row = self.write("global.ex", """
defmodule Sample.Global do
  use Ash.Resource, data_layer: AshPostgres.DataLayer
  policies do
    bypass always() do
      authorize_if always()
    end
  end
end
""")
        self.assertEqual(row["kind"], "unscoped_ash_review")
        self.assertEqual(row["observations"]["policy_bypass_always"], [5])

    def test_ecto_schema_and_repository_escape_are_visible(self):
        row = self.write("direct.ex", """
defmodule Sample.Direct do
  use Ecto.Schema
  schema "direct" do
    field :tenant_id, :binary_id
  end
  def list(), do: Sample.Repo.all(Sample.Direct)
  def read(), do: Ash.read!(Sample.Resource, authorize?: false)
end
""")
        self.assertEqual(row["kind"], "ecto_schema_review")
        self.assertEqual(row["observations"]["raw_repo_calls"], [7])
        self.assertEqual(row["observations"]["ash_authorization_bypass"], [8])

    def test_output_is_deterministically_path_sorted(self):
        self.write("z.ex", "defmodule Z do\n  use Ash.Resource\nend\n")
        self.write("a.ex", "defmodule A do\n  use Ash.Resource\nend\n")
        self.assertEqual(
            [row["path"] for row in collect(self.root)],
            ["apps/sample/lib/a.ex", "apps/sample/lib/z.ex"],
        )

    def test_no_source_fails_instead_of_claiming_empty_inventory(self):
        with self.assertRaises(ValueError):
            collect(self.root)


if __name__ == "__main__":
    unittest.main()

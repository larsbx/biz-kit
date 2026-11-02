defmodule BizKit.Extension.ReleaseLockTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.ReleaseLock

  defmodule School do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      %{
        id: "school",
        contract_version: 1,
        version: "0.1.0",
        dependencies: [],
        capabilities: ["school.course.read", "school.lesson.preview"],
        requested_grants: [],
        commands: [],
        events: [],
        projections: [],
        migrations: [],
        deployment: :integrated,
        activation: :manual,
        health: :host
      }
    end
  end

  defmodule ChangedSchool do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      BizKit.Extension.ReleaseLockTest.School.manifest()
      |> Map.update!(:capabilities, fn capabilities ->
        ["school.lesson.private" | capabilities]
      end)
    end
  end

  defmodule Dependent do
    @behaviour BizKit.Extension

    @impl true
    def manifest do
      BizKit.Extension.ReleaseLockTest.School.manifest()
      |> Map.merge(%{
        id: "dependent",
        dependencies: [%{id: "school", min_version: "0.1.0"}],
        capabilities: []
      })
    end
  end

  @school_source String.duplicate("a", 40)
  @dependent_source String.duplicate("b", 40)
  @pins %{"school" => @school_source, "dependent" => @dependent_source}

  test "deterministic source-locked catalog in dependency order" do
    assert {:ok, lock} = ReleaseLock.build([Dependent, School], @pins)
    assert Enum.map(lock, & &1.id) == ["school", "dependent"]
    assert {:ok, ^lock} = ReleaseLock.build([School, Dependent], @pins)
    assert {:ok, ^lock} = ReleaseLock.verify([Dependent, School], @pins, lock)

    assert Enum.all?(lock, fn item ->
             String.length(item.manifest_sha256) == 64 and
               String.match?(item.manifest_sha256, ~r/\A[0-9a-f]{64}\z/)
           end)
  end

  test "canonical manifest digest is independent of normalized top-level ordering" do
    school = School.manifest()
    assert {:ok, expected} = ReleaseLock.fingerprint(school)
    assert expected ==
             "602de6d20b186c21a3ebe76523935e5ffdfcf378d142db3cbe5cbeb53adf539f"

    assert {:ok, ^expected} =
             ReleaseLock.fingerprint(%{
               school
               | capabilities: Enum.reverse(school.capabilities)
             })
  end

  test "same-version manifest changes are refused, even if the source pin is reused" do
    assert {:ok, reviewed} = ReleaseLock.build([School], %{"school" => @school_source})

    assert {:error, :unreviewed_or_stale_release_lock} =
             ReleaseLock.verify([ChangedSchool], %{"school" => @school_source}, reviewed)

    assert {:ok, updated} =
             ReleaseLock.build([ChangedSchool], %{"school" => @school_source})

    refute updated == reviewed
  end

  test "source commit drift is refused even for an identical manifest" do
    assert {:ok, reviewed} = ReleaseLock.build([School], %{"school" => @school_source})

    assert {:error, :unreviewed_or_stale_release_lock} =
             ReleaseLock.verify(
               [School],
               %{"school" => String.duplicate("c", 40)},
               reviewed
             )
  end

  test "missing, extra, malformed and abbreviated source pins fail closed" do
    assert {:error, :source_pin_coverage_mismatch} =
             ReleaseLock.build([School, Dependent], %{"school" => @school_source})

    assert {:error, :source_pin_coverage_mismatch} =
             ReleaseLock.build([School], @pins)

    for sha <- ["main", "deadbeef", String.duplicate("A", 40), "x" <> @school_source] do
      assert {:error, :invalid_source_commit} =
               ReleaseLock.build([School], %{"school" => sha})
    end

    assert {:error, :invalid_source_commits} = ReleaseLock.build([School], [])
    assert {:error, :invalid_release_lock} = ReleaseLock.verify([School], @pins, %{})
  end

  test "untrusted modules, bad dependencies and broken manifests are rejected" do
    assert {:error, {:not_an_extension, "Remote.Module"}} =
             ReleaseLock.build(["Remote.Module"], %{})

    assert {:error, {:missing_dependency, "dependent", "school"}} =
             ReleaseLock.build([Dependent], %{"dependent" => @dependent_source})

    assert {:error, :duplicate_extension} =
             ReleaseLock.build([School, School], %{"school" => @school_source})

    assert {:error, {:invalid_field, :capabilities}} =
             ReleaseLock.fingerprint(%{
               School.manifest()
               | capabilities: ["school.course.read", "school.course.read"]
             })
  end
end

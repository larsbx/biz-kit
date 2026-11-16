defmodule ScfHost.CommandsTest do
  use ExUnit.Case, async: true

  alias ScfHost.Commands

  @sha String.duplicate("ab", 32)
  @book %{postings: %{7 => %{source: %{digest: <<9::256>>}}}, reversed: MapSet.new()}

  defp entry(lines, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "entry",
        "command_id" => "c-1",
        "journal" => "AC",
        "date" => "2026-03-05",
        "label" => "Achat fournitures",
        "piece" => "FA-001",
        "document_sha256" => @sha,
        "lines" => lines
      },
      extra
    )
  end

  test "form lines (indexed map, typed amounts, blank rows) become signed DZD lines" do
    lines = %{
      "1" => %{"account" => "4456", "debit" => "57,00", "credit" => ""},
      "0" => %{"account" => "60", "debit" => "300", "credit" => ""},
      "2" => %{"account" => "401", "debit" => "", "credit" => "357,00"},
      "3" => %{"account" => "", "debit" => "", "credit" => ""}
    }

    assert {:ok, "ScfJournalEntryPostedV1", "c-1", attrs} = Commands.build(entry(lines), @book)
    assert attrs["currency"] == "DZD"

    assert attrs["document"] == %{
             "id" => "FA-001",
             "sha256" => {:bytes, Base.decode16!(@sha, case: :lower)}
           }

    assert attrs["lines"] == [
             %{"side" => "debit", "account" => "60", "amount_minor" => 300_00},
             %{"side" => "debit", "account" => "4456", "amount_minor" => 57_00},
             %{"side" => "credit", "account" => "401", "amount_minor" => 357_00}
           ]
  end

  test "JSON lines carry exact centimes" do
    lines = [
      %{"side" => "debit", "account" => "512", "amount_minor" => 5},
      %{"side" => "credit", "account" => "101", "amount_minor" => 5}
    ]

    assert {:ok, _, _, %{"lines" => ^lines}} = Commands.build(entry(lines), @book)
  end

  test "an upload is not a digest: the host stores the bytes first, then cites them" do
    upload = %Plug.Upload{path: "/nonexistent", filename: "facture.pdf"}

    assert {:error, :invalid_document} =
             Commands.build(entry([], %{"document_sha256" => "", "document" => upload}), @book)
  end

  test "malformed input is refused before anything is signed" do
    ok = [%{"account" => "512", "debit" => "1", "credit" => ""}]

    for {params, error} <- [
          {entry(ok, %{"document_sha256" => "xyz"}), :invalid_document},
          {entry(ok, %{"piece" => " "}), :invalid_document},
          {entry([%{"account" => "512", "debit" => "1", "credit" => "1"}]), :invalid_line},
          {entry([%{"account" => "512", "debit" => "1,234", "credit" => ""}]), :invalid_line},
          {entry(ok, %{"command_id" => "bad id"}), :invalid_command_id},
          {%{"kind" => "transfer"}, :unknown_command}
        ],
        do: assert(Commands.build(params, @book) == {:error, error})
  end

  test "a reversal cites the target's digest from the book, never from the client" do
    params = %{
      "kind" => "reversal",
      "command_id" => "r-1",
      "target" => "7",
      "date" => "2026-03-06",
      "piece" => "AV-1",
      "document_sha256" => @sha,
      "target_digest" => "forged"
    }

    assert {:ok, "ScfEntryReversedV1", "r-1", attrs} = Commands.build(params, @book)
    assert attrs["target"] == %{"sequence" => 7, "digest" => {:bytes, <<9::256>>}}
    refute Map.has_key?(attrs, "target_digest")

    assert {:error, :unknown_entry} = Commands.build(%{params | "target" => "8"}, @book)
  end

  test "a clôture names its date and its procès-verbal" do
    params = %{
      "kind" => "close",
      "command_id" => "k-1",
      "through" => "2026-12-31",
      "piece" => "PV-AG",
      "document_sha256" => @sha
    }

    assert {:ok, "ScfFiscalYearClosedV1", "k-1",
            %{"through" => "2026-12-31", "document" => %{"id" => "PV-AG"}}} =
             Commands.build(params, @book)
  end
end

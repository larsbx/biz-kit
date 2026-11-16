defmodule ScfHost.Commands do
  @moduledoc """
  One parser for HTML forms and JSON: request params → `{type, command_id,
  attrs}` for `CoopSubstrate.Scf.post/4`. Pure; nothing here signs.

  * Amounts are typed DZD (`ScfCore.Money.parse/1`) or exact `amount_minor`.
  * The pièce justificative is an id plus the hex SHA-256 of bytes already
    held locally (`ScfHost.Pieces`); the Log refuses it otherwise.
  * A reversal names a log position; its digest comes from the signed book,
    never from the client.

  Admission (`ScfCore.SignedProjection` inside the Log) remains the only
  authority on accounting validity; this module rejects malformed input early.
  """
  alias ScfCore.Money

  @types %{
    "entry" => "ScfJournalEntryPostedV1",
    "reversal" => "ScfEntryReversedV1",
    "close" => "ScfFiscalYearClosedV1"
  }

  @spec build(map, map) :: {:ok, String.t(), String.t(), map} | {:error, atom}
  def build(%{"kind" => kind} = p, book) when is_map_key(@types, kind) do
    with {:ok, id} <- command_id(p["command_id"]),
         {:ok, document} <- document(p),
         {:ok, attrs} <- attrs(kind, p, book) do
      {:ok, @types[kind], id, Map.put(attrs, "document", document)}
    end
  end

  def build(_, _), do: {:error, :unknown_command}

  defp attrs("entry", p, _book) do
    with {:ok, lines} <- lines(p["lines"]) do
      {:ok,
       %{
         "journal" => text(p["journal"]),
         "label" => text(p["label"]),
         "date" => text(p["date"]),
         "currency" => "DZD",
         "lines" => lines
       }}
    end
  end

  defp attrs("reversal", p, book) do
    with {seq, ""} <- Integer.parse(to_string(p["target"])),
         %{source: %{digest: digest}} <- book.postings[seq] do
      {:ok,
       %{
         "target" => %{"sequence" => seq, "digest" => {:bytes, digest}},
         "date" => text(p["date"]),
         "currency" => "DZD"
       }}
    else
      _ -> {:error, :unknown_entry}
    end
  end

  defp attrs("close", p, _book), do: {:ok, %{"through" => text(p["through"])}}

  # Form rows arrive as %{"0" => row, ...}; JSON as a list.
  defp lines(rows) when is_map(rows),
    do:
      rows
      |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end, &<=/2)
      |> Enum.map(&elem(&1, 1))
      |> lines()

  defp lines(rows) when is_list(rows) do
    rows
    |> Enum.reject(&blank?/1)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case line(row) do
        {:ok, l} -> {:cont, {:ok, [l | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp lines(_), do: {:error, :invalid_line}

  defp line(%{"side" => side, "account" => a, "amount_minor" => m} = row)
       when side in ["debit", "credit"] and is_binary(a) and is_integer(m) and map_size(row) == 3,
       do: {:ok, row}

  defp line(%{"account" => a} = row) when is_binary(a) do
    case {present(row["debit"]), present(row["credit"])} do
      {d, nil} when d != nil -> typed("debit", a, d)
      {nil, c} when c != nil -> typed("credit", a, c)
      _ -> {:error, :invalid_line}
    end
  end

  defp line(_), do: {:error, :invalid_line}

  defp typed(side, account, amount) do
    case Money.parse(amount) do
      {:ok, m} -> {:ok, %{"side" => side, "account" => String.trim(account), "amount_minor" => m}}
      _ -> {:error, :invalid_line}
    end
  end

  defp blank?(%{} = row) when not is_map_key(row, "side"),
    do: Enum.all?(~w(account debit credit), &(present(row[&1]) == nil))

  defp blank?(_), do: false

  defp document(p) do
    with id when id != nil <- present(p["piece"]),
         {:ok, digest} <- digest(p) do
      {:ok, %{"id" => id, "sha256" => {:bytes, digest}}}
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp digest(%{"document_sha256" => hex}) when is_binary(hex) and byte_size(hex) == 64,
    do: Base.decode16(hex, case: :mixed)

  defp digest(_), do: :error

  defp command_id(id) when is_binary(id) do
    if id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/,
      do: {:ok, id},
      else: {:error, :invalid_command_id}
  end

  defp command_id(_), do: {:error, :invalid_command_id}

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp present(_), do: nil
  defp text(v) when is_binary(v), do: String.trim(v)
  defp text(_), do: ""
end

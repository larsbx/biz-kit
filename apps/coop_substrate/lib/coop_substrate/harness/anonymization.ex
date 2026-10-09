defmodule CoopSubstrate.Harness.Anonymization do
  @moduledoc """
  The fixture anonymization predicate (Phase 2D; corpus 11 §1.5, P2):
  mechanical where it can be — regex classes for MC/DOT numbers, emails,
  phone numbers — and explicit where it can't: a per-set **denylist** of
  literal strings (names, companies, lanes) supplied by the operator,
  because name detection is judgment. The denylist is an input only; it
  never enters any artifact or event.

  Non-UTF-8 content is `:unscannable` and fails closed — v0 fixtures are
  text (parser fixtures are extractions). Document quirks are the standing
  adversarial case (11 §5); this predicate is a floor, not a proof.
  """

  @patterns [
    mc_number: ~r/\bMC[-\s#]?\d{4,}\b/i,
    dot_number: ~r/\b(?:US)?DOT[-\s#]?\d{4,}\b/i,
    email: ~r/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i,
    phone: ~r/\b\d{3}[-.\s]\d{3}[-.\s]\d{4}\b/
  ]

  @doc "All violations in `text`: `{class, match}` per regex hit, `{:denylist, term}` per literal hit, or `[{:unscannable, :not_text}]`."
  @spec violations(binary(), [String.t()]) :: [{atom(), term()}]
  def violations(text, denylist \\ [])

  def violations(text, denylist) when is_binary(text) do
    if String.valid?(text) do
      regex_hits =
        for {class, pattern} <- @patterns,
            match <- Regex.scan(pattern, text) |> List.flatten() |> Enum.uniq(),
            do: {class, match}

      downcased = String.downcase(text)

      denylist_hits =
        for term <- denylist,
            term != "" and String.contains?(downcased, String.downcase(term)),
            do: {:denylist, term}

      regex_hits ++ denylist_hits
    else
      [{:unscannable, :not_text}]
    end
  end

  @doc "Does `text` pass the predicate?"
  @spec anonymized?(binary(), [String.t()]) :: boolean()
  def anonymized?(text, denylist \\ []), do: violations(text, denylist) == []
end

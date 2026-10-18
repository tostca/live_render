defmodule LiveRender.OpenUI.Collation do
  @moduledoc """
  String comparison approximating ECMAScript `localeCompare` with no arguments, which uses the
  ICU root collation (language.md, section 3.4, `@Sort`).

  Three levels, as in the Unicode Collation Algorithm:

    1. primary: character class (whitespace, punctuation, symbols, digits, letters, other), then
       the base letter with accents removed and case folded, so `a < B < é < Z`
    2. secondary: accents, unaccented first, so `e < é`
    3. tertiary: case, lowercase first, so `b < B`

  This is not a full UCA implementation. It covers Latin text and the fixture cases; scripts with
  contractions or reordering may sort differently from ICU.
  """

  @doc "Returns -1, 0 or 1."
  @spec compare(String.t(), String.t()) :: -1 | 0 | 1
  def compare(a, b) when a == b, do: 0

  def compare(a, b) do
    ka = key(a)
    kb = key(b)

    cond do
      ka < kb -> -1
      ka > kb -> 1
      a < b -> -1
      true -> 1
    end
  end

  defp key(s) do
    chars = s |> :unicode.characters_to_nfd_binary() |> safe_codepoints()

    {primary, secondary, tertiary} =
      Enum.reduce(chars, {[], [], []}, fn cp, {p, s2, t} ->
        if combining?(cp) do
          # An accent attaches to the previous base character.
          {p, [cp | s2], t}
        else
          lower = fold(cp)
          {[{class(cp), lower} | p], [0 | s2], [case_weight(cp, lower) | t]}
        end
      end)

    {Enum.reverse(primary), Enum.reverse(secondary), Enum.reverse(tertiary)}
  end

  defp safe_codepoints(bin) when is_binary(bin), do: String.to_charlist(bin)
  defp safe_codepoints(_), do: []

  defp combining?(cp), do: cp in 0x0300..0x036F or cp in 0x1AB0..0x1AFF or cp in 0x20D0..0x20FF

  defp fold(cp) do
    case String.downcase(<<cp::utf8>>) do
      <<lower::utf8>> -> lower
      _ -> cp
    end
  end

  defp case_weight(cp, lower), do: if(cp == lower, do: 0, else: 1)

  # Whitespace < punctuation < symbols < digits < letters < everything else, as in the root order.
  defp class(cp) do
    s = <<cp::utf8>>

    cond do
      String.match?(s, ~r/\A\s\z/u) -> 0
      String.match?(s, ~r/\A\p{P}\z/u) -> 1
      String.match?(s, ~r/\A\p{S}\z/u) -> 2
      String.match?(s, ~r/\A\p{N}\z/u) -> 3
      String.match?(s, ~r/\A\p{L}\z/u) -> 4
      true -> 5
    end
  end
end

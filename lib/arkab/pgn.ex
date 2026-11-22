defmodule Arkab.Pgn do
  @moduledoc """
  Reads one game out of PGN text: its tag pairs, its moves and the clock
  after each. Copied from Alnasl (`Alnasl.PgnReader`, same author, itself
  from OpenResults) and cut to one game per text, which is what a LiveChess
  export holds per file. It does not check that a move is legal:
  `Arkab.Chess.play/2` does. See NOTICE.

  Understands the tag pairs, move numbers, `{brace}` and `;line` comments,
  `(variations)`, numeric annotation glyphs and the result token. A
  `[%clk h:mm:ss]` command inside a comment is kept: the clock after the
  move it follows.

  ## A file still being written

  A game in PGN ends with its result token, `*` while it is being played.
  A text that does not end with one was read while it was being written
  (or was cut short), and is `{:error, :partial}`: what is in it may well
  be legal and still wrong - `O-O` is the first three characters of
  `O-O-O`. The reader tries again on the next reading.
  """

  @type game :: %{
          headers: %{String.t() => String.t()},
          moves: [String.t()],
          clocks: [non_neg_integer() | nil],
          result: String.t()
        }

  @results ["1-0", "0-1", "1/2-1/2", "*"]

  @doc "The first game in `text`: `{:ok, game}`, or `{:error, :partial}` (see above)."
  @spec read(String.t()) :: {:ok, game()} | {:error, :partial}
  def read(text) when is_binary(text) do
    chunk =
      text
      |> String.replace("\r\n", "\n")
      |> String.replace(~r/\A\xEF\xBB\xBF/, "")
      |> String.split(~r/\n\s*\n(?=\[)/)
      |> List.first("")

    if String.starts_with?(String.trim_leading(chunk), "["),
      do: game(chunk),
      else: {:error, :partial}
  end

  defp game(chunk) do
    lines = String.split(chunk, "\n")

    {tag_lines, rest} =
      Enum.split_while(lines, &(String.trim(&1) == "" or String.starts_with?(&1, "[")))

    headers =
      for line <- tag_lines,
          [_, name, value] <- [Regex.run(~r/^\s*\[(\w+)\s+"(.*)"\]\s*$/, line)],
          into: %{},
          do: {name, value}

    case movetext(Enum.join(rest, "\n")) do
      {:ok, moves, clocks, result} ->
        {:ok, %{headers: headers, moves: moves, clocks: clocks, result: result}}

      :partial ->
        {:error, :partial}
    end
  end

  @token ~r/\{[^}]*\}|;[^\n]*|\(|\)|[^\s(){};]+/

  defp movetext(text) do
    tokens = @token |> Regex.scan(text) |> List.flatten()

    # The last token at the top level must be the result; an unclosed
    # comment or variation is a file cut short too.
    {depth, acc, result, last} = Enum.reduce(tokens, {0, [], nil, nil}, &token/2)

    if depth == 0 and last == :result and not unclosed_comment?(text) do
      acc = Enum.reverse(acc)
      {:ok, Enum.map(acc, &elem(&1, 0)), Enum.map(acc, &elem(&1, 1)), result}
    else
      :partial
    end
  end

  defp unclosed_comment?(text) do
    opens = text |> String.graphemes() |> Enum.count(&(&1 == "{"))
    closes = text |> String.graphemes() |> Enum.count(&(&1 == "}"))
    opens != closes
  end

  # `{depth, [{san, clock_ms}] newest first, result, what the last top-level token was}`
  defp token("(", {depth, acc, result, _last}), do: {depth + 1, acc, result, :other}
  defp token(")", {depth, acc, result, _last}), do: {max(depth - 1, 0), acc, result, :other}
  defp token(_ignored, {depth, acc, result, last}) when depth > 0, do: {depth, acc, result, last}
  defp token("$" <> _glyph, state), do: state
  defp token(";" <> _comment, state), do: state

  defp token(word, {depth, acc, _result, _last}) when word in @results,
    do: {depth, acc, word, :result}

  defp token("{" <> comment, {depth, [{san, nil} | rest], result, last}) do
    case Regex.run(~r/\[%clk\s+(\d+):(\d+):(\d+)/, comment) do
      [_, h, m, s] ->
        ms =
          ((String.to_integer(h) * 60 + String.to_integer(m)) * 60 + String.to_integer(s)) * 1000

        {depth, [{san, ms} | rest], result, last}

      _no_clock ->
        {depth, [{san, nil} | rest], result, last}
    end
  end

  defp token("{" <> _comment, state), do: state

  # A move, possibly glued to its number ("1.e4"), or a number on its own.
  defp token(word, {depth, acc, result, _last}) do
    case word |> String.replace(~r/^\d+\.+/, "") |> String.replace(~r/[!?]+$/, "") do
      "" -> {depth, acc, result, :other}
      move -> {depth, [{move, nil} | acc], result, :other}
    end
  end
end

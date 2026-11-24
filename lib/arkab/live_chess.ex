defmodule Arkab.LiveChess do
  @moduledoc """
  The folder DGT LiveChess exports a tournament to ("filesystem
  exporter"), read as boards. Pure functions over the files; the process
  that reads them once a second is `Arkab.Driver.LiveChess`, one per game,
  and `Arkab.LiveChess.Folder` says which games there are.

  ## The folder

  The layout LiveChessCloud uses, written to disk:

      tournament.json            name, rounds, boards
      round-1/index.json         the pairings of round 1
      round-1/game-1.pgn         game 1 of round 1, as PGN, rewritten as it goes
      round-1/game-2.pgn
      round-2/...

  The folder given may hold `tournament.json` itself or have one
  subfolder per tournament; the newest `tournament.json` there or one
  level down is the tournament (`tournament_dir/1`). A folder with
  `round-N` folders and no `tournament.json` at all is read the same.

  The round being played is the one whose game files were written last
  (`current/1`): not simply the highest, because the next round's games
  may be written the moment it is paired, before anybody sits down. The
  moves come from the PGN files only; `index.json` and `tournament.json`
  add who is playing (`facts/2`).

  ## Who is playing

  `facts/2` is what the files say about a game besides its moves: the
  players (name, FIDE ID, title, rating, federation) from the PGN's tags,
  filled in from the round's `index.json` where a tag is missing, the
  LiveChess round and game number, the tournament's name, the result,
  and a forfeit when the index says one. The bridge sends it as
  `{:game, facts}`; Alnasl puts the board on the pairing it belongs to.

  ## A game

  `parse_game/1` plays the PGN's moves (`Arkab.Pgn`, `Arkab.Chess`) and
  gives every position from the first to the last, each with the clocks
  as `[%clk]` had them after that move. A file read while LiveChess was
  writing it is `{:error, :partial}`, a game that cannot be played
  `{:error, {:illegal, ply, why}}`; neither ever becomes a position.

  A file with no game in it yet is `{:error, :no_game}`: empty, tag pairs
  and nothing after them, or no moves on a set-up position that is no
  position (no kings: the e-board as it stands, before anybody set the
  pieces up). LiveChess writes those for a board it has no game on yet.
  """

  alias Arkab.{Board, Chess, Pgn}

  @type ply :: %{
          board: Board.t(),
          turn: :w | :b,
          white_ms: integer() | nil,
          black_ms: integer() | nil
        }
  @type game :: %{
          plies: [ply()],
          result: String.t(),
          start: :standard | Board.t(),
          headers: %{String.t() => String.t()}
        }

  # --- the folder ------------------------------------------------------------------

  @doc """
  Where the tournament is: the folder of the newest `tournament.json` in
  `folder` or one level down, `folder` itself when it has `round-N`
  folders and no `tournament.json`, `nil` otherwise.
  """
  @spec tournament_dir(String.t()) :: String.t() | nil
  def tournament_dir(folder) do
    candidates =
      [folder | Enum.map(subdirs(folder), &Path.join(folder, &1))]
      |> Enum.flat_map(fn dir ->
        case mtime(Path.join(dir, "tournament.json")) do
          nil -> []
          t -> [{t, dir}]
        end
      end)

    case candidates do
      [] -> if rounds(folder) != [], do: folder
      _some -> candidates |> Enum.max_by(&elem(&1, 0)) |> elem(1)
    end
  end

  @doc "The `round-N` folders of a tournament folder: `[{n, path}]`, lowest first."
  @spec rounds(String.t()) :: [{pos_integer(), String.t()}]
  def rounds(dir) do
    for name <- subdirs(dir),
        [_, n] <- [Regex.run(~r/^round-(\d+)$/, name)],
        do: {String.to_integer(n), Path.join(dir, name)}
  end

  @doc "The game files of a round folder: `%{game_number => path}`."
  @spec games(String.t()) :: %{pos_integer() => String.t()}
  def games(round_dir) do
    for name <- ls(round_dir),
        [_, m] <- [Regex.run(~r/^game-(\d+)\.pgn$/i, name)],
        into: %{},
        do: {String.to_integer(m), Path.join(round_dir, name)}
  end

  @doc """
  The round being played: `{:ok, %{dir, round, games}}` with `games` as
  `games/1` gives them, or `:none` when the folder has no game file yet.
  The round of the game file written last; of two written in the same
  second, the higher.
  """
  @spec current(String.t()) ::
          {:ok, %{dir: String.t(), round: pos_integer(), games: map()}} | :none
  def current(folder) when is_binary(folder) do
    with dir when is_binary(dir) <- tournament_dir(folder),
         [_ | _] = played <- played_rounds(dir) do
      {_newest, round, games} = Enum.max_by(played, fn {t, n, _games} -> {t, n} end)
      {:ok, %{dir: dir, round: round, games: games}}
    else
      _nothing -> :none
    end
  end

  defp played_rounds(dir) do
    for {n, path} <- rounds(dir),
        games = games(path),
        games != %{},
        newest = games |> Map.values() |> Enum.map(&(mtime(&1) || 0)) |> Enum.max(),
        do: {newest, n, games}
  end

  @doc "The file of game `m` of the round being played, or `nil`."
  @spec game_path(String.t(), pos_integer()) :: String.t() | nil
  def game_path(folder, m) do
    case current(folder) do
      {:ok, %{games: games}} -> Map.get(games, m)
      :none -> nil
    end
  end

  defp subdirs(dir), do: Enum.filter(ls(dir), &File.dir?(Path.join(dir, &1)))

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _reason} -> []
    end
  end

  @doc "A file's modification time in seconds, or `nil` when it is not there."
  def mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: t}} -> t
      _other -> nil
    end
  end

  # --- a game ----------------------------------------------------------------------

  @doc """
  Plays one game file's text. `{:ok, game}`: `plies` is every position,
  the first one before any move, each with the side to move and the
  clocks after it; `start` is `:standard` or the board the game was set
  up on. `{:error, :partial | :no_game | {:illegal, ply, why}}` (see the
  moduledoc). The file is read by its driver (`Arkab.Driver.LiveChess`),
  which compares texts.
  """
  @spec parse_game(String.t()) :: {:ok, game()} | {:error, term()}
  def parse_game(text) do
    case Pgn.read(text) do
      {:ok, pgn} -> play_game(pgn)
      {:error, :partial} -> if tags_only?(text), do: {:error, :no_game}, else: {:error, :partial}
    end
  end

  @doc "A game that is no game yet: the starting position, nobody's moves."
  @spec no_game() :: game()
  def no_game do
    {:ok, game} = parse_game(~s([Result "*"]\n\n*\n))
    game
  end

  # Nothing but tag pairs (or nothing at all): no movetext, not even `*`.
  # Half a file looks the same; the driver tells the two apart by whether
  # it had a game from that file already.
  defp tags_only?(text) do
    text
    |> String.replace(~r/\A\xEF\xBB\xBF/, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.all?(&(&1 == "" or String.starts_with?(&1, "[")))
  end

  defp play_game(%{moves: moves} = pgn) do
    fen = start_fen(pgn.headers)

    case fen_position(fen) do
      {:error, _why} when moves == [] -> {:error, :no_game}
      other -> play_game(pgn, fen, other)
    end
  end

  defp play_game(pgn, fen, first) do
    with {:ok, first} <- first,
         {:ok, positions} <- play(fen, pgn.moves) do
      {white0, black0} = initial_clocks(pgn.headers)

      {plies, _clocks} =
        Enum.map_reduce(Enum.zip([first | positions], [nil | pgn.clocks]), {white0, black0}, fn
          {pos, clk}, {white, black} ->
            # The clock after a move is the mover's: the side not to move now.
            {white, black} =
              cond do
                clk == nil -> {white, black}
                pos.turn == :b -> {clk, black}
                true -> {white, clk}
              end

            {%{board: pos.board, turn: pos.turn, white_ms: white, black_ms: black},
             {white, black}}
        end)

      start = if fen == Chess.start_fen(), do: :standard, else: first.board
      {:ok, %{plies: plies, result: pgn.result, start: start, headers: pgn.headers}}
    end
  end

  defp start_fen(headers) do
    case headers["FEN"] do
      fen when is_binary(fen) and fen != "" -> fen
      _none -> Chess.start_fen()
    end
  end

  defp fen_position(fen) do
    case Chess.parse_fen(fen) do
      {:ok, pos} -> {:ok, pos}
      {:error, why} -> {:error, {:illegal, 0, why}}
    end
  end

  defp play(fen, moves) do
    case Chess.play(fen, moves) do
      {:ok, positions} -> {:ok, positions}
      {:error, {ply, why}} -> {:error, {:illegal, ply, why}}
      {:error, why} -> {:error, {:illegal, 0, why}}
    end
  end

  # The clocks before a side has moved: its WhiteClock/BlackClock tag,
  # else the time control's first period (PGN's TimeControl is seconds).
  defp initial_clocks(headers) do
    base = time_control(headers["TimeControl"])
    {clock_tag(headers["WhiteClock"]) || base, clock_tag(headers["BlackClock"]) || base}
  end

  defp clock_tag(text) when is_binary(text) do
    case Regex.run(~r/^\s*(\d+):(\d{1,2}):(\d{1,2})/, text) do
      [_, h, m, s] ->
        ((String.to_integer(h) * 60 + String.to_integer(m)) * 60 + String.to_integer(s)) * 1000

      nil ->
        nil
    end
  end

  defp clock_tag(_none), do: nil

  defp time_control(text) when is_binary(text) do
    case Regex.run(~r/^\s*(?:\d+\/)?(\d+)(?:\+\d+)?(?::|\s*$)/, text) do
      [_, seconds] -> String.to_integer(seconds) * 1000
      nil -> nil
    end
  end

  defp time_control(_none), do: nil

  @doc "Is the game decided (a result other than `*`)?"
  def decided?(%{result: result}), do: result != "*"

  @doc """
  The clock reading after ply `i` (0 = before any move), or `nil` when a
  side's time is not known. `running` is the side to move while the game
  goes on and a move has been made; `:none` before the first move and
  once it is decided after the last. `elapsed_ms` is taken off the running
  side: how long it has been thinking.
  """
  @spec clock(game(), non_neg_integer(), non_neg_integer()) :: map() | nil
  def clock(game, i, elapsed_ms \\ 0) do
    ply = Enum.at(game.plies, i)
    last? = i == length(game.plies) - 1

    running =
      cond do
        i == 0 -> :none
        last? and decided?(game) -> :none
        ply.turn == :w -> :white
        true -> :black
      end

    if is_integer(ply.white_ms) and is_integer(ply.black_ms) do
      reading = %{white_ms: ply.white_ms, black_ms: ply.black_ms, running: running}

      case running do
        :white -> %{reading | white_ms: max(ply.white_ms - elapsed_ms, 0)}
        :black -> %{reading | black_ms: max(ply.black_ms - elapsed_ms, 0)}
        :none -> reading
      end
    end
  end

  @doc """
  The game as a board's memory (`{:history, events}`, see `Arkab.Driver`):
  the starting position, or the set-up position square by square after a
  power-up, then every move as the squares it changed and the mover's
  clock, as a DGT board writes it down. Alnasl holds it against the game
  it has (`Alnasl.BoardHistory`): what carries the game on is added, what
  does not is a draft for the arbiter.
  """
  @spec history(game()) :: list()
  def history(%{plies: [first | rest], start: start}) do
    opening =
      case start do
        :standard ->
          [:start_position]

        board ->
          [:power_up | for(i <- 0..63, piece = elem(board, i), do: {:field, i, piece})]
      end

    {moves, _before} =
      Enum.flat_map_reduce(rest, first, fn ply, before ->
        {changes(before.board, ply.board) ++ press(before, ply), ply}
      end)

    opening ++ moves
  end

  # Squares emptied first, then the squares filled: the hand lifts before
  # it puts down.
  defp changes(before, now) do
    squares = Board.diff(before, now)
    {emptied, filled} = Enum.split_with(squares, &(elem(now, &1) == nil))
    for i <- emptied ++ filled, do: {:field, i, elem(now, i)}
  end

  defp press(%{turn: :w}, %{white_ms: ms}) when is_integer(ms), do: [{:clock, :white, ms}]
  defp press(%{turn: :b}, %{black_ms: ms}) when is_integer(ms), do: [{:clock, :black, ms}]
  defp press(_before, _ply), do: []

  # --- who is playing ----------------------------------------------------------------

  @type player :: %{
          optional(:name) => String.t(),
          optional(:fide_id) => pos_integer(),
          optional(:title) => String.t(),
          optional(:rating) => pos_integer(),
          optional(:federation) => String.t()
        }

  @doc """
  What the files say about game `game` (as `parse_game/1` gave it) of
  the file at `path`, besides its moves:

      %{source: "livechess", tournament: "Open of Nowhere", round: 3, game: 5,
        white: player, black: player, result: "*", forfeit: "white"}

  A player has what is known of `:name`, `:fide_id`, `:title`, `:rating`
  and `:federation`, the PGN's tags first (`White`, `WhiteFideId`,
  `WhiteTitle`, `WhiteElo`), the round's `index.json` for what the tags
  leave out; the index's name is "Last, First" as LiveChess keeps them.
  `round` and `game` are the numbers of the folder and the file;
  `tournament` the name in `tournament.json`; `result` the PGN's. A
  `forfeit` (the side that forfeited, or `"both"`) only when the index
  says so. Keys with nothing known are left out.
  """
  @spec facts(String.t(), game()) :: map()
  def facts(path, game) do
    round_dir = Path.dirname(path)
    round = number(~r/^round-(\d+)$/, Path.basename(round_dir))
    m = number(~r/^game-(\d+)\.pgn$/i, Path.basename(path))
    pairing = pairing(round_dir, m)
    headers = Map.get(game, :headers, %{})

    %{
      source: "livechess",
      tournament: tournament_name(Path.dirname(round_dir)),
      round: round,
      game: m,
      white: player(headers, "White", pairing["white"]),
      black: player(headers, "Black", pairing["black"]),
      result: game.result,
      forfeit: forfeit(pairing["result"])
    }
    |> compact()
  end

  defp number(regex, name) do
    case Regex.run(regex, name) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  # Game m of a round is pairing m of its index.
  defp pairing(round_dir, m) when is_integer(m) do
    with %{"pairings" => [_ | _] = pairings} <- json(Path.join(round_dir, "index.json")),
         %{} = pairing <- Enum.at(pairings, m - 1) do
      pairing
    else
      _none -> %{}
    end
  end

  defp pairing(_round_dir, _m), do: %{}

  defp tournament_name(dir) do
    case json(Path.join(dir, "tournament.json")) do
      %{"name" => name} -> text(name)
      _none -> nil
    end
  end

  # Small files only: a tournament's index is a few kilobytes.
  # sobelow_skip ["Traversal.FileModule"]
  defp json(path) do
    with {:ok, %{size: size}} when size <= 1_000_000 <- File.stat(path),
         {:ok, text} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(text) do
      map
    else
      _none -> nil
    end
  end

  defp player(headers, side, listed) do
    listed = if is_map(listed), do: listed, else: %{}

    %{
      name: name(headers[side]) || listed_name(listed),
      fide_id: id(headers[side <> "FideId"]) || id(listed["fideid"]),
      title: title(headers[side <> "Title"]) || title(listed["title"]),
      rating: id(headers[side <> "Elo"]),
      federation: title(listed["federation"])
    }
    |> compact()
  end

  # "?" and "NN" are PGN for nobody.
  defp name(value) do
    case text(value) do
      name when name in [nil, "?", "NN", "-"] -> nil
      name -> name
    end
  end

  defp listed_name(listed) do
    first = [listed["fname"], listed["mname"]] |> Enum.map(&text/1) |> Enum.reject(&is_nil/1)
    last = text(listed["lname"])

    case {last, Enum.join(first, " ")} do
      {nil, ""} -> nil
      {nil, first} -> first
      {last, ""} -> last
      {last, first} -> last <> ", " <> first
    end
  end

  defp title(value) do
    case text(value) do
      title when title in [nil, "-", "?"] -> nil
      title -> title
    end
  end

  defp id(n) when is_integer(n) and n > 0, do: n

  defp id(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp id(_other), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(_other), do: nil

  # LiveChess writes a forfeit in the index, not in the PGN.
  defp forfeit(result) when is_binary(result) do
    case String.upcase(result) do
      "WHITEFORFAIT" -> "white"
      "BLACKFORFAIT" -> "black"
      "DOUBLEFORFAIT" -> "both"
      _other -> nil
    end
  end

  defp forfeit(_other), do: nil

  defp compact(map), do: for({k, v} <- map, v != nil and v != %{}, into: %{}, do: {k, v})
end

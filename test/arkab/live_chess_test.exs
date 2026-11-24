defmodule Arkab.LiveChessTest do
  @moduledoc """
  The LiveChess export folder read as games: where the tournament is,
  which round is being played, a PGN read whole or not at all, the clocks
  after each move, and the game as a board's memory.
  """

  use ExUnit.Case, async: true

  alias Arkab.{Board, LiveChess, LiveChessFolder, Pgn}

  setup do
    root = Path.join(System.tmp_dir!(), "arkab-lc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @game [{"e4", "1:29:50"}, {"e5", "1:29:40"}, {"Nf3", "1:29:10"}, {"Nc6", "1:28:00"}]

  describe "Arkab.Pgn" do
    test "reads the tags, the moves and the clock after each" do
      text = LiveChessFolder.pgn(@game)
      assert {:ok, game} = Pgn.read(text)
      assert game.moves == ~w(e4 e5 Nf3 Nc6)
      assert game.clocks == [5_390_000, 5_380_000, 5_350_000, 5_280_000]
      assert game.result == "*"
      assert game.headers["White"] == "Vermeulen, Wanda"
    end

    test "a text with no result token at the end is partial" do
      text = LiveChessFolder.pgn(@game)
      assert {:error, :partial} = Pgn.read(String.replace(text, " *\n", ""))
      # O-O is the first three characters of O-O-O.
      assert {:error, :partial} = Pgn.read(~s([Event "x"]\n\n1. e4 e5 2. O))
      assert {:error, :partial} = Pgn.read(~s([Event "x"]\n\n1. e4 {[%clk 1:29:50] *))
      assert {:error, :partial} = Pgn.read(~s([Event "x"]\n[Wh))
      assert {:error, :partial} = Pgn.read("")
      assert {:ok, %{moves: []}} = Pgn.read(~s([Event "x"]\n\n*\n))
      assert {:ok, %{result: "1-0"}} = Pgn.read(String.replace(text, " *\n", " 1-0\r\n"))
    end

    test "variations and comments are passed over" do
      text = "[Event \"x\"]

1. e4 (1. d4 d5) e5 {a comment} 2. Nf3 $1 ; a line
*
"
      assert {:ok, %{moves: ~w(e4 e5 Nf3)}} = Pgn.read(text)
    end
  end

  describe "the folder" do
    test "the tournament at the root, or the newest one a level down", %{root: root} do
      assert LiveChess.tournament_dir(root) == nil

      old = LiveChessFolder.new(root, subfolder: "Club championship")
      new = LiveChessFolder.new(root, subfolder: "Rapid")
      LiveChessFolder.touch(Path.join(old, "tournament.json"), -3600)
      assert LiveChess.tournament_dir(root) == new

      at_root = LiveChessFolder.new(root)
      assert LiveChess.tournament_dir(root) == at_root
    end

    test "round folders without a tournament.json are read too", %{root: root} do
      LiveChessFolder.round(root, 1, [{1, LiveChessFolder.pgn([])}])
      assert LiveChess.tournament_dir(root) == root
      assert {:ok, %{round: 1, games: %{1 => _}}} = LiveChess.current(root)
    end

    test "the round being played is the one written last, not the highest", %{root: root} do
      dir = LiveChessFolder.new(root)
      assert LiveChess.current(root) == :none

      LiveChessFolder.round(dir, 1, [
        {1, LiveChessFolder.pgn(@game)},
        {2, LiveChessFolder.pgn([])}
      ])

      LiveChessFolder.round(dir, 2, [{1, LiveChessFolder.pgn([])}])
      # Round 2 is paired; round 1 is still being played.
      for m <- [1, 2], do: LiveChessFolder.touch(Path.join([dir, "round-1", "game-#{m}.pgn"]), 10)
      LiveChessFolder.touch(Path.join([dir, "round-2", "game-1.pgn"]), -60)

      assert {:ok, %{round: 1, games: games}} = LiveChess.current(root)
      assert Map.keys(games) == [1, 2]
      assert LiveChess.game_path(root, 2) == Path.join([dir, "round-1", "game-2.pgn"])
      assert LiveChess.game_path(root, 3) == nil

      LiveChessFolder.touch(Path.join([dir, "round-2", "game-1.pgn"]), 20)
      assert {:ok, %{round: 2, games: %{1 => _}}} = LiveChess.current(root)
    end

    test "other files in a round folder are not games", %{root: root} do
      dir = LiveChessFolder.new(root)
      round = LiveChessFolder.round(dir, 1, [{3, LiveChessFolder.pgn([])}])
      File.write!(Path.join(round, "games.pgn"), "")
      File.write!(Path.join(round, "game-4.json"), "{}")
      assert {:ok, %{games: games}} = LiveChess.current(root)
      assert Map.keys(games) == [3]
    end
  end

  describe "a game" do
    test "every position from the start, with the clocks after each move" do
      assert {:ok, game} = LiveChess.parse_game(LiveChessFolder.pgn(@game))
      assert length(game.plies) == 5
      assert game.start == :standard
      assert hd(game.plies).board == Board.start()

      assert Enum.map(game.plies, &{&1.turn, &1.white_ms, &1.black_ms}) == [
               {:w, 5_400_000, 5_400_000},
               {:b, 5_390_000, 5_400_000},
               {:w, 5_390_000, 5_380_000},
               {:b, 5_350_000, 5_380_000},
               {:w, 5_350_000, 5_280_000}
             ]
    end

    test "a move that cannot be played is said, with its number" do
      text = LiveChessFolder.pgn(["e4", "e5", "Ke3"])
      assert {:error, {:illegal, 3, _why}} = LiveChess.parse_game(text)
      assert {:error, :partial} = LiveChess.parse_game("[Event \"x\"]\n\n1. e4 e")
    end

    test "a file with no game in it yet is no game, not an empty board" do
      assert {:error, :no_game} = LiveChess.parse_game("")
      assert {:error, :no_game} = LiveChess.parse_game("\xEF\xBB\xBF\r\n  \r\n")

      assert {:error, :no_game} =
               LiveChess.parse_game("[Event \"x\"]\r\n[White \"Vermeulen, Wanda\"]\r\n")

      # The e-board as it stands, nobody's pieces on it.
      empty = ~s([Event "x"]\n[SetUp "1"]\n[FEN "8/8/8/8/8/8/8/8 w - - 0 1"]\n\n*\n)
      assert {:error, :no_game} = LiveChess.parse_game(empty)

      # Moves on a position that is none are still a broken game.
      broken = ~s([SetUp "1"]\n[FEN "8/8/8/8/8/8/8/8 w - - 0 1"]\n\n1. e4 *\n)
      assert {:error, {:illegal, 0, _why}} = LiveChess.parse_game(broken)

      assert %{plies: [%{board: board}], result: "*", start: :standard} = LiveChess.no_game()
      assert board == Board.start()
    end

    test "the clock: who runs, and the running side's time counting down" do
      {:ok, game} = LiveChess.parse_game(LiveChessFolder.pgn(@game))

      assert LiveChess.clock(game, 0) == %{
               white_ms: 5_400_000,
               black_ms: 5_400_000,
               running: :none
             }

      assert LiveChess.clock(game, 1) == %{
               white_ms: 5_390_000,
               black_ms: 5_400_000,
               running: :black
             }

      assert LiveChess.clock(game, 4, 61_000) == %{
               white_ms: 5_350_000 - 61_000,
               black_ms: 5_280_000,
               running: :white
             }

      {:ok, decided} = LiveChess.parse_game(LiveChessFolder.pgn(@game, "1/2-1/2"))
      assert LiveChess.clock(decided, 4, 61_000).running == :none
      assert LiveChess.clock(decided, 3).running == :black
    end

    test "no clock anywhere: no reading" do
      text =
        LiveChessFolder.pgn(~w(e4 e5), "*", %{
          "WhiteClock" => "",
          "BlackClock" => "",
          "TimeControl" => "-"
        })

      {:ok, game} = LiveChess.parse_game(text)
      assert LiveChess.clock(game, 2) == nil
    end

    test "the game as a board's memory: the start, the squares of each move, the presses" do
      {:ok, game} =
        LiveChess.parse_game(
          LiveChessFolder.pgn([
            {"e4", "1:29:50"},
            {"e5", "1:29:40"},
            {"Nf3", "1:29:10"},
            {"Nc6", "1:28:00"},
            {"Bc4", "1:28:30"},
            {"Nf6", "1:27:00"},
            {"O-O", "1:28:00"}
          ])
        )

      history = LiveChess.history(game)
      assert hd(history) == :start_position

      # e4: e2 emptied, then e4 filled, then White's lever.
      assert Enum.slice(history, 1, 3) == [
               {:field, 52, nil},
               {:field, 36, {:w, :p}},
               {:clock, :white, 5_390_000}
             ]

      # Castling: the king's and the rook's squares emptied before filled.
      castle = history |> Enum.reverse() |> Enum.take(5) |> Enum.reverse()

      assert castle == [
               {:field, 60, nil},
               {:field, 63, nil},
               {:field, 61, {:w, :r}},
               {:field, 62, {:w, :k}},
               {:clock, :white, 5_280_000}
             ]

      # Played back, the memory ends where the game does.
      board =
        Enum.reduce(history, nil, fn
          :start_position, _ -> Board.start()
          {:field, i, piece}, board -> put_elem(board, i, piece)
          _clock, board -> board
        end)

      assert board == List.last(game.plies).board
    end

    test "a game set up from a FEN is remembered as a power-up and its pieces" do
      fen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"

      {:ok, game} =
        LiveChess.parse_game(LiveChessFolder.pgn(["e4"], "*", %{"FEN" => fen, "SetUp" => "1"}))

      assert [:power_up | rest] = LiveChess.history(game)
      assert {:field, 4, {:b, :k}} in rest
      assert {:field, 36, {:w, :p}} in rest
    end
  end
end

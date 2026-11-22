defmodule Arkab.ChessTest do
  @moduledoc """
  Arkab's copy of the move checker, proved as Alnasl's is: perft against
  the published counts (castling, en passant, promotions, pins), then the
  SAN reading and the playing of a game that the LiveChess source uses.
  """

  use ExUnit.Case, async: true

  alias Arkab.{Board, Chess}

  defp position!(fen) do
    {:ok, position} = Chess.parse_fen(fen)
    position
  end

  # From the Chess Programming Wiki's perft results; shallow, to stay quick.
  @perft [
    {"the starting position", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
     [20, 400]},
    {"Kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
     [48, 2039]},
    {"position 3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812]},
    {"position 4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264]},
    {"position 5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486]}
  ]

  for {name, fen, counts} <- @perft do
    test "perft: #{name}" do
      position = position!(unquote(fen))

      for {expected, depth} <- Enum.with_index(unquote(counts), 1) do
        assert Chess.perft(position, depth) == expected, "depth #{depth}"
      end
    end
  end

  test "FEN round-trips, and the counters may be left off" do
    for {_name, fen, _counts} <- @perft, do: assert(fen |> position!() |> Chess.to_fen() == fen)
    assert {:ok, %{halfmove: 0, fullmove: 1}} = Chess.parse_fen("8/8/8/4k3/8/8/4K3/8 w - -")
    assert {:error, _} = Chess.parse_fen("8/8/8/8/8/8/8/8 w - - 0 1")
  end

  test "the board of a position is an Arkab.Board" do
    assert Chess.start().board == Board.start()
  end

  test "SAN is read leniently and strictly at once" do
    start = Chess.start()
    assert {:ok, %{from: 52, to: 36, kind: :double}} = Chess.parse_san(start, "e4")
    assert {:ok, %{to: 45}} = Chess.parse_san(start, "Nf3+")
    assert {:error, _} = Chess.parse_san(start, "e5")
    assert {:error, _} = Chess.parse_san(start, "Nd2")
    assert {:error, _} = Chess.parse_san(start, "N")

    castle = position!("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    assert {:ok, %{kind: :castle_k}} = Chess.parse_san(castle, "O-O")
    assert {:ok, %{kind: :castle_q}} = Chess.parse_san(castle, "0-0-0")

    promo = position!("8/P7/8/8/8/8/8/k6K w - - 0 1")
    assert {:ok, %{promo: :q}} = Chess.parse_san(promo, "a8=Q")
    assert {:ok, %{promo: :n}} = Chess.parse_san(promo, "a8N")
    assert {:error, _} = Chess.parse_san(promo, "a8")
  end

  test "play/2 gives the position after each move, or the first move that is not legal" do
    assert {:ok, [p1, p2, p3]} = Chess.play(Chess.start_fen(), ~w(e4 e5 Nf3))
    assert p1.turn == :b and p3.turn == :b

    assert Board.to_text(p2.board) ==
             "rnbqkbnrpppp.ppp............p.......P...........PPPP.PPPRNBQKBNR"

    assert Board.to_text(p3.board) ==
             "rnbqkbnrpppp.ppp............p.......P........N..PPPP.PPPRNBQKB.R"

    assert {:error, {3, _why}} = Chess.play(Chess.start_fen(), ~w(e4 e5 Ke3))
    assert {:ok, []} = Chess.play(Chess.start_fen(), [])
  end
end

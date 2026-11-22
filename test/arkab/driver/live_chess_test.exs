defmodule Arkab.Driver.LiveChessTest do
  @moduledoc """
  One game of a LiveChess folder as a board: what it says when it is met,
  moves added to the file one position at a time, a file caught half
  written, a move LiveChess took back, a game that cannot be played, the
  next round's game on the same board, and the file gone.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arkab.{Board, Chess, LiveChessFolder}
  alias Arkab.Driver.LiveChess

  setup do
    root = Path.join(System.tmp_dir!(), "arkab-lcd-#{System.unique_integer([:positive])}")
    dir = LiveChessFolder.new(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, dir: dir}
  end

  defp start(root, extra \\ []) do
    opts =
      [
        owner: self(),
        id: "LiveChess#1",
        options: %{"folder" => root, "game" => 1, "step_ms" => 20},
        tick_ms: 50
      ] ++ extra

    start_supervised!({LiveChess, opts})
  end

  defp board_after(sans) do
    {:ok, positions} = Chess.play(Chess.start_fen(), sans)
    List.last(positions).board
  end

  # Driver events up to and including the first that matches, skipping polls and clocks.
  defp next_event(timeout \\ 2_000) do
    receive do
      {:driver, _id, {:poll, :ok}} -> next_event(timeout)
      {:driver, _id, {:clock, _}} -> next_event(timeout)
      {:driver, _id, event} -> event
    after
      timeout -> flunk("no event")
    end
  end

  defp next_clock(timeout \\ 2_000) do
    receive do
      {:driver, _id, {:clock, reading}} -> reading
    after
      timeout -> flunk("no clock")
    end
  end

  @four [{"e4", "1:29:50"}, {"e5", "1:29:40"}, {"Nf3", "1:29:10"}, {"Nc6", "1:28:00"}]

  test "met mid-game: connected, the game as its memory, then where it stands", %{
    root: root,
    dir: dir
  } do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(@four)}])
    start(root)

    assert next_event() == :connected
    assert {:history, [:start_position | _] = history} = next_event()
    assert {:clock, :black, 5_280_000} in history
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3 Nc6))}

    # White to move, counting down from its last [%clk].
    assert %{running: :white, black_ms: 5_280_000, white_ms: white} = next_clock()
    assert white <= 5_350_000
  end

  test "moves added to the file come one position at a time, each with its press", %{
    root: root,
    dir: dir
  } do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(Enum.take(@four, 1))}])
    start(root)
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert {:position, _} = next_event()

    LiveChessFolder.write_game(dir, 1, 1, LiveChessFolder.pgn(@four))
    flush_until_position()

    assert_receive {:driver, _, {:clock, %{running: :white, white_ms: 5_390_000}}}, 2_000
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3))}
    assert next_clock().running == :black
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3 Nc6))}
    assert %{running: :white, black_ms: 5_280_000} = next_clock()
  end

  # The first position after a change in the file, e5 here.
  defp flush_until_position do
    receive do
      {:driver, _, {:position, board}} ->
        assert board == board_after(~w(e4 e5))

      {:driver, _, _other} ->
        flush_until_position()
    after
      2_000 -> flunk("no position")
    end
  end

  test "a file caught half written is read again, never half played", %{root: root, dir: dir} do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(Enum.take(@four, 2))}])
    start(root)
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert {:position, _} = next_event()

    # O-O-O on its way: "5. O-O" with no result after it would be the wrong castle.
    full = LiveChessFolder.pgn(@four)
    LiveChessFolder.write_game(dir, 1, 1, String.replace(full, " *\n", ""))
    refute_position(300)

    LiveChessFolder.write_game(dir, 1, 1, full)
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3))}
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3 Nc6))}
  end

  defp refute_position(ms),
    do: refute_until(System.monotonic_time(:millisecond) + ms)

  defp refute_until(deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:driver, _, {:position, _}} -> flunk("a position that should not be")
      {:driver, _, _other} -> refute_until(deadline)
    after
      left -> :ok
    end
  end

  test "a move LiveChess took back: the position where both agree, then the new move", %{
    root: root,
    dir: dir
  } do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(@four)}])
    start(root)
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert {:position, _} = next_event()

    corrected = Enum.take(@four, 3) ++ [{"Nf6", "1:28:00"}]
    LiveChessFolder.write_game(dir, 1, 1, LiveChessFolder.pgn(corrected))

    assert next_event() == {:position, board_after(~w(e4 e5 Nf3))}
    assert next_event() == {:position, board_after(~w(e4 e5 Nf3 Nf6))}
  end

  test "a game that cannot be played is said once; the board keeps what it had", %{
    root: root,
    dir: dir
  } do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(Enum.take(@four, 2))}])
    start(root)
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert {:position, _} = next_event()

    log =
      capture_log(fn ->
        LiveChessFolder.write_game(dir, 1, 1, LiveChessFolder.pgn(["e4", "e5", "Ke3"]))
        refute_position(400)
      end)

    assert log =~ "move 3"
    assert length(String.split(log, "cannot be read")) == 2
  end

  test "the next round's game on the same board starts from its first position", %{
    root: root,
    dir: dir
  } do
    LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn(@four, "1-0")}])
    start(root)
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert {:position, _} = next_event()

    LiveChessFolder.round(dir, 2, [{1, LiveChessFolder.pgn([{"d4", "1:29:55"}])}])
    LiveChessFolder.touch(Path.join([dir, "round-2", "game-1.pgn"]), 5)

    assert next_event() == {:position, Board.start()}
    assert next_event() == {:position, board_after(~w(d4))}
  end

  test "the file gone is a board gone; back, it is met again", %{root: root, dir: dir} do
    path =
      LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn([])}]) |> Path.join("game-1.pgn")

    start(root)
    assert next_event() == :connected
    assert {:history, [:start_position]} = next_event()
    assert next_event() == {:position, Board.start()}

    File.rm!(path)
    assert next_event() == :disconnected

    File.write!(path, LiveChessFolder.pgn(Enum.take(@four, 1)))
    assert next_event() == :connected
    assert {:history, _} = next_event()
    assert next_event() == {:position, board_after(~w(e4))}
  end

  test "the bridge's own lookup replaces the scan", %{dir: dir} do
    path =
      LiveChessFolder.round(dir, 1, [{1, LiveChessFolder.pgn([])}]) |> Path.join("game-1.pgn")

    start("/nowhere", locate: fn -> path end)
    assert next_event() == :connected
  end
end

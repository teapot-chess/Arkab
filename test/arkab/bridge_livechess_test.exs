defmodule Arkab.BridgeLiveChessTest do
  @moduledoc """
  A LiveChess export folder as a source of the bridge: a board per game of
  the round being played, more or fewer as the rounds change, kept after a
  restart, added by `add_folder` (owner only, and only a folder that is
  there), and the game's memory sent again with the rest of the board.
  """

  use ExUnit.Case, async: false

  alias Arkab.{Bridge, LiveChessFolder}
  alias Arkab.Bridge.{Board, Ports, Store}

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-bridge-lc-#{System.unique_integer([:positive])}")
    folder = Path.join(dir, "export")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, folder: folder, tournament: LiveChessFolder.new(folder)}
  end

  defp start_bridge(dir, sources) do
    start_supervised!({Bridge, data_dir: Path.join(dir, "data"), name: "hall", sources: sources},
      id: Bridge
    )
  end

  defp eventually(fun, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(fun, deadline)
  end

  defp wait(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline, do: flunk("it did not happen in time")
      Process.sleep(50)
      wait(fun, deadline)
    end
  end

  @game LiveChessFolder.pgn([{"e4", "1:29:50"}, {"c5", "1:29:40"}])

  test "a board per game of the round; the next round's boards replace them", %{
    dir: dir,
    folder: folder,
    tournament: t
  } do
    LiveChessFolder.round(t, 1, [{1, @game}, {2, @game}, {3, @game}])
    start_bridge(dir, [%{"folder" => folder, "name" => "LiveChess"}])

    eventually(fn -> Board.ids() == ~w(LiveChess#1 LiveChess#2 LiveChess#3) end)

    status = Ports.status()

    assert %{port: "LiveChess", description: ^folder, read?: true} =
             Enum.find(status.ports, &(&1.port == "LiveChess"))

    eventually(fn ->
      Enum.all?(Ports.status().boards, &(&1.connected? and &1.port == "LiveChess"))
    end)

    # Round 2 has two boards and is the one being written.
    LiveChessFolder.round(t, 2, [{1, @game}, {2, @game}])
    for m <- [1, 2], do: LiveChessFolder.touch(Path.join([t, "round-2", "game-#{m}.pgn"]), 5)

    eventually(fn -> Board.ids() == ~w(LiveChess#1 LiveChess#2) end)
  end

  test "add_folder: owner only, a folder that is there, named LiveChess", %{
    dir: dir,
    folder: folder,
    tournament: t
  } do
    LiveChessFolder.round(t, 1, [{4, @game}])
    start_bridge(dir, [])

    assert {:error, :not_owner} =
             Ports.command(%{"cmd" => "add_folder", "folder" => folder}, false)

    assert {:error, :no_such_folder} = Ports.add_folder(Path.join(dir, "nowhere"))
    assert :ok = Ports.add_folder(folder)
    # The same folder twice is one source.
    assert :ok = Ports.add_folder(folder <> " ")

    assert [%{"folder" => ^folder, "name" => "LiveChess"}] = Store.get("ports")
    eventually(fn -> Board.ids() == ~w(LiveChess#4) end)

    other = Path.join(dir, "second")
    File.mkdir_p!(other)
    assert :ok = Ports.add_folder(other)
    assert [_, %{"name" => "LiveChess 2"}] = Store.get("ports")

    # Forgotten like a port.
    assert :ok = Ports.command(%{"cmd" => "forget_port", "port" => "LiveChess"}, true)
    eventually(fn -> Board.ids() == [] end)
    assert [%{"name" => "LiveChess 2"}] = Store.get("ports")
  end

  test "the game's memory is sent again with the rest of the board", %{tournament: t} do
    path = LiveChessFolder.round(t, 1, [{1, @game}]) |> Path.join("game-1.pgn")

    start_supervised!({Registry, keys: :unique, name: Arkab.Bridge.BoardRegistry})

    # The queue is this test: what the board appends arrives here.
    board =
      start_supervised!(
        {Board,
         id: "LiveChess#1",
         port: "LiveChess",
         address: 1,
         driver: Arkab.Driver.LiveChess,
         resend_history: true,
         store: self(),
         ports: self(),
         driver_opts: [options: %{"step_ms" => 20}, locate: fn -> path end, tick_ms: 60_000]}
      )

    assert_receive {:"$gen_cast", {:append, {"LiveChess#1", _t, nil, %{"k" => "hist"}}}}, 3_000
    eventually(fn -> Board.status(board).position? end)
    flush()

    assert :ok = GenServer.call(board, :resend)
    kinds = drain([])
    # A clock tick of the driver may come first; the resend is in order.
    assert ["st", "hist" | _] = Enum.drop_while(kinds, &(&1 != "st"))
    assert "pos" in kinds and "clk" in kinds
  end

  defp flush do
    receive do
      _any -> flush()
    after
      0 -> :ok
    end
  end

  # What the resend appended, in order (polls and clock ticks of the driver left out).
  defp drain(acc) do
    receive do
      {:"$gen_cast", {:append, {_id, _t, _at, %{"k" => k}}}} when k != "poll" -> drain([k | acc])
      {:"$gen_cast", _other} -> drain(acc)
    after
      200 -> acc |> Enum.reverse() |> Enum.dedup()
    end
  end
end

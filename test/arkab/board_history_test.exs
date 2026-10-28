defmodule Arkab.BoardHistoryTest do
  @moduledoc """
  A board's memory read back: the two real ones of 2026-10-12, byte for
  byte, and made-up ones that are cut, wrapped and garbled. What the reader
  must never do is crash, or pass on as an event what the board did not
  write.
  """

  use ExUnit.Case, async: true

  alias Arkab.{Board, Protocol}
  alias Arkab.Dgt.{Bus, Emulator}
  alias Arkab.Dgt.Protocol, as: Single

  @captures Path.expand("../fixtures/captures", __DIR__)

  defp answers(file) do
    bytes =
      @captures
      |> Path.join(file)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.flat_map(fn
        %{"k" => "rx", "h" => hex} -> [Base.decode16!(hex, case: :lower)]
        _other -> []
      end)
      |> IO.iodata_to_binary()

    {answers, _rest} = Bus.parse(bytes)
    answers
  end

  defp memory(address) do
    [data] =
      for {^address, {:from_start, data}} <- answers("real-loop-06-ignore-ping-all-d.jsonl"),
          do: data

    data
  end

  defp dump(address) do
    [board] =
      for {^address, {:board, board}} <- answers("real-loop-02-version-board-clock.jsonl"),
          do: board

    board
  end

  # The board as its memory leaves it: every square written down, from an
  # empty board, and the starting position wherever the board says it stood.
  defp replay(events) do
    Enum.reduce(events, Board.empty(), fn
      {:field, square, piece}, board -> put_elem(board, square, piece)
      :start_position, _board -> Board.start()
      _other, board -> board
    end)
  end

  describe "the real memories (2026-10-12)" do
    test "both came back whole: 1461 and 1313 bytes, every byte below 0x80" do
      assert byte_size(memory(6310)) == 1461
      assert byte_size(memory(12_799)) == 1313

      for address <- [6310, 12_799],
          do: assert(Enum.all?(:binary.bin_to_list(memory(address)), &(&1 < 0x80)))
    end

    test "replayed, each memory is the board that board showed" do
      for address <- [6310, 12_799] do
        events = Bus.history(memory(address))
        assert hd(events) == :start_mark
        assert Board.to_text(replay(events)) == Board.to_text(dump(address))
      end
    end

    test "they hold games: starting positions, clock times, a power-up" do
      old = Bus.history(memory(6310))
      new = Bus.history(memory(12_799))

      assert Enum.count(old, &(&1 == :start_position)) == 6
      assert Enum.count(old, &(&1 == :power_up)) == 2
      assert Enum.count(old, &match?({:clock, _, _}, &1)) == 102

      # The newer board's one game: a start, both clocks at 1:30:30, 1. e4.
      assert [
               :start_mark,
               :start_position,
               {:clock, :white, 5_430_000},
               {:clock, :black, 5_430_000},
               {:field, 52, nil},
               {:field, 36, {:w, :p}} | _
             ] = new

      assert Enum.count(new, &match?({:clock, _, _}, &1)) == 84
    end

    test "a memory asked for while a single-board command was answered is lost, not misread" do
      # 2026-10-12: a single-board question went out while 12799 sent its
      # memory. Everything that came back is damaged; nothing is an answer.
      answers = answers("real-loop-11-serial-behind-journal.jsonl")
      refute Enum.any?(answers, &match?({_address, {:from_start, _}}, &1))
      assert Enum.any?(answers, &match?({:bad_checksum, _}, &1))
    end
  end

  describe "made-up memories" do
    test "a power-up in the middle: the mark, then every piece found" do
      emu = Emulator.new(serial: "06310", bus?: true)
      {_, emu} = Emulator.set_board(emu, put_elem(put_elem(Board.start(), 52, nil), 36, {:w, :p}))
      emu = Emulator.power_up(emu)

      {[{6310, {:from_start, data}}], <<>>} =
        emu |> Emulator.handle(Bus.command(:from_start, 6310)) |> elem(0) |> Bus.parse()

      events = Bus.history(data)

      last =
        length(events) - 1 - (events |> Enum.reverse() |> Enum.find_index(&(&1 == :power_up)))

      {before, [:power_up | after_power]} = Enum.split(events, last)

      # What it found when it came on is what stood there when it went off.
      assert replay(before) == replay(after_power)
      assert Enum.count(after_power, &match?({:field, _, _}, &1)) == 32
    end

    test "a memory that wrapped: an event cut in half at the front is a few bytes of nothing" do
      data = memory(12_799)
      events = Bus.history(data)

      # Begin one byte into a clock time, at its minutes: BCD 0x30 is below
      # 0x40 and is skipped, and so are the seconds after it.
      {at, 3} = :binary.match(data, <<0x71, 0x30, 0x30>>)
      wrapped = binary_part(data, at + 1, byte_size(data) - at - 1)
      after_clock = events |> Enum.drop_while(&(&1 != {:clock, :white, 5_430_000})) |> tl()
      assert Bus.history(wrapped) == after_clock

      # Begin at the square of a field event: below 0x40 as well.
      {at, 2} = :binary.match(data, <<0x40, 0x34>>)
      from_square = binary_part(data, at + 1, byte_size(data) - at - 1)
      after_field = events |> Enum.drop_while(&(&1 != {:field, 52, nil})) |> tl()
      assert Bus.history(from_square) == after_field
    end

    test "cut off anywhere, a memory loses its last event at most" do
      data = memory(6310)
      whole = Bus.history(data)

      for cut <- 0..byte_size(data) do
        events = Bus.history(binary_part(data, 0, cut))
        assert events == Enum.take(whole, length(events))
        assert length(events) >= length(Bus.history(binary_part(data, 0, max(cut - 3, 0))))
      end
    end

    test "garbage never crashes the reader, and every event it gives is one a board can write" do
      :rand.seed(:exsss, {20, 26, 10})

      for _ <- 1..300 do
        bytes = for _ <- 1..:rand.uniform(400), into: <<>>, do: <<:rand.uniform(256) - 1>>

        for event <- Bus.history(bytes) do
          assert valid?(event), inspect(event)
        end

        # And through the line's own reader, in any pieces.
        assert {_answers, _rest} = Bus.parse(bytes)
        assert {_messages, _rest} = Single.parse(bytes)
      end
    end

    test "no more than max_history events, the newest kept" do
      data = :binary.copy(<<0x41, 0x10>>, Bus.max_history() + 5) <> <<0x6A>>
      events = Bus.history(data)
      assert length(events) == Bus.max_history()
      assert List.last(events) == :power_up
    end
  end

  defp valid?({:field, square, piece}),
    do: square in 0..63 and (piece == nil or match?({c, _} when c in [:w, :b], piece))

  defp valid?({:clock, side, ms}), do: side in [:white, :black] and is_integer(ms) and ms >= 0

  defp valid?(mark),
    do:
      mark in [
        :power_up,
        :start_position,
        :start_position_rotated,
        :start_mark,
        :restarted,
        :empty_board,
        :end_of_data
      ]

  describe "the single-board memory (ee_moves)" do
    test "is asked for with 0x49 and read as the bus's memory is" do
      assert Single.command(:ee_moves) == <<0x49>>
      emu = Emulator.new(serial: "06310")
      {reply, _emu} = Emulator.handle(emu, <<0x49>>)
      assert {[{:ee_moves, data}], <<>>} = Single.parse(reply)
      assert hd(Bus.history(data)) == :start_mark
      assert replay(Bus.history(data)) == Board.start()
    end

    test "a memory cut short on the line does not swallow the messages after it" do
      memory = :binary.copy(<<0x41, 0x10, 0x70, 0x30, 0x00>>, 100)
      whole = Single.encode({:ee_moves, memory})
      # Half of it, then a whole-board message.
      cut = binary_part(whole, 0, 200)
      dump = Single.encode({:board, Board.start()})

      assert {[{:ee_moves_cut, 197}, {:board, board}], <<>>} = Single.parse(cut <> dump)
      assert board == Board.start()

      # Whole, it is a memory.
      assert {[{:ee_moves, ^memory}], <<>>} = Single.parse(whole)
    end

    test "a memory still arriving is waited for" do
      whole = Single.encode({:ee_moves, :binary.copy(<<0x41, 0x10>>, 300)})
      part = binary_part(whole, 0, 400)
      assert {[], ^part} = Single.parse(part)
    end
  end

  describe "on the link" do
    test "a history goes over and comes back as it went" do
      events = Bus.history(memory(12_799)) ++ [:restarted, :end_of_data, :start_position_rotated]
      map = Protocol.encode_event(9, "COM5#12799", 1_791_817_998_006, {:history, events})

      {:ok, %{"events" => [wire]}} =
        Protocol.events([map]) |> Protocol.encode() |> Protocol.decode()

      assert {:ok, %{event: {:history, ^events}}} = Protocol.decode_event(wire)
    end

    test "one item that is not one, and the history is not taken at all" do
      good = %{"m" => "power_up"}

      for bad <- [
            %{"f" => 64, "p" => "P"},
            %{"f" => 3, "p" => "X"},
            %{"c" => "green", "ms" => 1},
            %{"c" => "white", "ms" => -1},
            %{"m" => "explode"},
            "power_up"
          ] do
        map = %{"s" => 1, "t" => 1, "id" => "COM3", "e" => %{"k" => "hist", "h" => [good, bad]}}
        assert Protocol.decode_event(map) == {:error, :bad_event}, inspect(bad)
      end
    end
  end
end

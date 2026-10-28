defmodule Arkab.BoardHistoryScheduleTest do
  @moduledoc """
  When a board's memory is asked for, and what the others are asked
  meanwhile. A memory is a second and a half of a loop's line: asked for one
  board at a time, with the ordinary questions to everybody in between, so
  that twelve boards coming back at once do not stop the moves on all
  twelve.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arkab.Board
  alias Arkab.Dgt.{Bus, Emulator}
  alias Arkab.Driver.{DgtBus, DgtSerial}
  alias Arkab.Transport.Fake

  defmodule NoMemory do
    @moduledoc "A loop whose first board's memory always arrives damaged."
    alias Arkab.Dgt.{Bus, Emulator}

    def handle([first | others] = emulators, bytes) do
      case Bus.decode_command(bytes) do
        {:from_start, address} when address == first.address ->
          {said, emulators} = Emulator.handle(emulators, bytes)
          size = byte_size(said) - 1
          <<body::binary-size(^size), last>> = said
          {body <> <<Bitwise.band(last + 1, 0x7F)>>, emulators}

        _other ->
          {said, others} = Emulator.handle(others, bytes)
          {mine, first} = Emulator.handle(first, bytes)
          {mine <> said, [first | others]}
      end
    end
  end

  defmodule Cut do
    @moduledoc "One board whose answers go through `fun` first."
    def handle({fun, emu}, bytes) do
      {reply, emu} = fun.(emu, bytes)
      {reply, {fun, emu}}
    end
  end

  @addresses [6310, 12_799, 4242]

  defp start_loop(device, name, opts \\ []) do
    port = "FAKE-HIST-#{name}"
    start_supervised!({Fake, port: port, device: device}, id: port)
    start_supervised!(Arkab.Drivers)

    {:ok, bus} =
      DgtBus.ensure(
        port,
        [transport: Fake, discover_ms: 60_000, reply_ms: 200, history_gap_ms: 150] ++ opts
      )

    for address <- @addresses, do: DgtBus.attach(bus, address, self(), address)
    {port, bus}
  end

  defp boards, do: Emulator.loop(@addresses)

  # The questions written to the line, in order: `[{name, address}]`.
  defp questions(port), do: commands(Fake.written(port))

  defp commands(<<id, hi, lo, sum, rest::binary>>) when id >= 0x80,
    do: [Bus.decode_command(<<id, hi, lo, sum>>) | commands(rest)]

  defp commands(<<_byte, rest::binary>>), do: commands(rest)
  defp commands(<<>>), do: []

  defp histories(acc \\ %{}, wanted, ms) do
    if map_size(acc) >= wanted do
      acc
    else
      receive do
        {:driver, address, {:history, events}} ->
          histories(Map.update(acc, address, [events], &(&1 ++ [events])), wanted, ms)
      after
        ms -> acc
      end
    end
  end

  defp replay(events) do
    Enum.reduce(events, Board.empty(), fn
      {:field, square, piece}, board -> put_elem(board, square, piece)
      _other, board -> board
    end)
  end

  test "every board's memory is read once it is met, one board at a time, and the polls go on" do
    {port, _bus} = start_loop({Emulator, boards()}, "THREE")

    got = histories(3, 6_000)
    assert Enum.sort(Map.keys(got)) == Enum.sort(@addresses)

    for {_address, [events]} <- got do
      assert hd(events) == :start_mark
      assert replay(events) == Board.start()
    end

    asked = questions(port)
    memories = for {{:from_start, address}, i} <- Enum.with_index(asked), do: {address, i}
    assert Enum.sort(for {address, _} <- memories, do: address) == Enum.sort(@addresses)

    # Between two memories, every board is asked what changed: nobody waits
    # for the others' memories to be read.
    for [{_, i}, {_, j}] <- Enum.chunk_every(memories, 2, 1, :discard) do
      between =
        asked |> Enum.slice((i + 1)..(j - 1)//1) |> Enum.filter(&match?({:changes, _}, &1))

      assert Enum.sort(Enum.uniq(for {:changes, a} <- between, do: a)) == Enum.sort(@addresses)
    end
  end

  test "a board that says it was switched off and on is read again; the others are not" do
    {port, _bus} = start_loop({Emulator, boards()}, "POWER")
    assert map_size(histories(3, 6_000)) == 3

    moved = put_elem(put_elem(Board.start(), 52, nil), 36, {:w, :p})

    Fake.update(port, fn emulators ->
      {<<>>,
       Enum.map(emulators, fn
         %{address: 6310} = emu ->
           emu |> Emulator.set_board(moved) |> elem(1) |> Emulator.power_up()

         emu ->
           emu
       end)}
    end)

    assert_receive {:driver, 6310, {:history, events}}, 4_000
    assert :power_up in events
    assert replay(events) == replay(Enum.drop_while(events, &(&1 != :power_up)))
    refute_receive {:driver, 12_799, {:history, _}}, 1_000
    refute_received {:driver, 4242, {:history, _}}

    asked = for {:from_start, address} <- questions(port), do: address
    assert Enum.frequencies(asked) == %{6310 => 2, 12_799 => 1, 4242 => 1}
  end

  test "a memory that never arrives whole is asked for twice, and the board goes on being read" do
    log =
      capture_log(fn ->
        {port, bus} = start_loop({NoMemory, boards()}, "DAMAGED")

        got = histories(2, 6_000)
        assert Enum.sort(Map.keys(got)) == [4242, 12_799]

        # Long enough for a third try, if there were one.
        Process.sleep(1_500)
        refute_received {:driver, 6310, {:history, _}}

        asked = for {:from_start, address} <- questions(port), do: address
        assert Enum.frequencies(asked)[6310] == 2

        stats = Map.new(DgtBus.stats(bus), &{&1.address, &1})
        assert stats[6310].connected?
        assert stats[6310].answered > 20
      end)

    assert log =~ "6310 did not send its memory in 2 tries"
  end

  describe "a board on its own line" do
    defp start_single(name, device) do
      port = "FAKE-HIST-SINGLE-#{name}"
      start_supervised!({Fake, port: port, device: device}, id: port)

      start_supervised!(
        {DgtSerial, owner: self(), id: name, port: port, transport: Fake, resync_ms: 150},
        id: name
      )

      port
    end

    test "is asked for its memory once, at the first resync, and is put back in update mode" do
      port = start_single("one", {Emulator, Emulator.new(serial: "06310")})

      assert_receive {:driver, "one", {:history, events}}, 3_000
      assert hd(events) == :start_mark
      assert replay(events) == Board.start()

      Process.sleep(600)
      written = Fake.written(port)
      assert length(:binary.matches(written, <<0x49>>)) == 1
      # After the question, update mode again.
      [{at, 1}] = :binary.matches(written, <<0x49>>)
      assert binary_part(written, at + 1, 1) == <<0x4B>>
    end

    test "a memory cut short on the line is let go of; the board goes on" do
      cut = fn
        emu, <<0x49>> ->
          {reply, emu} = Emulator.handle(emu, <<0x49>>)
          {binary_part(reply, 0, 20), emu}

        emu, bytes ->
          Emulator.handle(emu, bytes)
      end

      log =
        capture_log(fn ->
          port = start_single("cut", {Cut, {cut, Emulator.new(serial: "06310")}})
          assert_receive {:driver, "cut", :connected}, 3_000
          Process.sleep(800)
          refute_received {:driver, "cut", {:history, _}}
          refute_received {:driver, "cut", :disconnected}

          moved = put_elem(put_elem(Board.start(), 52, nil), 36, {:w, :p})

          Fake.update(port, fn {fun, emu} ->
            emu |> Emulator.set_board(moved) |> then(fn {bytes, emu} -> {bytes, {fun, emu}} end)
          end)

          assert_receive {:driver, "cut", {:position, ^moved}}, 2_000
        end)

      assert log =~ "memory was cut short"
    end
  end
end

defmodule Arkab.Transport.UartTest do
  use ExUnit.Case, async: true

  alias Arkab.Transport.Uart

  # A Mac ran out of processes after a day of retrying an unplugged adapter:
  # every failed open left its UART, and the UART's helper program, behind.
  test "a port that does not open leaves no UART behind" do
    if Uart.available?() do
      links = fn -> self() |> Process.info(:links) |> elem(1) |> MapSet.new() end
      before = links.()

      for _ <- 1..3,
          do: assert({:error, _} = Uart.open("/dev/arkab-no-such-port", baud: 9600))

      assert links.() == before
    end
  end

  defmodule Recorder do
    @moduledoc "Stands in for Circuits.UART: remembers which lines were asked for."
    def set_dtr(pid, on), do: send(pid, {:line, :dtr, on}) && :ok
    def set_rts(pid, on), do: send(pid, {:line, :rts, on}) && {:error, :enotty}
  end

  # RTS on and DTR off, as LiveChess ends up: neither leaves long answers cut
  # short on a Mac, and DTR on cuts an old wooden board short on a loop.
  test "an opened port gets RTS on and DTR off, and a refusal does not matter" do
    assert :ok = Uart.power_line(Recorder, self(), "/dev/cu.usbserial-test")
    assert_received {:line, :dtr, false}
    assert_received {:line, :rts, true}
  end
end

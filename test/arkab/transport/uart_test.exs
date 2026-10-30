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

  # A DGT RS-232 board powers its transmitter from DTR and RTS. A Mac that is
  # asked for neither gives long answers that stop after a few bytes.
  test "an opened port is asked for DTR and RTS, and a refusal does not matter" do
    assert :ok = Uart.power_line(Recorder, self(), "/dev/cu.usbserial-test")
    assert_received {:line, :dtr, true}
    assert_received {:line, :rts, true}
  end
end

defmodule Arkab.Transport.Uart do
  @moduledoc """
  A real serial port, through `circuits_uart`.

  The library is C code and is not always there: it is left out of the build
  on Windows unless asked for (see `mix.exs` and the README). So it is never
  named at compile time - the module is looked up when a port is opened, and
  `available?/0` says whether there is anything to open one with.

  Port names: `COM3` on Windows, `/dev/ttyUSB0` or `/dev/ttyACM0` on Linux,
  `/dev/cu.usbserial-...` or `/dev/cu.usbmodem...` on a Mac (a DGT USB
  board is a serial port to the system; the RS232 models hang on a USB
  adapter).

  A Mac lists every serial device twice, as `/dev/tty.X` and `/dev/cu.X`.
  The `tty.` one is for dial-in: opening it waits for a modem's carrier
  signal, which a chess board never sends. Only the `cu.` one is offered
  (`one_per_device/1`), so nobody has to know that.

  After every open RTS is switched on and DTR off, which is what DGT's own
  LiveChess ends up with (a USB capture of it, 2026-11-21: it opens with
  both on and drops DTR a second later). A DGT RS-232 board borrows the
  voltage for its transmitter from the host's lines, so with neither
  asserted - a Unix asks for neither, a Mac leaves whatever its adapter's
  driver likes - long answers fade out after a few bytes with a zero last.
  With DTR on as well, an old wooden board (firmware 1.9) on a loop does
  exactly the same: 0 of 15 whole boards complete with DTR on, 15 of 15 with
  it off, and the five 4.2 boards on that loop answered in full either way.
  So: RTS on, DTR off, on every system and for both drivers (`power_line/3`).
  """

  @behaviour Arkab.Transport

  require Logger

  defp uart, do: Module.concat(["Circuits", "UART"])

  @impl true
  def available?, do: Code.ensure_loaded?(uart())

  @impl true
  def enumerate do
    if available?() do
      uart()
      |> apply(:enumerate, [])
      |> Enum.map(fn {port, info} ->
        %{port: port, description: info[:description] || info[:manufacturer] || ""}
      end)
      |> one_per_device()
      |> Enum.sort_by(& &1.port)
    else
      []
    end
  rescue
    # Still an empty list - a port list that crashes the page helps nobody -
    # but a logged one: "no boards" with the reason swallowed cost a hall on
    # an old Mac an evening of reinstalling drivers that were fine.
    error ->
      Logger.warning(
        "serial ports could not be listed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      []
  catch
    kind, reason ->
      Logger.warning(
        "serial ports could not be listed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      []
  end

  @doc """
  Drops a Mac's `/dev/tty.X` when `/dev/cu.X` is in the list too (see the
  moduledoc). Every other name passes untouched, so this is a no-op off a
  Mac.
  """
  def one_per_device(ports) do
    names = MapSet.new(ports, & &1.port)

    Enum.reject(ports, fn %{port: port} ->
      case port do
        "/dev/tty." <> device -> MapSet.member?(names, "/dev/cu." <> device)
        _other -> false
      end
    end)
  end

  @impl true
  def open(port, opts) do
    if available?() do
      settings = [
        speed: Keyword.get(opts, :baud, 9600),
        data_bits: 8,
        parity: :none,
        stop_bits: 1,
        flow_control: :none,
        active: true
      ]

      # Every UART process runs a helper program of its own, and a driver
      # retries a port that will not open from the same process, over and
      # over. A failed open used to keep its UART: one stray helper per try,
      # four hundred and sixty-two of them by the next afternoon, and then a
      # Mac with no processes left for anybody. A port that does not open
      # takes its UART down with it.
      with {:ok, pid} <- apply(uart(), :start_link, []) do
        case apply(uart(), :open, [pid, port, settings]) do
          :ok ->
            power_line(uart(), pid, port)
            {:ok, pid}

          failed ->
            close(pid)
            {:error, with({:error, reason} <- failed, do: reason)}
        end
      else
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      {:error, :no_serial_library}
    end
  end

  @doc """
  Sets RTS on and DTR off on an open port, through `module` (`Circuits.UART` in
  life, a stand-in in the test). A failure is logged and swallowed: a port
  that opened is better than a port that did not, even a stingy one.
  """
  def power_line(module, pid, port) do
    for {name, line, on?} <- [{:dtr, :set_dtr, false}, {:rts, :set_rts, true}] do
      case apply(module, line, [pid, on?]) do
        :ok ->
          :ok

        other ->
          Logger.warning(
            "serial port #{port}: could not turn #{name} #{if on?, do: "on", else: "off"}: " <>
              inspect(other)
          )
      end
    end

    :ok
  catch
    kind, reason ->
      Logger.warning(
        "serial port #{port}: could not set DTR and RTS: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :ok
  end

  @impl true
  def write(pid, data), do: apply(uart(), :write, [pid, IO.iodata_to_binary(data)])

  @impl true
  def close(pid) do
    apply(uart(), :close, [pid])
    apply(uart(), :stop, [pid])
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def message({:circuits_uart, _port, {:error, reason}}), do: {:error, reason}
  def message({:circuits_uart, _port, data}) when is_binary(data), do: {:data, data}
  def message(_other), do: nil
end

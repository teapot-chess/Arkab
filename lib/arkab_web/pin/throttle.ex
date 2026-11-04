defmodule ArkabWeb.Pin.Throttle do
  @moduledoc """
  Keeps the access PIN from being guessed: the same scheme as Alnasl's door
  guard, in a process of its own.

  Per peer address: five free failures; from the fifth on the address waits
  5 seconds, then 10, 20 and so on, doubling up to a quarter of an hour, and
  while it waits even the right PIN is refused. A right PIN clears the
  address's count. Across all addresses the box takes at most 40 failures a
  minute; past that everybody waits, right PIN included, until the oldest
  failure of that minute has aged out. That is the price of not letting a
  crowd of addresses take turns. An address quiet for an hour is forgotten,
  and a restart forgives everybody, which is no worse than the attacker
  waiting.

  The peer is the socket's address and never a header, so behind a reverse
  proxy every visitor shares the proxy's address and its count: a hall lock,
  not a per-person one.
  """

  use GenServer

  @free 5
  @base 5
  @cap 900
  @global_limit 40
  @window 60
  @forget 3_600

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, empty()}

  @doc """
  Takes one guess for `key` before the PIN is compared: `:ok`, or
  `{:locked, seconds}`. Every guess is counted as a failure up front, one at
  a time through this process, so a burst of simultaneous guesses cannot
  walk past a wait none of them had recorded yet; a right guess is
  `clear/1`ed afterwards. If the counter is not there to ask, nobody guesses.
  """
  @spec claim(term(), integer()) :: :ok | {:locked, pos_integer()}
  def claim(key, now \\ now()) do
    GenServer.call(__MODULE__, {:claim, key, now})
  catch
    :exit, _reason -> {:locked, @cap}
  end

  @doc "A right guess from `key`: its count starts again, and its claim is no failure."
  @spec clear(term()) :: :ok
  def clear(key) do
    GenServer.call(__MODULE__, {:clear, key})
  catch
    :exit, _reason -> :ok
  end

  @doc "Every count, gone (tests)."
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def handle_call({:claim, key, now}, _from, state) do
    state = prune(state, now)
    wait = max(global_wait(state, now), ip_wait(state, key, now))

    if wait > 0 do
      {:reply, {:locked, wait}, state}
    else
      fails = Map.get(state.ips, key, %{fails: 0}).fails + 1
      until = if fails >= @free, do: now + min(@base * Integer.pow(2, fails - @free), @cap)

      state = %{
        state
        | ips: Map.put(state.ips, key, %{fails: fails, last: now, until: until}),
          global: [now | state.global]
      }

      {:reply, :ok, state}
    end
  end

  # The claim just counted is the newest entry of the box-wide window.
  def handle_call({:clear, key}, _from, state) do
    global =
      case state.global do
        [_newest | rest] -> if Map.has_key?(state.ips, key), do: rest, else: state.global
        [] -> []
      end

    {:reply, :ok, %{state | ips: Map.delete(state.ips, key), global: global}}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty()}

  defp empty, do: %{ips: %{}, global: []}

  defp ip_wait(state, key, now) do
    case state.ips[key] do
      %{until: until} when is_integer(until) -> max(until - now, 0)
      _none -> 0
    end
  end

  defp global_wait(%{global: times}, now) do
    if length(times) >= @global_limit do
      max(Enum.min(times) + @window - now, 0)
    else
      0
    end
  end

  defp prune(state, now) do
    ips =
      state.ips
      |> Enum.reject(fn {_key, %{last: last, until: until}} ->
        now - last > @forget and (until || now) <= now
      end)
      |> Map.new()

    %{state | ips: ips, global: Enum.filter(state.global, &(&1 > now - @window))}
  end

  defp now, do: System.monotonic_time(:second)
end

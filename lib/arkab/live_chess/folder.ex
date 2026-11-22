defmodule Arkab.LiveChess.Folder do
  @moduledoc """
  Watches one LiveChess export folder (`Arkab.LiveChess`) once a second
  and knows which games the round being played has, and where each one's
  file is. Whoever started it is told when the set of games changes:
  `{:livechess_games, name, [game_number]}`, once at the start and on
  every change - a new round with more or fewer boards, a game file that
  appeared. The boards themselves are `Arkab.Driver.LiveChess`, which ask
  `path/2` for their file.

  The scan is here once for the folder, not in every board: deciding the
  round means looking at the time of every game file of every round.
  """

  use GenServer

  alias Arkab.LiveChess

  @every_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, opts[:id] || opts[:folder]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }

  @doc "The file of game `m` of the round being played, or `nil`."
  def path(server, m) do
    GenServer.call(server, {:path, m})
  catch
    :exit, _reason -> nil
  end

  @doc "`%{round, games: %{m => path}}`, or `nil` while there is no game file."
  def current(server), do: GenServer.call(server, :current)

  @impl true
  def init(opts) do
    state = %{
      folder: Keyword.fetch!(opts, :folder),
      label: Keyword.get(opts, :label, Keyword.fetch!(opts, :folder)),
      notify: Keyword.get(opts, :notify),
      every: Keyword.get(opts, :every_ms, @every_ms),
      current: nil,
      told: nil
    }

    {:ok, state, {:continue, :scan}}
  end

  @impl true
  def handle_continue(:scan, state), do: {:noreply, scan(state)}

  @impl true
  def handle_info(:scan, state), do: {:noreply, scan(state)}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:path, m}, _from, state),
    do: {:reply, state.current && Map.get(state.current.games, m), state}

  def handle_call(:current, _from, state), do: {:reply, state.current, state}

  defp scan(state) do
    Process.send_after(self(), :scan, state.every)

    current =
      case LiveChess.current(state.folder) do
        {:ok, found} -> Map.take(found, [:round, :games])
        :none -> nil
      end

    games = if current, do: current.games |> Map.keys() |> Enum.sort(), else: []

    if games != state.told and state.notify,
      do: send(state.notify, {:livechess_games, state.label, games})

    %{state | current: current, told: games}
  end
end

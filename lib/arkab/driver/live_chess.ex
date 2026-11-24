defmodule Arkab.Driver.LiveChess do
  @moduledoc """
  One game of a DGT LiveChess export folder, read as a board: the game
  file of board `m` of the round being played (`Arkab.LiveChess`), looked
  at once a second, and every position in it sent as a board would send
  it - whole positions, clocks, `:connected` / `:disconnected`. The board
  is the PGN; nothing in the hall is asked anything.

  Options (string keys in `:options`): `"folder"`, `"game"` (the number
  `m` of `game-m.pgn`) and `"step_ms"` (default #{300}). `:locate`, a
  function of no arguments that gives the game's file or `nil`, replaces
  the scan of the folder: the bridge gives one that asks the folder's
  `Arkab.LiveChess.Folder`, so that forty boards do not each scan it.

  ## What is sent

  - The first time the file reads as a game (and again after it was gone):
    `:connected`, then who is playing (`{:game, facts}`,
    `Arkab.LiveChess.facts/2`), then the game so far as the board's memory
    (`{:history, events}`, `Arkab.LiveChess.history/1`), then the position
    and clock as they stand. Alnasl holds the game it has up against the
    memory, so a game that was under way before the bridge looked is
    caught up move by move without a guess, and a game it already has is
    left alone - instead of a board that jumped forty moves at once.
  - Moves added to the file afterwards: one position per move, in order,
    `step_ms` apart, each followed by the clock as `[%clk]` had it after
    that move. The clock's running side changes with every move, which
    is a press, and a press is what tells the tracker a move is finished:
    several moves found in the file at once arrive as several moves, not
    as a board that has to be explained.
  - Moves taken out of the file (LiveChess corrected one): the position
    where the file and what was sent agree, then the file's moves from
    there.
  - Another file for the same board (the next round): its starting
    position, then its moves as above - players who sat down and played.
  - Once a second while the file is there: `{:poll, :ok}`, and while the
    game goes on the clock again, the side to move's time counting down
    from its last `[%clk]`. The file says the time after each move; what
    a clock shows between moves is that, less the time since.
  - `{:game, facts}` again whenever the facts change: a forfeit or a name
    put right in the round's `index.json`, a result, the next round.
  - The file gone (or the round has no such board): `:disconnected`.
  - A file with no game in it yet (`{:error, :no_game}`: empty, tags only,
    an empty e-board): `:connected`, who is playing as far as the round's
    index knows, with `no_game: true`, and the starting position - not an
    empty board, which is what a board with no game looked like until
    0.7.3. The game that turns up in the file later is sent as on first
    sight: who is playing, the memory, where it stands. A file that held
    a game and reads empty for a moment is LiveChess rewriting it, and is
    read again on the next tick, like half a file.

  A file read while LiveChess was still writing it (no result token at
  the end: `Arkab.Pgn`) is read again on the next tick. A file whose
  moves cannot be played is logged once and ignored until it changes;
  the board keeps the last position that could.

  No clock (`[%clk]` and the clock tags missing): no clock readings,
  which is a board without a clock.
  """

  @behaviour Arkab.Driver

  use GenServer

  require Logger

  alias Arkab.{Driver, LiveChess}

  @tick_ms 1_000
  @step_ms 300
  # Bigger than any game; smaller than anything that is not one.
  @max_bytes 2_000_000

  @impl Arkab.Driver
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    options = Keyword.get(opts, :options, %{})
    folder = options["folder"]
    game = options["game"]

    locate =
      Keyword.get_lazy(opts, :locate, fn -> fn -> LiveChess.game_path(folder, game) end end)

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      id: Keyword.fetch!(opts, :id),
      locate: locate,
      tick: Keyword.get(opts, :tick_ms, @tick_ms),
      step: positive(options["step_ms"], @step_ms),
      connected?: false,
      # The file being read and what it held when last read: {path, mtime, hash}.
      # The text, not the time: a move corrected within the second is
      # the same size and the same mtime.
      path: nil,
      seen: nil,
      # The game as last read, and how many of its positions were sent.
      game: nil,
      sent: 0,
      stepping?: false,
      # Since when the side to move has been thinking (wall clock, ms).
      since: nil,
      # A file that could not be played, said once: {path, mtime, hash}.
      bad: nil,
      # Who is playing (`LiveChess.facts/2`) as last sent, and the files
      # it was read from as they were then: {seen, index mtime, tournament mtime}.
      facts: nil,
      facts_from: nil,
      # The file has no game yet: the starting position was sent instead.
      no_game?: false
    }

    send(self(), :tick)
    {:ok, state}
  end

  defp positive(n, _default) when is_integer(n) and n > 0, do: n
  defp positive(_other, default), do: default

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick)
    {:noreply, state |> read() |> facts() |> heartbeat()}
  end

  def handle_info(:step, state), do: {:noreply, step(%{state | stepping?: false})}
  def handle_info(_other, state), do: {:noreply, state}

  # --- reading the file ----------------------------------------------------------

  # sobelow_skip ["Traversal.FileModule"]
  defp read(state) do
    with path when is_binary(path) <- state.locate.(),
         {:ok, %{mtime: mtime, size: size}} when size <= @max_bytes <-
           File.stat(path, time: :posix),
         {:ok, text} <- File.read(path) do
      seen = {path, mtime, :erlang.phash2(text)}

      if seen in [state.seen, state.bad] or same_text?(seen, state.seen),
        do: state,
        else: load(state, path, seen, text)
    else
      _gone -> gone(state)
    end
  end

  # Touched, not changed: nothing to read again.
  defp same_text?({path, _t, hash}, {path, _t2, hash}), do: true
  defp same_text?(_seen, _before), do: false

  defp load(state, path, seen, text) do
    case LiveChess.parse_game(text) do
      {:ok, game} ->
        state |> take(path, game, seen) |> Map.put(:bad, nil)

      # Half written: the next tick reads it again.
      {:error, :partial} ->
        state

      # The same file had a game a second ago: LiveChess is rewriting it.
      {:error, :no_game} when path == state.path and not state.no_game? and state.game != nil ->
        state

      {:error, :no_game} ->
        waiting(state, path, seen)

      {:error, why} ->
        Logger.warning(
          "arkab: #{state.id}: #{Path.basename(path)} cannot be read: #{describe(why)}"
        )

        %{state | bad: seen}
    end
  end

  defp describe({:illegal, ply, why}), do: "move #{ply}: #{why}"

  defp gone(%{connected?: false} = state), do: state

  defp gone(state) do
    emit(state, :disconnected)

    %{
      state
      | connected?: false,
        seen: nil,
        path: nil,
        game: nil,
        sent: 0,
        facts_from: nil,
        no_game?: false
    }
  end

  # No game in the file yet: the board is there, at the starting position,
  # and says so. Players from the index, when it has them.
  defp waiting(%{no_game?: true, path: path} = state, path, seen), do: %{state | seen: seen}

  defp waiting(state, path, seen) do
    if not state.connected?, do: emit(state, :connected)
    game = LiveChess.no_game()

    state =
      %{
        state
        | connected?: true,
          path: path,
          seen: seen,
          game: game,
          sent: 1,
          since: nil,
          no_game?: true,
          bad: nil
      }
      |> facts(true)

    emit(state, {:position, hd(game.plies).board})
    state
  end

  # A game read for the first time since the board came (or since the file
  # had none): its memory, then where it stands.
  defp take(%{connected?: connected?, no_game?: no_game?} = state, path, game, seen)
       when not connected? or no_game? do
    if not connected?, do: emit(state, :connected)
    state = %{state | no_game?: false}
    # Who is playing before what was played: Alnasl puts the board on its
    # pairing, and the memory is the game of that pairing.
    state =
      state |> Map.merge(%{connected?: true, path: path, seen: seen, game: game}) |> facts(true)

    emit(state, {:history, LiveChess.history(game)})
    last = length(game.plies) - 1
    emit(state, {:position, Enum.at(game.plies, last).board})
    # The side to move has been thinking since the file was written.
    state = %{
      state
      | connected?: true,
        path: path,
        seen: seen,
        game: game,
        sent: last + 1,
        since: mtime_ms(seen)
    }

    clock(state, last, System.os_time(:millisecond))
    state
  end

  # Another file: another game on the same board.
  defp take(%{path: old} = state, path, game, seen) when old != path do
    schedule(%{state | path: path, seen: seen, game: game, sent: 0})
  end

  defp take(state, path, game, seen) do
    sent = min(state.sent, agree(state.game.plies, game.plies))
    # Sent past where the two agree: the last position they share goes again.
    sent = if sent < state.sent, do: max(sent - 1, 0), else: sent
    schedule(%{state | path: path, seen: seen, game: game, sent: sent})
  end

  defp agree(a, b) do
    a
    |> Enum.zip(b)
    |> Enum.take_while(fn {x, y} -> x.board == y.board end)
    |> length()
  end

  defp mtime_ms({_path, mtime, _size}), do: mtime * 1000

  # --- who is playing ----------------------------------------------------------------

  # The facts are read again when the game file, the round's index or the
  # tournament's file changed, and sent when they say something new: a
  # forfeit in the index, a name put right, the next round's players.
  # `force?`: sent whatever was sent before (a board that came back).
  defp facts(state, force? \\ false)

  defp facts(%{connected?: true, game: game, path: path} = state, force?) when game != nil do
    from = {state.seen, index_mtime(path), tournament_mtime(path)}

    if from == state.facts_from and not force? do
      state
    else
      facts = LiveChess.facts(path, game)
      facts = if state.no_game?, do: Map.put(facts, :no_game, true), else: facts
      if facts != state.facts or force?, do: emit(state, {:game, facts})
      %{state | facts: facts, facts_from: from}
    end
  end

  defp facts(state, _force?), do: state

  defp index_mtime(path), do: LiveChess.mtime(Path.join(Path.dirname(path), "index.json"))

  defp tournament_mtime(path),
    do: LiveChess.mtime(Path.join(Path.dirname(Path.dirname(path)), "tournament.json"))

  # --- sending ---------------------------------------------------------------------

  defp schedule(%{stepping?: true} = state), do: state

  defp schedule(%{game: game, sent: sent} = state) do
    if sent < length(game.plies), do: step(state), else: state
  end

  defp step(%{game: nil} = state), do: state

  defp step(%{game: game, sent: i} = state) do
    if i < length(game.plies) do
      emit(state, {:position, Enum.at(game.plies, i).board})
      now = System.os_time(:millisecond)
      state = %{state | sent: i + 1, since: now}
      clock(state, i, now)

      if i + 1 < length(game.plies) do
        Process.send_after(self(), :step, state.step)
        %{state | stepping?: true}
      else
        state
      end
    else
      state
    end
  end

  # The clock while nothing new is being sent: the running side counts down.
  defp heartbeat(%{connected?: true, game: game, sent: sent} = state) when game != nil do
    emit(state, {:poll, :ok})

    if sent == length(game.plies) and not LiveChess.decided?(game) and sent > 1,
      do: clock(state, sent - 1, System.os_time(:millisecond))

    state
  end

  defp heartbeat(state), do: state

  defp clock(state, i, now) do
    elapsed = max(now - (state.since || now), 0)

    case LiveChess.clock(state.game, i, elapsed) do
      nil -> :ok
      reading -> emit(state, {:clock, reading})
    end
  end

  defp emit(state, event), do: Driver.emit(state.owner, state.id, event)
end

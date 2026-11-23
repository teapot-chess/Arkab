defmodule Arkab.Bridge.Ports do
  @moduledoc """
  What the bridge reads: its ports, and the boards on each. Every command a
  server sends ends here, one at a time, in the order they arrived - two
  servers that disagree are both obeyed, the later one last.

  ## A port

  A serial port is read as one board first (`Arkab.Driver.DgtSerial`),
  which asks the line who is there before it says anything to a board. When
  more than one board answers, the driver says so and lets go of the port,
  and the port is read as a loop (`Arkab.Driver.DgtBus`): a board for each
  address that answered. A board plugged into the loop later answers the
  bus's ten-second ping and is read from then on (`stranger/2`). This is
  the same discovery Alnasl does with its own ports; there is no switch for
  it.

  The ports are kept in the bridge's file (`"ports"`), so a bridge that
  restarts reads what it read before. A source can also be a capture
  played back (`%{"replay" => path, "name" => name, "speed" => n}`): the
  hall without the hall, for the tests and for trying a server out.

  ## A LiveChess folder

  `%{"folder" => path, "name" => name}`: the folder DGT LiveChess exports a
  tournament to (`Arkab.LiveChess`). A watcher (`Arkab.LiveChess.Folder`)
  says which games the round being played has, and each is a board,
  `name#m` for `game-m.pgn` (`Arkab.Driver.LiveChess`). The next round with
  more boards gets more boards here, and fewer fewer; board 3 of the next
  round is the same board 3, with another game on it. `add_folder` names
  it "LiveChess", or "LiveChess 2" when that name is taken.

  ## Board names

  `Arkab.Protocol.board_id/2`: the port for a single board, `port#address`
  on a loop, the name for a replay, `name#m` for a LiveChess game. Alnasl
  makes its rows of them.
  """

  use GenServer

  require Logger

  alias Arkab.Bridge.{Board, Store}
  alias Arkab.Driver.{DgtBus, DgtSerial, Replay}
  alias Arkab.LiveChess.Folder
  alias Arkab.Protocol

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Applies a command from a server; `owner?` says whether that server may make it forget things."
  def command(frame, owner?), do: GenServer.call(__MODULE__, {:command, frame, owner?}, 30_000)

  @doc "`%{ports: [%{port, description, read?}], boards: [Board.status]}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Reads `port` from now on, and after a restart."
  def add(source), do: GenServer.call(__MODULE__, {:add, source})

  @doc "Reads a DGT LiveChess export folder from now on (`add_folder`, from the status page)."
  def add_folder(folder), do: command(%{"cmd" => "add_folder", "folder" => folder}, true)

  @doc "A board answered on the loop of `port` that is not read. Called by the bus."
  def stranger(port, address), do: send(__MODULE__, {:stranger, port, address})

  # --- the process -------------------------------------------------------------

  @impl true
  def init(opts) do
    :persistent_term.put({Arkab.Bridge, :recording}, Store.get("recording", true))
    stored = Store.get("ports")

    sources =
      case Keyword.fetch(opts, :sources) do
        {:ok, given} -> given
        :error -> stored || []
      end
      |> Enum.uniq_by(&same_source/1)

    if sources != stored, do: Store.put("ports", sources)

    state = %{
      sources: sources,
      forgotten: MapSet.new(Store.get("forgotten", [])),
      supervisor: Keyword.get(opts, :supervisor, Arkab.Bridge.Boards),
      listeners: Keyword.get(opts, :listeners, Arkab.Bridge.Listeners),
      transport: Keyword.get(opts, :transport)
    }

    for source <- sources, do: start_source(state, source)
    {:ok, state}
  end

  @impl true
  def handle_call({:command, %{"cmd" => cmd} = frame, owner?}, _from, state) do
    if cmd in Protocol.owner_only() and not owner? do
      {:reply, {:error, :not_owner}, state}
    else
      {reply, state} = run(cmd, frame, state)
      {:reply, reply, state}
    end
  end

  def handle_call({:command, _frame, _owner?}, _from, state),
    do: {:reply, {:error, :unknown_command}, state}

  def handle_call(:status, _from, state), do: {:reply, describe(state), state}

  def handle_call({:add, source}, _from, state) do
    {reply, state} = add_source(state, source)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:loop, port, addresses}, state) do
    if Enum.any?(state.sources, &(&1["port"] == port)) do
      stop_board(state, Protocol.board_id(port, nil))

      for address <- addresses,
          id = Protocol.board_id(port, address),
          not MapSet.member?(state.forgotten, id),
          do: start_bus_board(state, port, address)

      changed(state)
    end

    {:noreply, state}
  end

  def handle_info({:stranger, port, address}, state) do
    id = Protocol.board_id(port, address)

    unless MapSet.member?(state.forgotten, id) or Board.whereis(id) do
      start_bus_board(state, port, address)
      changed(state)
    end

    {:noreply, state}
  end

  # The games of a LiveChess folder's round: a board for each, and none
  # for a game the round no longer has.
  def handle_info({:livechess_games, name, games}, state) do
    case Enum.find(state.sources, &match?(%{"folder" => _, "name" => ^name}, &1)) do
      nil ->
        :ok

      source ->
        wanted = MapSet.new(games, &Protocol.board_id(name, &1))

        for id <- Board.ids(),
            elem(Protocol.parse_board_id(id), 0) == name,
            not MapSet.member?(wanted, id),
            do: stop_board(state, id)

        for m <- games,
            id = Protocol.board_id(name, m),
            not MapSet.member?(state.forgotten, id),
            Board.whereis(id) == nil,
            do: start_game_board(state, source, m)

        changed(state)
    end

    {:noreply, state}
  end

  def handle_info(:boards_changed, state) do
    changed(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- commands ----------------------------------------------------------------

  defp run("resend", frame, state) do
    ids = if frame["board"], do: [frame["board"]], else: Board.ids()
    results = Enum.map(ids, &Board.resend/1)
    {if(Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :no_such_board}), state}
  end

  defp run("rescan", frame, state) do
    for source <- state.sources, frame["port"] in [nil, source_port(source)] do
      stop_source(state, source)
      start_source(state, source)
    end

    changed(state)
    {:ok, state}
  end

  defp run("add_port", %{"port" => port}, state) when is_binary(port) and port != "",
    do: add_source(state, %{"port" => port})

  defp run("add_folder", %{"folder" => folder}, state) when is_binary(folder) do
    folder = String.trim(folder)

    cond do
      folder == "" or not File.dir?(folder) ->
        {{:error, :no_such_folder}, state}

      source = Enum.find(state.sources, &(same_source(&1) == {:folder, folder_key(folder)})) ->
        # Asked for again: what was forgotten of it is welcome back, or the
        # owner has no way left to see game 1 once board 1 was put away.
        state = welcome_back(state, source_port(source))

        case Registry.lookup(Arkab.Bridge.BoardRegistry, {:folder, source["name"]}) do
          [{pid, _}] -> send(self(), {:livechess_games, source["name"], games_of(pid)})
          [] -> start_source(state, source)
        end

        changed(state)
        {:ok, state}

      true ->
        add_source(state, %{"folder" => folder, "name" => folder_name(state.sources)})
    end
  end

  defp run("forget_port", %{"port" => port}, state) when is_binary(port) do
    {gone, kept} = Enum.split_with(state.sources, &(source_port(&1) == port))
    for source <- gone, do: stop_source(state, source)
    Store.put("ports", kept)
    state = %{state | sources: kept}
    state = if gone == [], do: state, else: welcome_back(state, port)
    changed(state)
    {if(gone == [], do: {:error, :no_such_port}, else: :ok), state}
  end

  defp run("forget_board", %{"board" => id}, state) when is_binary(id) do
    stop_board(state, id)
    forgotten = MapSet.put(state.forgotten, id)
    Store.put("forgotten", MapSet.to_list(forgotten))
    state = %{state | forgotten: forgotten}
    changed(state)
    {:ok, state}
  end

  defp run("record", %{"on" => on}, state) when is_boolean(on) do
    Arkab.Bridge.set_recording(on)
    changed(state)
    {:ok, state}
  end

  defp run(_cmd, _frame, state), do: {{:error, :bad_command}, state}

  defp add_source(state, source) do
    port = source_port(source)

    if Enum.any?(state.sources, &(source_port(&1) == port)) do
      {:ok, state}
    else
      sources = state.sources ++ [source]
      Store.put("ports", sources)
      # A port read again is a port whose boards are welcome again.
      state = welcome_back(%{state | sources: sources}, port)
      start_source(state, source)
      changed(state)
      {:ok, state}
    end
  end

  # --- boards ------------------------------------------------------------------

  defp source_port(%{"port" => port}), do: port
  defp source_port(%{"replay" => _path, "name" => name}), do: name
  defp source_port(%{"folder" => _path, "name" => name}), do: name

  @doc """
  One folder, however it was typed: `C:\\users\\x` and `C:\\Users\\x\\` are
  the same folder to Windows (and to macOS, case-insensitive out of the box),
  and reading it twice gave every game two boards. Linux keeps case apart.
  """
  def folder_key(path, os \\ :os.type()) do
    key =
      path
      |> String.trim()
      |> String.replace("\\", "/")
      |> Path.expand()
      |> String.trim_trailing("/")

    if os == {:unix, :linux}, do: key, else: String.downcase(key)
  end

  # The boards of `port` that were put away are no longer remembered as such.
  defp welcome_back(state, port) do
    forgotten = MapSet.reject(state.forgotten, &(elem(Protocol.parse_board_id(&1), 0) == port))
    if forgotten != state.forgotten, do: Store.put("forgotten", MapSet.to_list(forgotten))
    %{state | forgotten: forgotten}
  end

  defp same_source(%{"folder" => path}), do: {:folder, folder_key(path)}
  defp same_source(source), do: {:port, source_port(source)}

  defp folder_name(sources) do
    taken = MapSet.new(sources, &source_port/1)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> "LiveChess"
      n -> "LiveChess #{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp start_source(state, %{"folder" => folder, "name" => name}) do
    spec =
      {Folder, id: name, folder: folder, label: name, notify: self(), name: folder_via(name)}

    case DynamicSupervisor.start_child(state.supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Ports restarted, the watcher did not: what it knows is told again.
        send(self(), {:livechess_games, name, games_of(pid)})
        {:ok, pid}

      error ->
        Logger.warning("arkab: folder #{folder} is not read: #{inspect(error)}")
        error
    end
  end

  defp start_source(state, %{"replay" => path, "name" => name} = source) do
    options = %{"path" => path, "speed" => source["speed"] || 1}

    start_board(state,
      id: name,
      port: name,
      driver: Replay,
      driver_opts: [options: options]
    )
  end

  defp start_source(state, %{"port" => port}) do
    id = Protocol.board_id(port, nil)

    unless MapSet.member?(state.forgotten, id) do
      start_board(state,
        id: id,
        port: port,
        driver: DgtSerial,
        driver_opts: transport(state, options: %{"clock" => true})
      )
    end
  end

  defp start_game_board(state, %{"folder" => folder, "name" => name}, m) do
    watcher = folder_via(name)

    start_board(state,
      id: Protocol.board_id(name, m),
      port: name,
      address: m,
      driver: Arkab.Driver.LiveChess,
      resend_history: true,
      driver_opts: [
        options: %{"folder" => folder, "game" => m},
        locate: fn -> Folder.path(watcher, m) end
      ]
    )
  end

  defp folder_via(name), do: {:via, Registry, {Arkab.Bridge.BoardRegistry, {:folder, name}}}

  defp games_of(pid) do
    case Folder.current(pid) do
      %{games: games} -> games |> Map.keys() |> Enum.sort()
      nil -> []
    end
  catch
    :exit, _reason -> []
  end

  defp start_bus_board(state, port, address) do
    start_board(state,
      id: Protocol.board_id(port, address),
      port: port,
      address: address,
      driver: DgtBus,
      driver_opts: transport(state, stranger: &__MODULE__.stranger/2)
    )
  end

  defp transport(%{transport: nil}, opts), do: opts
  defp transport(%{transport: transport}, opts), do: [{:transport, transport} | opts]

  defp start_board(state, opts) do
    case DynamicSupervisor.start_child(state.supervisor, {Board, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      error ->
        Logger.warning("arkab: board #{opts[:id]} did not start: #{inspect(error)}")
        error
    end
  end

  defp stop_source(state, source) do
    port = source_port(source)

    for id <- Board.ids(), elem(Protocol.parse_board_id(id), 0) == port do
      stop_board(state, id)
    end

    if source["folder"], do: stop_watcher(state, port), else: await_bus_gone(port)
  end

  defp stop_watcher(state, name) do
    case Registry.lookup(Arkab.Bridge.BoardRegistry, {:folder, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(state.supervisor, pid)
      [] -> :ok
    end
  end

  # The loop's bus lets go of the port when its last board has gone, which
  # it learns from a message. A port read again before that is a port two
  # drivers talk on at once (a Mac lets two programs open the same serial
  # device), and what the old board hears is two askers.
  defp await_bus_gone(port) do
    case DgtBus.whereis(port) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          2_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end

  defp stop_board(state, id) do
    case Board.whereis(id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(state.supervisor, pid)
    end
  end

  # --- what the servers are told ---------------------------------------------

  defp describe(state) do
    read = MapSet.new(state.sources, &source_port/1)

    available =
      try do
        Arkab.Transport.ports()
      rescue
        _error -> []
      end

    ports =
      Enum.map(state.sources, fn source ->
        port = source_port(source)
        found = Enum.find(available, &(&1.port == port))
        description = source["folder"] || (found && found.description) || ""
        %{port: port, description: description, read?: true}
      end) ++
        for(
          found <- available,
          not MapSet.member?(read, found.port),
          do: %{port: found.port, description: found.description, read?: false}
        )

    boards =
      for id <- Board.ids(), pid = Board.whereis(id), pid != nil do
        try do
          Board.status(pid)
        catch
          :exit, _reason -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    %{ports: ports, boards: boards, recording?: Arkab.Bridge.recording?()}
  end

  defp changed(state) do
    Registry.dispatch(state.listeners, :boards, fn entries ->
      for {pid, _} <- entries, do: send(pid, :boards_changed)
    end)
  end
end

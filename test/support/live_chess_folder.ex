defmodule Arkab.LiveChessFolder do
  @moduledoc """
  A LiveChess export folder for the tests, written the way LiveChess 2's
  filesystem exporter writes one: `tournament.json`, `round-N/index.json`
  and `round-N/game-M.pgn` (the same layout as LiveChessCloud's). The
  players are made up.
  """

  @players [
    {"Wanda", "Vermeulen", "BEL"},
    {"Otto", "Brask", "NED"},
    {"Ines", "Quaghebeur", "BEL"},
    {"Ruben", "Taelman", "FRA"},
    {"Lotte", "Ysebaert", "BEL"},
    {"Kasper", "Duym", "GER"}
  ]

  def new(root, opts \\ []) do
    dir = if sub = opts[:subfolder], do: Path.join(root, sub), else: root
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "tournament.json"),
      Jason.encode!(%{
        "id" => "4d0c6b8e-0000-4000-8000-000000000001",
        "name" => "Open of Nowhere",
        "location" => "Somewhere",
        "country" => "BEL",
        "website" => nil,
        "rules" => "STANDARD",
        "chess960" => "NO",
        "timecontrol" => "90+30",
        "rounds" => for(_ <- 1..5, do: %{"count" => 3, "live" => 0}),
        "eboards" => ["48714", "48715", "48716"]
      })
    )

    dir
  end

  @doc "Writes round `n` with `games` (`[{m, pgn_text}]`) and its index."
  def round(dir, n, games) do
    round_dir = Path.join(dir, "round-#{n}")
    File.mkdir_p!(round_dir)

    pairings =
      for {_m, _pgn} <- games do
        [{wf, wl, wfed}, {bf, bl, bfed}] = Enum.take_random(@players, 2)

        %{
          "white" => player(wf, wl, wfed),
          "black" => player(bf, bl, bfed),
          "result" => "*",
          "live" => true
        }
      end

    File.write!(
      Path.join(round_dir, "index.json"),
      Jason.encode!(%{"date" => "2026-11-22", "pairings" => pairings})
    )

    for {m, pgn} <- games, do: write_game(dir, n, m, pgn)
    round_dir
  end

  def write_game(dir, n, m, pgn) do
    path = Path.join([dir, "round-#{n}", "game-#{m}.pgn"])
    File.write!(path, pgn)
    path
  end

  defp player(f, l, fed),
    do: %{
      "fname" => f,
      "mname" => nil,
      "lname" => l,
      "title" => nil,
      "federation" => fed,
      "gender" => nil,
      "fideid" => nil
    }

  @doc """
  A game as LiveChess's PGN writer has it: `moves` is `[{san, "h:mm:ss"}]`
  (or a bare san), with `[%clk]` and `[%emt]` after each.
  """
  def pgn(moves, result \\ "*", headers \\ %{}) do
    tags =
      Map.merge(
        %{
          "Event" => "Open of Nowhere",
          "Site" => "Somewhere",
          "Date" => "2026.11.22",
          "Round" => "1",
          "White" => "Vermeulen, Wanda",
          "Black" => "Brask, Otto",
          "Result" => result,
          "TimeControl" => "5400+30",
          "WhiteClock" => "1:30:00",
          "BlackClock" => "1:30:00"
        },
        headers
      )

    head = Enum.map_join(tags, "\n", fn {k, v} -> ~s([#{k} "#{v}"]) end)

    body =
      moves
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {move, i} ->
        number = if rem(i, 2) == 0, do: "#{div(i, 2) + 1}. ", else: ""

        case move do
          {san, clk} -> "#{number}#{san} {[%clk #{clk}] [%emt 0:00:05]}"
          san -> "#{number}#{san}"
        end
      end)

    head <> "\n\n" <> String.trim(body <> " " <> result) <> "\n"
  end

  @doc "Sets a file's modification time `seconds` from now (into the past when negative)."
  def touch(path, seconds) do
    t = System.os_time(:second) + seconds
    File.touch!(path, t)
  end
end

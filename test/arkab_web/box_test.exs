defmodule ArkabWeb.BoxTest do
  @moduledoc """
  The "This box" section on a Pi image: which system image runs, the "v7 is
  available" card with its confirmation and progress, and "Switch to master"
  on a slave. All of it asks the box's setup server, here a stand-in
  (`:help_req_options`); none of it is drawn where that server is not.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arkab.{Bridge, Box}

  @endpoint ArkabWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-box-#{System.unique_integer([:positive])}")
    start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:arkab, :help_available)
      Application.delete_env(:arkab, :help_req_options)
    end)

    :ok
  end

  @system %{
    "train" => "v6",
    "version" => "6.0",
    "slot" => "A",
    "ab" => true,
    "updates_on" => true,
    "phase" => "idle",
    "progress" => nil,
    "busy" => false,
    "trial" => nil,
    "offer" => %{
      "train" => "v7",
      "version" => "7.0",
      "size" => 900_000_000,
      "released" => "2027-01-05",
      "notes" => "Newer everything."
    }
  }

  # Stands in for 127.0.0.1:4041. `state` is read on every request, so a test can change the box's
  # answer between ticks; every request is sent to the test as {:req, method, path, body}.
  defp box(state) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> state end)

    Application.put_env(:arkab, :help_available, true)

    Application.put_env(:arkab, :help_req_options,
      plug: fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = if raw == "", do: nil, else: Jason.decode!(raw)

        send(
          test,
          {:req, conn.method, conn.request_path, body,
           Plug.Conn.get_req_header(conn, "x-alnasl-setup")}
        )

        st = Agent.get(agent, & &1)

        case {conn.method, conn.request_path} do
          {"GET", "/api/system"} -> Req.Test.json(conn, st.system)
          {"GET", "/api/mode"} -> Req.Test.json(conn, %{"mode" => st.mode, "set" => true})
          {"POST", "/api/system/upgrade"} -> reply(conn, st[:upgrade] || {200, %{"ok" => true}})
          {"POST", "/api/mode"} -> reply(conn, st[:switch] || {200, %{"ok" => true}})
        end
      end
    )

    agent
  end

  defp reply(conn, {status, body}) do
    conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
  end

  # The page asks the box off its own process; wait for the first answer to be drawn.
  defp settled(view) do
    render_async(view, 5_000)
    view
  end

  test "nothing is drawn where there is no setup server" do
    Application.put_env(:arkab, :help_available, false)
    {:ok, view, _html} = live(build_conn(), "/")
    refute has_element?(view, "#box")
    refute has_element?(view, "#upgrade-card")
  end

  test "a visitor from the network sees none of it, and the box is not even asked" do
    box(%{system: @system, mode: "slave"})

    conn =
      Plug.Test.put_peer_data(build_conn(), %{
        address: {192, 168, 1, 23},
        port: 50_000,
        ssl_cert: nil
      })

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#box")
    refute_received {:req, _, _, _, _}
    refute has_element?(view, "#upgrade-card")
  end

  test "shows the image and, when a later train is on offer, the card" do
    box(%{system: @system, mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)

    assert has_element?(view, "#box-version", "v6")
    assert has_element?(view, "#box-version", "6.0")
    assert has_element?(view, "#upgrade-card h4", "v7 is available")
    assert has_element?(view, "#upgrade-notes", "Newer everything.")
    refute has_element?(view, "#upgrade-confirm")
    refute has_element?(view, "#mode-card")
  end

  test "no offer, no card" do
    box(%{system: Map.put(@system, "offer", nil), mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)

    assert has_element?(view, "#box-version")
    refute has_element?(view, "#upgrade-card")
  end

  test "the button asks first; yes posts the upgrade the way the menu does" do
    box(%{system: @system, mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)

    view |> element("#upgrade-open") |> render_click()
    assert has_element?(view, "#upgrade-confirm")
    refute_received {:req, "POST", _, _, _}

    view |> element("#upgrade-no") |> render_click()
    refute has_element?(view, "#upgrade-confirm")

    view |> element("#upgrade-open") |> render_click()
    view |> element("#upgrade-yes") |> render_click()
    render_async(view, 5_000)

    assert_received {:req, "POST", "/api/system/upgrade",
                     %{"train" => "v7", "confirm" => "UPGRADE", "by" => "arkab"}, ["1"]}

    assert has_element?(view, "#upgrade-message", "has started")
  end

  test "progress from phase and progress while the box works" do
    agent = box(%{system: @system, mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)

    Agent.update(agent, fn st ->
      %{st | system: %{@system | "busy" => true, "phase" => "downloading", "progress" => 42}}
    end)

    # The page asks again by itself while an upgrade runs; a click that starts one asks at once.
    view |> element("#upgrade-open") |> render_click()
    view |> element("#upgrade-yes") |> render_click()
    render_async(view, 5_000)
    render_async(view, 5_000)

    assert has_element?(view, "#upgrade-progress", "Downloading the update")
    assert has_element?(view, "#upgrade-percent", "42%")
    assert has_element?(view, "progress[value='42']")
    refute has_element?(view, "#upgrade-card")
  end

  test "each refusal of the box has its own sentence" do
    for {key, sentence} <- [
          {"busy", "another update"},
          {"updates_off", "System updates are off"},
          {"not_ab", "cannot take system updates"},
          {"bad_train", "not a later train"}
        ] do
      box(%{system: @system, mode: "master", upgrade: {400, %{"error" => key}}})
      {:ok, view, _html} = live(build_conn(), "/")
      settled(view)
      view |> element("#upgrade-open") |> render_click()
      view |> element("#upgrade-yes") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#upgrade-message", sentence)
    end
  end

  test "a round in progress is said so" do
    box(%{system: Map.put(@system, "request_error", "round_in_progress"), mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)
    assert has_element?(view, "#upgrade-round", "round is in progress")
  end

  test "updates off: the card says so and the button is dead" do
    box(%{system: %{@system | "updates_on" => false}, mode: "master"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)
    assert has_element?(view, "#upgrade-off")
    assert has_element?(view, "#upgrade-open[disabled]")
  end

  test "the Dutch page has the card in Dutch" do
    box(%{system: @system, mode: "master"})
    conn = build_conn() |> get("/lang/nl") |> recycle()
    {:ok, view, _html} = live(conn, "/")
    settled(view)
    assert has_element?(view, "#upgrade-card h4", "v7 is beschikbaar")
    assert has_element?(view, "#upgrade-open", "Upgraden naar v7")
  end

  test "a slave offers Switch to master, with a question first" do
    box(%{system: Map.put(@system, "offer", nil), mode: "slave"})
    {:ok, view, _html} = live(build_conn(), "/")
    settled(view)

    assert has_element?(view, "#mode-card")
    view |> element("#switch-open") |> render_click()
    assert has_element?(view, "#switch-confirm")
    refute_received {:req, "POST", _, _, _}

    view |> element("#switch-no") |> render_click()
    refute has_element?(view, "#switch-confirm")

    view |> element("#switch-open") |> render_click()
    view |> element("#switch-yes") |> render_click()
    render_async(view, 5_000)

    assert_received {:req, "POST", "/api/mode", %{"mode" => "master", "confirm" => "SWITCH"},
                     ["1"]}

    assert has_element?(view, "#switch-message", "restarts")
  end

  test "Box.upgrade/1 maps an unknown refusal to a server error" do
    box(%{system: @system, mode: "master", upgrade: {400, %{"error" => "whatever"}}})
    assert Box.upgrade("v7") == {:error, :server_error}
  end
end

defmodule ArkabWeb.PinTest do
  @moduledoc """
  The access PIN: always there, made at the first start, kept in a file the
  box can read, shown and changed on the bridge itself only, asked of every
  other browser before it sees anything, throttled, and every grant void the
  moment it changes.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arkab.{Bridge, FakeServer}
  alias ArkabWeb.{Local, Pin}

  @endpoint ArkabWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-pin-#{System.unique_integer([:positive])}")
    start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})
    Pin.Throttle.reset()
    :ok = Pin.set("2468-hall")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # Who is asking: another computer, a loopback proxy (tailscale serve), or
  # this machine.
  defp as(conn, :lan),
    do: Plug.Test.put_peer_data(conn, %{address: {192, 168, 1, 23}, port: 50_000, ssl_cert: nil})

  defp as(conn, :proxied), do: Plug.Conn.put_req_header(conn, "x-forwarded-for", "100.64.0.7")
  defp as(conn, :local), do: conn

  # The unlock form, filled in: returns the answer, with the session in it.
  defp unlock(kind, pin, session \\ nil) do
    base = if session, do: recycle(session), else: build_conn()
    page = base |> as(kind) |> get("/unlock")
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(page, 200))

    page |> recycle() |> as(kind) |> post("/unlock", %{"_csrf_token" => token, "pin" => pin})
  end

  defp open(session, kind), do: session |> recycle() |> as(kind) |> live("/")

  defp joined_server do
    server = FakeServer.start(codes: ["P"])
    {:ok, _id} = Bridge.join(FakeServer.link(server, "P"))
    [%{id: id}] = Bridge.Store.servers()
    id
  end

  describe "the PIN itself" do
    test "is kept in plaintext in access-pin, one line, and checked", %{dir: dir} do
      assert File.read!(Path.join(dir, "access-pin")) == "2468-hall\n"
      assert Pin.current() == "2468-hall"
      assert {:ok, %{"stamp" => _, "until" => _}} = Pin.attempt("2468-hall", :peer)
      assert {:error, :wrong} = Pin.attempt("2468-halL", :peer)
    end

    test "the file is private, and no .new is left behind", %{dir: dir} do
      refute File.exists?(Path.join(dir, "access-pin.new"))

      unless match?({:win32, _}, :os.type()) do
        assert File.stat!(Path.join(dir, "access-pin")).mode |> Bitwise.band(0o777) == 0o600
      end
    end

    test "6 to 64 printable characters, no space at the ends" do
      assert {:error, :too_short} = Pin.set("12345")
      assert {:error, :too_long} = Pin.set(String.duplicate("x", 65))
      assert {:error, :edge_space} = Pin.set(" 123456")
      assert {:error, :edge_space} = Pin.set("123456 ")
      assert {:error, :invisible} = Pin.set("123\t456")
      assert {:error, :invisible} = Pin.set("123" <> <<0x85::utf8>> <> "456")
      assert {:error, :invisible} = Pin.set(<<0xFF, 0xFE, "123456">>)
      assert Pin.current() == "2468-hall"

      assert :ok = Pin.set("123456")
      assert :ok = Pin.set(String.duplicate("é", 64))
      assert :ok = Pin.set("a pass phrase, with spaces & signs")
      assert Pin.current() == "a pass phrase, with spaces & signs"
    end

    test "there is no way to remove it" do
      refute function_exported?(Pin, :remove, 0)
      assert {:error, :too_short} = Pin.set("")
      assert Pin.current() == "2468-hall"
    end

    test "a new random PIN is six digits, and replaces the old one", %{dir: dir} do
      assert {:ok, pin} = Pin.new_random()
      assert pin =~ ~r/\A\d{6}\z/
      assert Pin.current() == pin
      assert File.read!(Path.join(dir, "access-pin")) == pin <> "\n"
      assert Enum.all?(1..200, fn _ -> Pin.random_digits() =~ ~r/\A\d{6}\z/ end)
    end

    test "changing the PIN, or a new random one, voids every grant" do
      {:ok, grant} = Pin.attempt("2468-hall", :peer)
      assert Pin.valid_grant?(grant)

      :ok = Pin.set("1357-hall")
      refute Pin.valid_grant?(grant)

      {:ok, grant} = Pin.attempt("1357-hall", :peer)
      assert Pin.valid_grant?(grant)
      {:ok, _pin} = Pin.new_random()
      refute Pin.valid_grant?(grant)
    end

    test "a grant holds a stamp of the PIN, not the PIN" do
      {:ok, grant} = Pin.attempt("2468-hall", :peer)
      refute inspect(grant) =~ "2468"
      assert byte_size(Base.decode64!(grant["stamp"])) == 16
    end

    test "an expired or forged grant is no grant" do
      {:ok, %{"stamp" => stamp}} = Pin.attempt("2468-hall", :peer)
      now = System.os_time(:second)
      refute Pin.valid_grant?(%{"stamp" => stamp, "until" => now - 1})
      refute Pin.valid_grant?(%{"stamp" => stamp, "until" => now + 10 * 24 * 3600})
      refute Pin.valid_grant?(%{"stamp" => "AAAAAAAAAAAAAAAAAAAAAA==", "until" => now + 60})
      refute Pin.valid_grant?(%{"gen" => 1, "until" => now + 60})
      refute Pin.valid_grant?(nil)
    end

    test "may_change? is local, or a good grant" do
      {:ok, grant} = Pin.attempt("2468-hall", :peer)
      assert Local.may_change?(true, nil)
      assert Local.may_change?(false, grant)
      refute Local.may_change?(false, nil)
    end
  end

  describe "first start" do
    test "makes a six-digit PIN, and a restart keeps it" do
      dir = Path.join(System.tmp_dir!(), "arkab-pin-first-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      stop_supervised!(Bridge)

      start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})
      pin = Pin.current()
      assert pin =~ ~r/\A\d{6}\z/
      assert File.read!(Path.join(dir, "access-pin")) == pin <> "\n"
      refute Pin.notice?(), "nothing was retired, so nothing to say"

      stop_supervised!(Bridge)
      start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})
      assert Pin.current() == pin
    end

    test "an old PIN hash is retired, a new PIN made, and the page says so once" do
      dir = Path.join(System.tmp_dir!(), "arkab-pin-old-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      stop_supervised!(Bridge)

      # The old version's bridge, with a hashed remote PIN.
      start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: false})

      Bridge.Store.put("remote_pin", %{
        "gen" => 3,
        "iter" => 1000,
        "salt" => "c2FsdA==",
        "hash" => "aGFzaA=="
      })

      stop_supervised!(Bridge)

      start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})
      assert Bridge.Store.get("remote_pin") == nil
      assert Pin.current() =~ ~r/\A\d{6}\z/
      assert Pin.notice?()

      {:ok, view, _html} = live(build_conn(), "/")
      assert has_element?(view, "#pin-notice")
      view |> element("#pin-notice-ok") |> render_click()
      refute has_element?(view, "#pin-notice")
      refute Pin.notice?()
    end

    test "a file that is a symlink is not the PIN" do
      dir = Path.join(System.tmp_dir!(), "arkab-pin-link-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      stop_supervised!(Bridge)
      File.mkdir_p!(dir)
      target = Path.join(dir, "elsewhere")
      File.write!(target, "sneaky-pin\n")

      case File.ln_s(target, Path.join(dir, "access-pin")) do
        :ok ->
          start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})
          assert Pin.current() =~ ~r/\A\d{6}\z/
          assert File.read!(target) == "sneaky-pin\n", "the link's target was not written"
          assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(dir, "access-pin"))

        {:error, _no_symlinks_here} ->
          :ok
      end
    end
  end

  describe "the lockout" do
    alias ArkabWeb.Pin.Throttle

    test "five free failures, then 5 s, doubling, capped at 15 minutes" do
      for _ <- 1..4, do: assert(:ok = Throttle.claim(:a, 1000))
      # The fifth guess is still heard; it starts the wait.
      assert :ok = Throttle.claim(:a, 1000)
      assert {:locked, 5} = Throttle.claim(:a, 1000)
      assert {:locked, 1} = Throttle.claim(:a, 1004)
      assert :ok = Throttle.claim(:a, 1005)
      assert {:locked, 10} = Throttle.claim(:a, 1005)
      assert :ok = Throttle.claim(:a, 1015)
      assert {:locked, 20} = Throttle.claim(:a, 1015)

      # Far enough along, the wait stops growing at 900 s.
      t =
        Enum.reduce(1..10, 1035, fn _, t ->
          :ok = Throttle.claim(:a, t)
          {:locked, wait} = Throttle.claim(:a, t)
          assert wait <= 900
          t + wait
        end)

      :ok = Throttle.claim(:a, t)
      assert {:locked, 900} = Throttle.claim(:a, t)
    end

    test "while an address waits, even the right PIN is refused; another address is not" do
      for _ <- 1..5, do: assert({:error, :wrong} = Pin.attempt("000000", :peer))
      assert {:error, {:locked, seconds}} = Pin.attempt("2468-hall", :peer)
      assert seconds in 1..5
      assert {:ok, _grant} = Pin.attempt("2468-hall", :other)
    end

    test "a right PIN clears the count" do
      for _ <- 1..4, do: Pin.attempt("000000", :peer)
      assert {:ok, _} = Pin.attempt("2468-hall", :peer)
      for _ <- 1..4, do: Pin.attempt("000000", :peer)
      assert {:ok, _} = Pin.attempt("2468-hall", :peer)
    end

    test "box-wide, 40 failures a minute; then everybody waits, the right PIN too" do
      for n <- 1..40, do: assert(:ok = Throttle.claim({:addr, n}, 2000 + rem(n, 10)))
      assert {:locked, 51} = Throttle.claim(:fresh, 2009)
      assert {:locked, 1} = Throttle.claim(:fresh, 2059)
      assert :ok = Throttle.claim(:fresh, 2060)
    end

    test "a right PIN's own claim is no failure for the box-wide count" do
      for n <- 1..60, do: assert({:ok, _} = Pin.attempt("2468-hall", {:addr, n}))
    end

    test "an address quiet for an hour is forgotten" do
      for _ <- 1..5, do: :ok = Throttle.claim(:a, 0)
      assert {:locked, 5} = Throttle.claim(:a, 0)
      # One failure more after an hour and a bit: counted as the first again.
      for _ <- 1..4, do: assert(:ok = Throttle.claim(:a, 3_700))
      assert :ok = Throttle.claim(:a, 3_700)
      assert {:locked, 5} = Throttle.claim(:a, 3_700)
    end

    test "fifty guesses at once still get five tries between them" do
      answers =
        1..50
        |> Task.async_stream(fn _ -> Pin.attempt("000000", :peer) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.count(answers, &(&1 == {:error, :wrong})) == 5

      assert Enum.all?(
               answers -- List.duplicate({:error, :wrong}, 5),
               &match?({:error, {:locked, _}}, &1)
             )
    end
  end

  describe "from another computer" do
    test "every page sends it to the unlock page first" do
      conn = build_conn() |> as(:lan) |> get("/")
      assert redirected_to(conn) == "/unlock"
      conn = build_conn() |> as(:lan) |> get("/help")
      assert redirected_to(conn) == "/unlock"

      assert {:error, {:redirect, %{to: "/unlock"}}} = live(as(build_conn(), :lan), "/")
    end

    test "the unlock page has a masked text field with a Show button, not a keypad" do
      conn = build_conn() |> as(:lan) |> get("/unlock")
      doc = conn |> html_response(200) |> LazyHTML.from_document()

      field = LazyHTML.query(doc, "#unlock-form input#pin")
      assert LazyHTML.attribute(field, "type") == ["password"]
      assert LazyHTML.attribute(field, "maxlength") == ["64"]
      assert LazyHTML.attribute(field, "inputmode") == []
      assert LazyHTML.attribute(LazyHTML.query(doc, "#pin-show"), "data-reveal") == ["pin"]
    end

    test "a wrong PIN is refused and gives nothing" do
      conn = unlock(:lan, "111111")
      assert html_response(conn, 403) =~ "not the PIN"
      assert {:error, {:redirect, %{to: "/unlock"}}} = open(conn, :lan)
    end

    test "the right PIN gives the page and its controls, but not the PIN" do
      id = joined_server()

      conn = unlock(:lan, "2468-hall")
      assert redirected_to(conn) == "/"

      {:ok, view, html} = open(conn, :lan)
      assert has_element?(view, "#unlocked")
      assert has_element?(view, "#join-form")
      assert has_element?(view, "#remove-#{id}")
      refute has_element?(view, "#pin"), "the PIN is shown and changed on the bridge only"
      refute html =~ "2468-hall"

      render_click(view, "remove", %{"id" => to_string(id)})
      assert Bridge.Store.servers() == []
    end

    test "locking again takes the grant away" do
      conn = unlock(:lan, "2468-hall")
      conn = conn |> recycle() |> as(:lan) |> get("/lock")
      assert redirected_to(conn) == "/"
      assert {:error, {:redirect, %{to: "/unlock"}}} = open(conn, :lan)
    end

    test "a grant does not let a browser change the PIN" do
      conn = unlock(:lan, "2468-hall")
      {:ok, view, _html} = open(conn, :lan)

      render_submit(view, "pin_set", %{"pin" => "999999"})
      render_click(view, "pin_new", %{})

      assert Pin.current() == "2468-hall"
    end

    test "changing the PIN sends an open page back to the door" do
      id = joined_server()
      conn = unlock(:lan, "2468-hall")
      {:ok, view, _html} = open(conn, :lan)
      assert has_element?(view, "#join-form")

      :ok = Pin.set("1357-hall")
      render_click(view, "remove", %{"id" => to_string(id)})

      assert [%{id: ^id}] = Bridge.Store.servers()
      assert_redirect(view, "/unlock")
    end

    test "and the next tick does the same for a page that does nothing" do
      conn = unlock(:lan, "2468-hall")
      {:ok, view, _html} = open(conn, :lan)
      {:ok, _pin} = Pin.new_random()
      send(view.pid, :refresh)
      assert_redirect(view, "/unlock")
    end

    test "an old grant opens nothing after a change" do
      conn = unlock(:lan, "2468-hall")
      :ok = Pin.set("1357-hall")
      assert {:error, {:redirect, %{to: "/unlock"}}} = open(conn, :lan)
    end

    test "five wrong tries in the page make the address wait, the right PIN too" do
      for _ <- 1..5, do: unlock(:lan, "000000")
      conn = unlock(:lan, "2468-hall")
      assert html_response(conn, 429) =~ ~r/Wait \d seconds/
      assert {:error, {:redirect, %{to: "/unlock"}}} = open(conn, :lan)
    end

    test "a post without the CSRF token is refused" do
      assert_error_sent 403, fn ->
        build_conn()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> as(:lan)
        |> post("/unlock", %{"pin" => "2468-hall"})
      end
    end
  end

  describe "behind a proxy on loopback" do
    test "is not this machine, but can unlock with the PIN" do
      id = joined_server()

      assert {:error, {:redirect, %{to: "/unlock"}}} = live(as(build_conn(), :proxied), "/")

      conn = unlock(:proxied, "2468-hall")
      assert redirected_to(conn) == "/"
      {:ok, view, _html} = open(conn, :proxied)
      assert has_element?(view, "#remove-#{id}")
      refute has_element?(view, "#pin"), "still not local: no PIN management"
    end
  end

  describe "this machine" do
    test "is never asked for the PIN" do
      conn = get(build_conn(), "/")
      assert html_response(conn, 200)
      assert {:ok, view, _html} = live(build_conn(), "/")
      refute has_element?(view, "#unlocked")
    end

    test "sees the PIN and changes it, with a Show toggle and no Remove", %{dir: dir} do
      {:ok, view, _html} = live(build_conn(), "/")
      assert has_element?(view, "#pin-current", "2468-hall")
      assert has_element?(view, "#pin-input[type=password]")
      assert has_element?(view, "#pin-input-show")
      refute has_element?(view, "#pin-remove")
      refute render(view) =~ ~r/remove pin/i

      view |> form("#pin-form", %{pin: "12345"}) |> render_submit()
      assert has_element?(view, "#pin-message.error", "at least 6")
      assert Pin.current() == "2468-hall"

      view |> form("#pin-form", %{pin: " 123456"}) |> render_submit()
      assert has_element?(view, "#pin-message.error", "space")

      view |> form("#pin-form", %{pin: "new hall pin"}) |> render_submit()
      assert has_element?(view, "#pin-message.ok")
      assert Pin.current() == "new hall pin"
      assert File.read!(Path.join(dir, "access-pin")) == "new hall pin\n"
      assert has_element?(view, "#pin-current", "new hall pin")
    end

    test "makes a new random PIN with one button" do
      {:ok, view, _html} = live(build_conn(), "/")
      view |> element("#pin-random") |> render_click()
      pin = Pin.current()
      assert pin =~ ~r/\A\d{6}\z/
      assert has_element?(view, "#pin-current", pin)
      assert has_element?(view, "#pin-message.ok")
    end
  end
end

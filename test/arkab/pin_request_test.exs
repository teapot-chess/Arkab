defmodule Arkab.PinRequestTest do
  @moduledoc """
  The PIN asked for on a box's SD card: a request file in the data directory,
  applied when the bridge starts and deleted either way, with `access-pin`
  holding the result for the box to read back. It is the only way to a PIN
  besides the bridge's own page, it must not be a way for anybody else, and
  it cannot take the PIN away.
  """

  use ExUnit.Case, async: false

  alias Arkab.{Bridge, PinRequest}
  alias ArkabWeb.Pin

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-pinreq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp request(dir, content), do: File.write!(Path.join(dir, PinRequest.file_name()), content)
  defp request_exists?(dir), do: File.exists?(Path.join(dir, PinRequest.file_name()))
  defp access_pin(dir), do: File.read!(Path.join(dir, "access-pin"))

  defp start_bridge(dir),
    do: start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})

  defp pin_works?(pin) do
    Pin.Throttle.reset()
    match?({:ok, _grant}, Pin.attempt(pin, {10, 0, 0, 9}))
  end

  test "a set request is applied when the bridge starts, and the file is gone", %{dir: dir} do
    request(dir, "set\nhall-2026\n")
    start_bridge(dir)

    assert pin_works?("hall-2026")
    refute pin_works?("hall-2027")
    assert access_pin(dir) == "hall-2026\n"
    refute request_exists?(dir)
  end

  test "a new request at the first start gives six digits, like no request", %{dir: dir} do
    request(dir, "new\n")
    start_bridge(dir)
    assert Pin.current() =~ ~r/\A\d{6}\z/
    assert access_pin(dir) == Pin.current() <> "\n"
    refute request_exists?(dir)
  end

  test "a PIN with spaces inside and symbols survives the file", %{dir: dir} do
    request(dir, "set\nde zaal #1 ok\r\n")
    start_bridge(dir)
    assert pin_works?("de zaal #1 ok")
  end

  test "setting it voids an old grant", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("first-pin")
    {:ok, grant} = Pin.attempt("first-pin", {10, 0, 0, 9})
    assert Pin.valid_grant?(grant)

    assert PinRequest.consume(dir) == :none
    request(dir, "set\nsecond-pin\n")
    assert PinRequest.consume(dir) == :set

    refute Pin.valid_grant?(grant)
    assert pin_works?("second-pin")
    assert access_pin(dir) == "second-pin\n"
  end

  test "new makes a fresh six-digit PIN, and voids an old grant", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("some-pin")
    {:ok, grant} = Pin.attempt("some-pin", {10, 0, 0, 9})
    request(dir, "new\n")

    assert PinRequest.consume(dir) == :new
    pin = Pin.current()
    assert pin =~ ~r/\A\d{6}\z/
    assert access_pin(dir) == pin <> "\n"
    refute Pin.valid_grant?(grant)
    refute request_exists?(dir)
  end

  test "remove is refused: the PIN stays", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("some-pin")

    for content <- ["remove\n", "remove", "remove\n\n"] do
      request(dir, content)
      assert PinRequest.consume(dir) == {:refused, :remove}
      assert pin_works?("some-pin")
      assert access_pin(dir) == "some-pin\n"
      refute request_exists?(dir)
    end
  end

  test "an empty PIN is refused, not a way to none", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("some-pin")
    request(dir, "set\n\n")
    assert PinRequest.consume(dir) == {:refused, :too_short}
    assert pin_works?("some-pin")
  end

  test "what breaks the rules is refused, the file is deleted anyway", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("kept-pin")

    request(dir, "set\n12345\n")
    assert PinRequest.consume(dir) == {:refused, :too_short}
    refute request_exists?(dir)

    request(dir, "set\n" <> String.duplicate("x", 65) <> "\n")
    assert PinRequest.consume(dir) == {:refused, :too_long}

    request(dir, "set\n kept-pin\n")
    assert PinRequest.consume(dir) == {:refused, :edge_space}

    request(dir, "set\nkept\tpin\n")
    assert PinRequest.consume(dir) == {:refused, :invisible}

    assert pin_works?("kept-pin")
    assert access_pin(dir) == "kept-pin\n"
  end

  test "a request nobody can read is refused and removed", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("kept-pin")

    for content <- ["please let me in\n", "", "new\nextra\n", "SET\nkept-pin2\n"] do
      request(dir, content)
      assert PinRequest.consume(dir) == {:refused, :unreadable}
      refute request_exists?(dir)
    end

    assert pin_works?("kept-pin")
  end

  test "no request file changes nothing", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("kept-pin")
    assert PinRequest.consume(dir) == :none
    assert pin_works?("kept-pin")
  end

  test "a symlink in its place is not followed", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("kept-pin")
    target = Path.join(dir, "elsewhere")
    File.write!(target, "set\nsneaky-pin\n")

    case File.ln_s(target, Path.join(dir, PinRequest.file_name())) do
      :ok ->
        assert PinRequest.consume(dir) == {:refused, :not_a_plain_file}
        refute pin_works?("sneaky-pin")
        assert pin_works?("kept-pin")
        refute request_exists?(dir)

      {:error, _no_symlinks_here} ->
        :ok
    end
  end

  test "the PIN is never written to the log", %{dir: dir} do
    start_bridge(dir)
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        request(dir, "set\nsecret-hall-pin\n")
        PinRequest.consume(dir)
        request(dir, "new\n")
        PinRequest.consume(dir)
      end)

    assert log =~ "Access PIN set"
    assert log =~ "a new random one"
    refute log =~ "secret-hall-pin"
    refute log =~ Pin.current()
  end
end

defmodule Arkab.PinRequestTest do
  @moduledoc """
  The PIN asked for on a box's SD card: a request file in the data directory,
  applied when the bridge starts and deleted either way. It is the only way
  to a PIN besides the bridge's own page, and it must not be a way for
  anybody else.
  """

  use ExUnit.Case, async: false

  require Logger

  alias Arkab.{Bridge, PinRequest}
  alias ArkabWeb.Pin

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-pinreq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:arkab, :pin_iterations, 1_000)

    on_exit(fn ->
      Application.delete_env(:arkab, :pin_iterations)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp request(dir, content), do: File.write!(Path.join(dir, PinRequest.file_name()), content)
  defp request_exists?(dir), do: File.exists?(Path.join(dir, PinRequest.file_name()))

  defp start_bridge(dir),
    do: start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})

  defp pin_works?(pin) do
    Pin.Throttle.reset()
    match?({:ok, _grant}, Pin.attempt(pin, {10, 0, 0, 9}))
  end

  test "a set request is applied when the bridge starts, and the file is gone", %{dir: dir} do
    request(dir, "set\nhall-2026\n")
    start_bridge(dir)
    _ = :sys.get_state(Bridge)

    assert Pin.set?()
    assert pin_works?("hall-2026")
    refute pin_works?("hall-2027")
    refute request_exists?(dir)
  end

  test "a PIN with spaces inside and symbols survives the file", %{dir: dir} do
    request(dir, "set\nde zaal #1 ok\r\n")
    start_bridge(dir)
    assert pin_works?("de zaal #1 ok")
  end

  test "setting it counts the generation up: an old grant is void", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("first-pin")
    {:ok, grant} = Pin.attempt("first-pin", {10, 0, 0, 9})
    assert Pin.valid_grant?(grant)

    assert PinRequest.consume(dir) == :none
    request(dir, "set\nsecond-pin\n")
    assert PinRequest.consume(dir) == :set

    refute Pin.valid_grant?(grant)
    assert pin_works?("second-pin")
  end

  test "remove takes the PIN away", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("some-pin")
    request(dir, "remove\n")

    assert PinRequest.consume(dir) == :removed
    refute Pin.set?()
    refute request_exists?(dir)
  end

  test "too short and too long are refused, the file is deleted anyway", %{dir: dir} do
    start_bridge(dir)

    request(dir, "set\n123\n")
    assert PinRequest.consume(dir) == {:refused, :too_short}
    refute Pin.set?()
    refute request_exists?(dir)

    request(dir, "set\n" <> String.duplicate("x", 65) <> "\n")
    assert PinRequest.consume(dir) == {:refused, :too_long}
    refute Pin.set?()
  end

  test "a request nobody can read is refused and removed", %{dir: dir} do
    start_bridge(dir)
    request(dir, "please let me in\n")
    assert PinRequest.consume(dir) == {:refused, :unreadable}
    refute Pin.set?()
    refute request_exists?(dir)
  end

  test "no request file changes nothing", %{dir: dir} do
    start_bridge(dir)
    :ok = Pin.set("kept-pin")
    assert PinRequest.consume(dir) == :none
    assert pin_works?("kept-pin")
  end

  test "a symlink in its place is not followed", %{dir: dir} do
    start_bridge(dir)
    target = Path.join(dir, "elsewhere")
    File.write!(target, "set\nsneaky-pin\n")

    case File.ln_s(target, Path.join(dir, PinRequest.file_name())) do
      :ok ->
        assert PinRequest.consume(dir) == {:refused, :not_a_plain_file}
        refute Pin.set?()
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
    request(dir, "set\nsecret-hall-pin\n")

    log = ExUnit.CaptureLog.capture_log(fn -> PinRequest.consume(dir) end)

    assert log =~ "Remote PIN set"
    refute log =~ "secret-hall-pin"
  end
end

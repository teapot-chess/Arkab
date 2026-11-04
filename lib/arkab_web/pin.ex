defmodule ArkabWeb.Pin do
  @moduledoc """
  The access PIN: what a phone or laptop on the hall's network has to give
  before it sees anything of this bridge. There is always one.

  It lives in plaintext in `<data>/access-pin`, one line, mode 0600, written
  atomically (a fresh `access-pin.new`, then a rename over the old one; a
  symlink at either name is never followed). The file is the single source
  of truth: the Pi image's box reads it to show the PIN on its own screen and
  to copy it to the SD card, and never writes it. A plaintext PIN because it
  has to be shown, on the bridge's own page and on the box; a hash cannot be.
  It is kept in memory after it is read, and read again after every write.
  The PIN is never logged, never put in a URL or a cookie.

  At start (`Arkab.PinRequest`, before the page answers) the file is read,
  the box's request applied, and a PIN that is still missing made: six
  random digits. The old PBKDF2 hash of the optional remote PIN (Store
  setting `remote_pin`) is retired then, and if that is what made a new PIN
  necessary, the bridge's own page says so once (`notice?/0`).

  A right PIN is answered with a *grant* for the Phoenix session cookie
  (signed and encrypted): a stamp of the PIN, keyed with the page's
  secret_key_base, and a deadline twelve hours away. A grant is good while
  its stamp is the current PIN's, so any change of the PIN voids every grant
  at once; the page asks again every second and before every change
  (`ArkabWeb.Local.may_change?/2`).

  A PIN has 6 to 64 characters, printable ones, and no space at either end
  (`validate/1`). Guesses are throttled per peer address and for the box as
  a whole (`ArkabWeb.Pin.Throttle`).
  """

  require Logger

  alias Arkab.Bridge.Store
  alias ArkabWeb.Pin.Throttle

  @file_name "access-pin"
  @legacy_setting "remote_pin"
  @notice_setting "pin_notice"
  @min_length 6
  @max_length 64
  @grant_seconds 12 * 3600
  @session_key "pin_grant"
  @term {__MODULE__, :state}

  def min_length, do: @min_length
  def max_length, do: @max_length
  def session_key, do: @session_key
  def grant_seconds, do: @grant_seconds
  def file_name, do: @file_name

  @type problem :: :too_short | :too_long | :edge_space | :invisible

  # --- start-up --------------------------------------------------------------

  @doc """
  Reads `<data_dir>/access-pin` into memory and retires the old hash. Returns
  whether there was an old hash. The first half of the start-up step; the
  request file comes next, `ensure/1` last.
  """
  @spec load(Path.t()) :: boolean()
  def load(data_dir) do
    :persistent_term.put(@term, %{dir: data_dir, pin: read_file(data_dir)})
    retire_legacy()
  end

  @doc """
  Makes a PIN if there is still none: six random digits. `legacy?` says an
  old hash was retired; a PIN made in its place earns the one-time notice.
  """
  @spec ensure(boolean()) :: :ok
  def ensure(legacy? \\ false) do
    if current() == nil do
      {:ok, _pin} = new_random()
      if legacy?, do: put_setting(@notice_setting, true)
      Logger.info("Access PIN made: there was none.")
    end

    :ok
  end

  # --- the PIN -----------------------------------------------------------------

  @doc "The PIN now, or nil before start-up (a library, a test without a bridge)."
  @spec current() :: String.t() | nil
  def current do
    case :persistent_term.get(@term, nil) do
      %{pin: pin} -> pin
      nil -> nil
    end
  end

  @doc "Whether `pin` may be a PIN: `:ok` or `{:error, problem}`."
  @spec validate(term()) :: :ok | {:error, problem()}
  def validate(pin) when is_binary(pin) do
    cond do
      not String.valid?(pin) -> {:error, :invisible}
      String.length(pin) < @min_length -> {:error, :too_short}
      String.length(pin) > @max_length -> {:error, :too_long}
      String.trim(pin) != pin -> {:error, :edge_space}
      pin |> String.to_charlist() |> Enum.any?(&control?/1) -> {:error, :invisible}
      true -> :ok
    end
  end

  def validate(_other), do: {:error, :too_short}

  defp control?(c), do: c < 32 or c in 127..159

  @doc "Sets (changes) the PIN. Every grant made before is void."
  @spec set(String.t()) :: :ok | {:error, problem() | :unwritable}
  def set(pin) do
    with :ok <- validate(pin), do: write(pin)
  end

  @doc "A fresh random PIN of six digits: `{:ok, pin}`. Every grant made before is void."
  @spec new_random() :: {:ok, String.t()} | {:error, :unwritable}
  def new_random do
    pin = random_digits()

    case write(pin) do
      :ok -> {:ok, pin}
      error -> error
    end
  end

  @doc "Six digits from 8 random bytes: 2^64 mod 10^6 leaves a bias of about 10^-13."
  @spec random_digits() :: String.t()
  def random_digits do
    <<n::unsigned-64>> = :crypto.strong_rand_bytes(8)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  # --- the one-time notice ------------------------------------------------------

  @doc "Whether the page still has to say that a new PIN replaced the old hash."
  @spec notice?() :: boolean()
  def notice?, do: get_setting(@notice_setting) == true

  @doc "The notice was read."
  def dismiss_notice, do: put_setting(@notice_setting, nil)

  # --- guesses and grants --------------------------------------------------------

  @doc """
  A guess from `peer` (the socket's address). `{:ok, grant}` for the right
  PIN, `{:error, :wrong}`, or `{:error, {:locked, seconds}}` while the peer
  or the box has to wait (even a right PIN does not get in then).
  """
  @spec attempt(String.t(), term()) ::
          {:ok, map()} | {:error, :wrong | {:locked, pos_integer()}}
  def attempt(guess, peer) when is_binary(guess) do
    case Throttle.claim(peer) do
      :ok ->
        pin = current()

        if is_binary(pin) and Plug.Crypto.secure_compare(guess, pin) do
          Throttle.clear(peer)
          {:ok, %{"stamp" => stamp(pin), "until" => now() + @grant_seconds}}
        else
          {:error, :wrong}
        end

      {:locked, seconds} ->
        {:error, {:locked, seconds}}
    end
  end

  def attempt(_guess, _peer), do: {:error, :wrong}

  @doc "Whether a grant (from the session) is good now: the current PIN's stamp, not expired."
  @spec valid_grant?(term()) :: boolean()
  def valid_grant?(%{"stamp" => stamp, "until" => until})
      when is_binary(stamp) and is_integer(until) do
    case current() do
      pin when is_binary(pin) ->
        Plug.Crypto.secure_compare(stamp, stamp(pin)) and now() < until and
          until - now() <= @grant_seconds

      nil ->
        false
    end
  end

  def valid_grant?(_other), do: false

  # The first 16 bytes of HMAC-SHA256(secret_key_base, "access-pin:" <> pin):
  # useless to anybody without the page's secret, and a different one for
  # every PIN.
  defp stamp(pin) do
    key = Application.get_env(:arkab, ArkabWeb.Endpoint, [])[:secret_key_base] || ""

    :crypto.mac(:hmac, :sha256, key, "access-pin:" <> pin)
    |> binary_part(0, 16)
    |> Base.encode64()
  end

  # --- the file --------------------------------------------------------------

  defp write(pin) do
    case :persistent_term.get(@term, nil) do
      %{dir: dir} = state ->
        case write_file(dir, pin) do
          :ok ->
            :persistent_term.put(@term, %{state | pin: read_file(dir)})
            :ok

          {:error, reason} ->
            Logger.error("Access PIN: could not write the file (#{inspect(reason)}).")
            {:error, :unwritable}
        end

      nil ->
        {:error, :unwritable}
    end
  end

  # Empty and private first, the PIN after: there is no moment at which it
  # sits in a file somebody else may read. A symlink at `.new` is removed,
  # not followed, and `:exclusive` refuses anything that comes back in its
  # place; the rename replaces whatever stands at `access-pin`, a symlink
  # included, without following it. On Windows chmod does nothing and the
  # profile folder's own rights do the job.
  defp write_file(dir, pin) do
    path = Path.join(dir, @file_name)
    tmp = path <> ".new"
    _ = File.rm(tmp)

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         _ <- File.chmod(tmp, 0o600),
         :ok <- IO.binwrite(io, pin <> "\n"),
         :ok <- File.close(io),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  # Only a regular file, and only a valid PIN; anything else is no PIN.
  defp read_file(dir) do
    path = Path.join(dir, @file_name)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, content} <- File.read(path),
         pin = content |> String.trim_trailing("\n") |> String.trim_trailing("\r"),
         :ok <- validate(pin) do
      pin
    else
      _no_pin -> nil
    end
  end

  # --- the old hash --------------------------------------------------------------

  defp retire_legacy do
    case get_setting(@legacy_setting) do
      %{"hash" => _} ->
        put_setting(@legacy_setting, nil)
        Logger.info("Access PIN: the old remote PIN hash is retired.")
        true

      %{} ->
        put_setting(@legacy_setting, nil)
        false

      _none ->
        false
    end
  end

  # Not running (a library, a test): no settings.
  defp get_setting(name) do
    Store.get(name)
  catch
    :exit, _reason -> nil
  end

  defp put_setting(name, value) do
    Store.put(name, value)
  catch
    :exit, _reason -> :ok
  end

  defp now, do: System.os_time(:second)
end

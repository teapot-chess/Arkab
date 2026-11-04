defmodule Arkab.PinRequest do
  @moduledoc """
  The access PIN's start-up step, and the box's way to ask for a PIN without
  a browser: for a box with no screen and no keyboard.

  On the Pi image the boot partition carries a text file the organiser fills
  in on a PC. At boot a root-run step on the box checks it and leaves a
  *request file*, `pin-request`, in this program's data directory (mode 0600,
  owner the user Arkab runs as). When the bridge starts, before the page
  answers, this reads `access-pin` (`ArkabWeb.Pin.load/1`), applies the
  request and deletes it whatever came of it, and makes a PIN if there is
  still none (`ArkabWeb.Pin.ensure/1`). The box reads `access-pin` back.

  Nothing here listens, and nothing a visitor can send reaches it: the file
  is in a directory only the box's own accounts can write to, which is the
  same standard as "set from the machine itself" for the page. Only a
  regular file is read; a symlink or anything else in its place is deleted
  unread.

  The file is

      set
      the-pin

  (the PIN must pass `ArkabWeb.Pin.validate/1`, or the current one stays) or
  just `new` (six fresh random digits). Anything else is refused, the old
  `remove` included: there is always a PIN. The PIN is never logged, here or
  anywhere the request passes through.
  """

  require Logger

  alias ArkabWeb.Pin

  @file_name "pin-request"

  @doc false
  def child_spec(data_dir),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [data_dir]}, restart: :temporary}

  # A supervisor child that does its work while it is being started, so that
  # the page does not answer before the PIN is what the card said, and then
  # is not there (`:ignore`).
  @doc false
  def start_link(data_dir) do
    legacy? = Pin.load(data_dir)
    consume(data_dir)
    Pin.ensure(legacy?)
    :ignore
  end

  @doc "The request file's name inside the data directory."
  def file_name, do: @file_name

  @doc """
  Applies the request in `data_dir`, if there is one, and deletes it.
  Returns `:none` without one, otherwise what became of it: `:set`, `:new`,
  or `{:refused, reason}`.
  """
  @spec consume(Path.t()) :: :none | :set | :new | {:refused, atom()}
  def consume(data_dir) do
    path = Path.join(data_dir, @file_name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        result = path |> File.read() |> apply_request()
        File.rm(path)
        report(result)
        result

      {:ok, _symlink_or_worse} ->
        File.rm(path)
        report({:refused, :not_a_plain_file})
        {:refused, :not_a_plain_file}

      {:error, _no_file} ->
        :none
    end
  end

  defp apply_request({:ok, content}) do
    case String.split(content, "\n", parts: 2) do
      [set, rest] when set in ["set", "set\r"] ->
        set_pin(rest |> String.trim_trailing("\n") |> String.trim_trailing("\r"))

      [new, rest] when new in ["new", "new\r"] and rest in ["", "\n"] ->
        new_pin()

      ["new"] ->
        new_pin()

      ["remove" <> _ | _] ->
        {:refused, :remove}

      _unknown ->
        {:refused, :unreadable}
    end
  end

  defp apply_request({:error, _reason}), do: {:refused, :unreadable}

  defp set_pin(pin) do
    case Pin.set(pin) do
      :ok -> :set
      {:error, reason} -> {:refused, reason}
    end
  end

  defp new_pin do
    case Pin.new_random() do
      {:ok, _pin} -> :new
      {:error, reason} -> {:refused, reason}
    end
  end

  defp report(:set), do: Logger.info("Access PIN set from the request file.")
  defp report(:new), do: Logger.info("Access PIN: a new random one, from the request file.")

  defp report({:refused, :remove}),
    do:
      Logger.warning(
        "Access PIN request refused (remove: there is always a PIN); the request file is gone."
      )

  defp report({:refused, reason}),
    do: Logger.warning("Access PIN request refused (#{reason}); the request file is gone.")
end

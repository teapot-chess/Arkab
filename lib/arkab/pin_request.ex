defmodule Arkab.PinRequest do
  @moduledoc """
  A remote PIN asked for from outside the web page: the one way in that does
  not need a browser, for a box with no screen and no keyboard.

  On the Pi image the boot partition carries a text file the organiser fills
  in on a PC. At boot a root-run step on the box checks it and leaves a
  *request file*, `pin-request`, in this program's data directory (mode 0600,
  owner the user Arkab runs as). `consume/1` reads it when the bridge starts,
  applies it and deletes it, whatever came of it.

  Nothing here listens, and nothing a visitor can send reaches it: the file
  is in a directory only the box's own accounts can write to, which is the
  same standard as "set from the machine itself" for the page. A symlink in
  its place is not read.

  The file is two lines at most:

      set
      the-pin

  or just `remove`. The PIN is never logged, here or anywhere the request
  passes through.
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
    consume(data_dir)
    :ignore
  end

  @doc "The request file's name inside the data directory."
  def file_name, do: @file_name

  @doc """
  Applies the request in `data_dir`, if there is one, and deletes it.
  Returns `:none` without one, otherwise what became of it: `:set`,
  `:removed`, or `{:refused, reason}`.
  """
  @spec consume(Path.t()) :: :none | :set | :removed | {:refused, atom()}
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
      ["remove" <> _, _rest] -> remove_pin()
      ["remove"] -> remove_pin()
      ["set", rest] -> set_pin(rest |> String.trim_trailing("\n") |> String.trim_trailing("\r"))
      _unknown -> {:refused, :unreadable}
    end
  end

  defp apply_request({:error, _reason}), do: {:refused, :unreadable}

  defp set_pin(pin) do
    case Pin.set(pin) do
      :ok -> :set
      {:error, reason} -> {:refused, reason}
    end
  end

  defp remove_pin do
    Pin.remove()
    :removed
  end

  defp report(:set), do: Logger.info("Remote PIN set from the request file.")
  defp report(:removed), do: Logger.info("Remote PIN removed from the request file.")

  defp report({:refused, reason}),
    do: Logger.warning("Remote PIN request refused (#{reason}); the request file is gone.")
end

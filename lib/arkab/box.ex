defmodule Arkab.Box do
  @moduledoc """
  The rest of what a Pi image's own setup server (`alnasl-setup`, 127.0.0.1:4041
  and nowhere else) offers the status page, besides "Get help" (`Arkab.Help`):
  which system image the box runs and whether a later train is on offer, the
  upgrade to it, and the box's mode (master or slave).

  Arkab only presses its buttons over loopback; the setup server downloads,
  checks, writes and restarts. Only where that server exists
  (`available?/0`, the same test as for Get help); on a PC or a Mac the page
  draws none of this. The address and the HTTP options come from the same
  settings as `Arkab.Help` (`:help_api`, `:help_req_options`, `:help_available`),
  so a test stands in for all of it at once.

  Answers are plain maps with atom keys, or `{:error, reason}`:

    * `system/0` - `%{train: "v6", version: "6.0", slot: "A", phase: "idle",
      progress: nil | 0..100, busy?: false, updates_on?: true, request_error:
      nil | "round_in_progress", offer: nil | %{train: "v7", version: "7.0",
      size: 123, notes: ""}, offer_blocked: nil | "6.2"}`
    * `upgrade/1` - `:ok`, or `{:error, :busy | :updates_off | :not_ab |
      :bad_train | :unavailable | :server_error}`
    * `mode/0` - `{:ok, "master" | "slave"}`
    * `switch_mode/1` - `:ok` (the box restarts a moment later)
  """

  alias Arkab.Help

  @default_api "http://127.0.0.1:4041"

  @upgrade_errors %{
    "busy" => :busy,
    "updates_off" => :updates_off,
    "not_ab" => :not_ab,
    "bad_train" => :bad_train
  }

  @doc "Is there a setup server on this machine to ask?"
  def available?, do: Help.available?()

  @doc "Everything the page draws from, in one go: `{:ok, %{system: ..., mode: \"master\" | \"slave\" | nil}}`."
  def snapshot do
    # An older image has no /api/mode: the upgrade card still draws, only "Switch to master" does not.
    with {:ok, system} <- system() do
      mode =
        case mode() do
          {:ok, mode} -> mode
          {:error, _reason} -> nil
        end

      {:ok, %{system: system, mode: mode}}
    end
  end

  @doc "The image the box runs and its update state (`GET /api/system`)."
  def system do
    case get("/api/system") do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, system_map(body)}
      _other -> {:error, :unavailable}
    end
  end

  @doc "Asks for the upgrade to `train` (`\"v7\"`), the way the box's own menu does."
  def upgrade(train) when is_binary(train) do
    body = %{"train" => train, "confirm" => "UPGRADE", "by" => "arkab"}

    case post("/api/system/upgrade", body) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      {:ok, %{status: 400, body: %{"error" => key}}} ->
        {:error, Map.get(@upgrade_errors, key, :server_error)}

      {:ok, _other} ->
        {:error, :server_error}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc "`{:ok, \"master\" | \"slave\"}` (`GET /api/mode`)."
  def mode do
    case get("/api/mode") do
      {:ok, %{status: 200, body: %{"mode" => mode}}} when mode in ["master", "slave"] ->
        {:ok, mode}

      _other ->
        {:error, :unavailable}
    end
  end

  @doc "Switches the box to `\"master\"` or `\"slave\"`; it restarts a moment later."
  def switch_mode(mode) when mode in ["master", "slave"] do
    case post("/api/mode", %{"mode" => mode, "confirm" => "SWITCH", "by" => "arkab"}) do
      {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
      {:ok, _other} -> {:error, :server_error}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp system_map(body) do
    %{
      train: text(body["train"]),
      version: text(body["version"]),
      slot: text(body["slot"]),
      phase: text(body["phase"]) || "idle",
      progress: percent(body["progress"]),
      busy?: body["busy"] == true,
      updates_on?: body["updates_on"] == true,
      off_reason: text(body["off_reason"]),
      request_error: text(body["request_error"]),
      offer: offer(body["offer"]),
      offer_blocked: text(body["offer_blocked"])
    }
  end

  defp offer(%{"train" => train, "version" => version} = o)
       when is_binary(train) and is_binary(version) do
    %{train: train, version: version, size: o["size"], notes: text(o["notes"]) || ""}
  end

  defp offer(_none), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil

  defp percent(n) when is_number(n), do: n |> round() |> max(0) |> min(100)
  defp percent(_other), do: nil

  defp get(path), do: Req.get(api() <> path, options([]))

  # The setup server wants its own header on every POST, and answers only to
  # its own Host; both are what a request to 127.0.0.1:4041 carries.
  defp post(path, body),
    do: Req.post(api() <> path, options(json: body, headers: [{"x-alnasl-setup", "1"}]))

  defp api, do: Application.get_env(:arkab, :help_api, @default_api)

  defp options(extra) do
    Keyword.merge(
      [retry: false, redirect: false, receive_timeout: 10_000, connect_options: [timeout: 3_000]] ++
        extra,
      Application.get_env(:arkab, :help_req_options, [])
    )
  end
end

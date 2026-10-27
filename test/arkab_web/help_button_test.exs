defmodule ArkabWeb.HelpButtonTest do
  @moduledoc "The Get help button: drawn only where the box's setup server is, and shows the code or why not."

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Arkab.{Bridge, Help}

  @endpoint ArkabWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "arkab-help-#{System.unique_integer([:positive])}")
    start_supervised!({Bridge, data_dir: dir, name: "hall", sources: [], web: true})

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:arkab, :help_available)
      Application.delete_env(:arkab, :help_req_options)
    end)

    :ok
  end

  defp answer(body) do
    Application.put_env(:arkab, :help_available, true)

    Application.put_env(:arkab, :help_req_options,
      plug: fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-alnasl-setup") == ["1"]
        assert conn.request_path == "/api/help/send"
        Req.Test.json(conn, body)
      end
    )
  end

  test "no button where there is no setup server" do
    Application.put_env(:arkab, :help_available, false)
    {:ok, view, _html} = live(build_conn(), "/")
    refute has_element?(view, "#help")
  end

  test "shows the code, spaced, and when it stops being valid" do
    answer(%{"ok" => true, "code" => "123456", "expires_at" => "2099-01-02T03:04:05Z"})
    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "#help-send")

    view |> element("#help-send") |> render_click()
    render_async(view, 5_000)

    assert has_element?(view, "#help-code", "123 456")
    assert has_element?(view, "#help-result", "2099-01-02 03:04 UTC")
  end

  test "each failure has its own sentence" do
    for {key, sentence} <- [
          {"no_internet", "could not reach the internet"},
          {"rate_limited", "in an hour"},
          {"support_off", "switched off"},
          {"too_large", "too large"}
        ] do
      answer(%{"ok" => false, "error" => key})
      {:ok, view, _html} = live(build_conn(), "/")
      view |> element("#help-send") |> render_click()
      render_async(view, 5_000)
      assert has_element?(view, "#help-error", sentence)
    end
  end

  test "Help.request/0 maps an unknown key to a server error" do
    answer(%{"ok" => false, "error" => "whatever"})
    assert Help.request() == {:error, :server_error}
  end
end

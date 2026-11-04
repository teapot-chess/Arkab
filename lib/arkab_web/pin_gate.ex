defmodule ArkabWeb.PinGate do
  @moduledoc """
  The door in front of every page: this machine walks in (`ArkabWeb.Local`),
  everybody else needs a valid access-PIN grant (`ArkabWeb.Pin`) and is sent
  to `/unlock` without one. There are no public pages: the status page and
  the manual alike. What stays outside is what has its own rules: the
  static files, the language switch, `/unlock` and `/lock` themselves, and
  the launcher's Details endpoint (this machine and a secret).

  Twice, like the local check: as a plug for the page's HTTP request and as
  an `on_mount` for its LiveView socket, which a browser can open without
  ever having loaded the page.
  """

  @behaviour Plug

  import Plug.Conn

  alias ArkabWeb.{Local, Pin}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Local.may_change?(Local.local_conn?(conn), get_session(conn, Pin.session_key())) do
      conn
    else
      conn |> Phoenix.Controller.redirect(to: "/unlock") |> halt()
    end
  end

  @doc "`on_mount` for the LiveViews: the same door for the socket."
  def on_mount(:default, _params, session, socket) do
    session = session || %{}

    if Local.may_change?(Local.local_socket?(socket, session), session[Pin.session_key()]) do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/unlock")}
    end
  end
end

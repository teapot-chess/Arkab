defmodule ArkabWeb.Router do
  use ArkabWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ArkabWeb.Layouts, :root}
    plug ArkabWeb.Locale
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ArkabWeb.Local
  end

  pipeline :pin do
    plug ArkabWeb.PinGate
  end

  scope "/", ArkabWeb do
    pipe_through :browser
    post "/lang/:code", LangController, :set
    get "/unlock", PinController, :show
    post "/unlock", PinController, :unlock
    post "/lock", PinController, :lock
  end

  # Every page behind the access PIN: this machine, or a browser that gave it.
  scope "/", ArkabWeb do
    pipe_through [:browser, :pin]

    live_session :default,
      on_mount: [{ArkabWeb.Locale, :default}, {ArkabWeb.PinGate, :default}] do
      live "/", StatusLive, :index
      live "/help", HelpLive, :index
    end
  end
end

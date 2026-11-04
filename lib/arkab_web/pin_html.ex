defmodule ArkabWeb.PinHTML do
  @moduledoc """
  The unlock page: one text field, masked, with a Show button, in the
  visitor's language. A PIN may be letters and spaces too, so no numeric
  keypad. The page is not a LiveView, so the Show button is wired in
  `priv/static/app.js` (`data-reveal`), not by a JS command.
  """

  use Phoenix.Component

  import ArkabWeb.Components, only: [foot: 1, logo: 1]

  alias ArkabWeb.{Pin, Words}

  def unlock(assigns) do
    # Called by the controller with a plain map, hence no `assign/3`.
    assigns =
      Map.merge(assigns, %{
        __changed__: nil,
        token: Plug.CSRFProtection.get_csrf_token(),
        max: Pin.max_length()
      })

    ~H"""
    <main id="bridge">
      <header>
        <h1><.logo /> Arkab</h1>
      </header>

      <section id="unlock">
        <h2>{Words.t(@locale, :unlock_title)}</h2>

        <p>{Words.t(@locale, :unlock_intro)}</p>

        <form id="unlock-form" method="post" action="/unlock">
          <input type="hidden" name="_csrf_token" value={@token} />
          <input
            id="pin"
            type="password"
            name="pin"
            autocomplete="current-password"
            autocapitalize="off"
            spellcheck="false"
            maxlength={@max}
            aria-label={Words.t(@locale, :pin_label)}
            placeholder={Words.t(@locale, :pin_label)}
            required
            autofocus
          />
          <button id="pin-show" type="button" data-reveal="pin">
            {Words.t(@locale, :pin_show)}
          </button>
          <button id="unlock-button" type="submit">{Words.t(@locale, :unlock)}</button>
        </form>

        <p :if={@error == :wrong} id="pin-error" class="error">{Words.t(@locale, :pin_wrong)}</p>

        <p :if={match?({:locked, _}, @error)} id="pin-error" class="error">
          {Words.t(@locale, :pin_locked, seconds: elem(@error, 1))}
        </p>

        <p class="note">{Words.t(@locale, :unlock_where)}</p>

        <p class="note">{Words.t(@locale, :pin_plain)}</p>
      </section>
      <.foot locale={@locale} page={:unlock} />
    </main>
    """
  end
end

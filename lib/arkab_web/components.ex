defmodule ArkabWeb.Components do
  @moduledoc "The little the two pages share: the foot with the help link and the language."

  use Phoenix.Component

  alias ArkabWeb.Words

  @doc "The mark (`ArkabWeb.Logo`): decorative, the name beside it says what it is."
  attr :class, :any, default: nil

  def logo(assigns) do
    assigns = assign(assigns, :inner, Phoenix.HTML.raw(ArkabWeb.Logo.inner()))

    ~H"""
    <svg class={["logo", @class]} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      {@inner}
    </svg>
    """
  end

  attr :locale, :string, required: true
  attr :page, :atom, values: [:status, :help, :unlock], required: true

  def foot(assigns) do
    ~H"""
    <footer id="foot" class="foot">
      <a :if={@page == :status} id="help-link" href="/help">{Words.t(@locale, :help)}</a>
      <a :if={@page == :help} id="back-link" href="/">{Words.t(@locale, :back)}</a>
      <span class="note">{Words.t(@locale, :language)}:</span>
      <.form
        :for={code <- ~w(en nl)}
        for={%{}}
        id={"lang-form-#{code}"}
        action={"/lang/#{code}"}
        method="post"
        class="lang"
      >
        <button id={"lang-#{code}"} type="submit" aria-current={to_string(@locale == code)}>
          {String.upcase(code)}
        </button>
      </.form>
    </footer>
    """
  end
end

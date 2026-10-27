defmodule Arkab.Help do
  @moduledoc """
  "Get help" on a Pi image: asks the box's own setup server to send the
  diagnostics to the support address and hands back the code it gets.

  The setup server (`alnasl-setup`, listening on 127.0.0.1:4041 and nowhere
  else) builds the report, strips passphrases and keys, posts it over HTTPS and
  keeps the address; this module only presses its button over loopback. Nothing
  here listens, nothing is sent from Arkab itself.

  Only offered where that server exists: the Pi image. Anywhere else
  (`available?/0` false) the page shows no button. The API's address is
  `config :arkab, :help_api` and its presence check `:help_available`, and `:help_req_options` reaches Req, so a
  test can stand in for all three.
  """

  @default_api "http://127.0.0.1:4041"
  @setup_server "/usr/local/lib/alnasl-setup/server.py"

  # What the setup server's error keys become here. Unknown keys are a server error.
  @errors %{
    "no_internet" => :no_internet,
    "rate_limited" => :rate_limited,
    "support_off" => :support_off,
    "too_large" => :too_large,
    "rejected" => :rejected,
    "server_error" => :server_error
  }

  @doc "Is there a setup server on this machine to ask?"
  def available? do
    case Application.fetch_env(:arkab, :help_available) do
      {:ok, value} -> value == true
      :error -> File.exists?(@setup_server)
    end
  end

  @doc """
  Sends the report. `{:ok, %{code: "123456", expires_at: "..."}}`, or
  `{:error, reason}` with reason one of `:no_internet`, `:rate_limited`,
  `:support_off`, `:too_large`, `:rejected`, `:server_error`, or
  `:unavailable` when the setup server itself does not answer.
  """
  def request do
    api = Application.get_env(:arkab, :help_api, @default_api)

    # The setup server wants its own header on every POST, and answers only
    # to its own Host; both are what a request to 127.0.0.1:4041 carries.
    options =
      Keyword.merge(
        [
          json: %{},
          headers: [{"x-alnasl-setup", "1"}],
          retry: false,
          redirect: false,
          receive_timeout: 45_000,
          connect_options: [timeout: 3_000]
        ],
        Application.get_env(:arkab, :help_req_options, [])
      )

    case Req.post(api <> "/api/help/send", options) do
      {:ok, %{status: 200, body: %{"ok" => true, "code" => code, "expires_at" => expires}}}
      when is_binary(code) and is_binary(expires) ->
        {:ok, %{code: code, expires_at: expires}}

      {:ok, %{status: 200, body: %{"ok" => false, "error" => key}}} ->
        {:error, Map.get(@errors, key, :server_error)}

      {:ok, _other} ->
        {:error, :server_error}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @doc "A code the way it is read out: `123 456`."
  def format_code(<<a::binary-size(3), b::binary-size(3)>>), do: a <> " " <> b
  def format_code(code), do: code
end

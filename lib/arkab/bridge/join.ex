defmodule Arkab.Bridge.Join do
  @moduledoc """
  Joining a server: the whole of it is one link.

  The server's "Add a bridge" shows `https://<server>/join/<code>`, as text
  and as a QR code; it is good for fifteen minutes and for one bridge. The
  bridge is given that link (pasted, or scanned on its page) and does the
  rest: it POSTs to the very same address who it is, and the answer is its
  own long key, where the socket is, and what the server is called. The
  key is stored in the bridge's file and never shown. Nobody types an
  address; nobody sees a key.

  The answer, as JSON: `{"key", "socket", "server", "owner"}` - `socket` is
  a path on the same host (`/bridge/link`), `owner` whether this server may
  make the bridge forget boards and ports. A code that is used up or
  expired is a 404 or a 410, and the bridge says so in words.
  """

  @doc """
  `{:ok, %{url, key, name, owner?}}` - what `Arkab.Bridge.Store.add_server/1`
  takes - or `{:error, reason}` with `reason` an atom the page can say.
  """
  def redeem(link, identity, req_options \\ []) do
    with {:ok, uri} <- parse(link) do
      url = URI.to_string(%{uri | query: nil, fragment: nil})

      options =
        Keyword.merge(
          [
            json: identity,
            retry: false,
            receive_timeout: 15_000,
            connect_options: [timeout: 10_000]
          ],
          req_options
        )

      case Req.post(url, options) do
        {:ok, %{status: 200, body: %{"key" => key, "socket" => socket} = body}}
        when is_binary(key) and is_binary(socket) ->
          {:ok,
           %{
             url: socket_url(uri, socket),
             key: key,
             name: body["server"] || uri.host,
             owner?: body["owner"] == true
           }}

        {:ok, %{status: status}} when status in [404, 410] ->
          {:error, :used_or_expired}

        {:ok, %{status: 409}} ->
          {:error, :version}

        # This bridge is still in another hall on that server, which will
        # not let a code from a second hall take it away from the first.
        {:ok, %{status: 403, body: %{"error" => "elsewhere"}}} ->
          {:error, :elsewhere}

        {:ok, _other} ->
          {:error, :not_a_server}

        {:error, _exception} ->
          {:error, :unreachable}
      end
    end
  end

  @doc "The join link's parts, or `{:error, :not_a_link}`."
  def parse(link) when is_binary(link) do
    case URI.new(String.trim(link)) do
      {:ok, %URI{scheme: scheme, host: host, path: "/join/" <> code} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and code != "" ->
        if scheme == "https" or private_host?(host), do: {:ok, uri}, else: {:error, :insecure}

      _other ->
        {:error, :not_a_link}
    end
  end

  def parse(_other), do: {:error, :not_a_link}

  @doc """
  Whether a host is one where plain http is acceptable: loopback, a private
  address (10/8, 172.16/12, 192.168/16, link-local, 100.64/10, fc00::/7,
  fe80::/10) or a `.local` name. The bridge key travels in the first frame,
  so anywhere else it must be https.
  """
  def private_host?(host) when is_binary(host) do
    host = host |> String.trim("[") |> String.trim("]") |> String.downcase()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> private_ip?(ip)
      {:error, _} -> host == "localhost" or String.ends_with?(host, ".local")
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_ip?(_ip), do: false

  # Where the socket is: the same host and port, ws for http, wss for https.
  defp socket_url(uri, path) do
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%URI{scheme: scheme, host: uri.host, port: uri.port, path: path})
  end
end

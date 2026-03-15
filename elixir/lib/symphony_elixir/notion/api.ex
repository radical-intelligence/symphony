defmodule SymphonyElixir.Notion.API do
  @moduledoc """
  Shared Notion REST request helper for tracker operations and dynamic tools.
  """

  alias SymphonyElixir.Config

  @notion_version "2025-09-03"

  @type method :: :delete | :get | :patch | :post
  @type response :: %{status: integer(), body: term()}
  @type request_fun ::
          (method(), String.t(), [{String.t(), String.t()}], map() | nil ->
             {:ok, response()} | {:error, term()})

  @spec request(method(), String.t(), map() | nil, keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, path, body \\ nil, opts \\ [])
      when method in [:delete, :get, :patch, :post] and is_binary(path) do
    tracker = Config.settings!().tracker
    endpoint = Keyword.get(opts, :endpoint, tracker.endpoint)
    api_key = Keyword.get(opts, :api_key, tracker.api_key)
    url = build_url(endpoint, path)

    with {:ok, headers} <- notion_headers(api_key),
         {:ok, response} <- request_fun(opts).(method, url, headers, body),
         {:ok, normalized} <- normalize_response(response) do
      {:ok, normalized}
    else
      {:error, {:unexpected_response, response}} ->
        {:error, {:notion_api_request, {:unexpected_response, response}}}

      {:error, reason} ->
        {:error, normalize_request_error(reason)}
    end
  end

  @spec request_fun(keyword()) :: request_fun()
  def request_fun(opts \\ []) do
    Keyword.get(opts, :request_fun) ||
      Application.get_env(:symphony_elixir, :notion_request_fun, &default_request/4)
  end

  @spec default_request(method(), String.t(), [{String.t(), String.t()}], map() | nil) ::
          {:ok, response()} | {:error, term()}
  def default_request(method, url, headers, nil) do
    case Req.request(method: method, url: url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def default_request(method, url, headers, body) when is_map(body) do
    case Req.request(
           method: method,
           url: url,
           headers: headers,
           json: body,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notion_headers(nil), do: {:error, :missing_notion_api_token}

  defp notion_headers(token) do
    {:ok,
     [
       {"Authorization", "Bearer " <> token},
       {"Content-Type", "application/json"},
       {"Notion-Version", @notion_version}
     ]}
  end

  defp normalize_response(%{status: status, body: body}) when is_integer(status) do
    {:ok, %{status: status, body: body}}
  end

  defp normalize_response(response), do: {:error, {:unexpected_response, response}}

  defp normalize_request_error(:missing_notion_api_token), do: :missing_notion_api_token
  defp normalize_request_error({:notion_api_request, _reason} = reason), do: reason
  defp normalize_request_error(reason), do: {:notion_api_request, reason}

  defp build_url(endpoint, path) when is_binary(endpoint) and is_binary(path) do
    String.trim_trailing(endpoint, "/") <> path
  end
end

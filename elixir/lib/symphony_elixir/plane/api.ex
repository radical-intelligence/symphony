defmodule SymphonyElixir.Plane.API do
  @moduledoc """
  Shared Plane REST request helper for tracker operations and dynamic tools.
  """

  alias SymphonyElixir.Config

  @type method :: :delete | :get | :patch | :post | :put
  @type response :: %{status: integer(), body: term()}
  @type query :: map() | nil
  @type request_fun ::
          (method(), String.t(), [{String.t(), String.t()}], query(), map() | nil ->
             {:ok, response()} | {:error, term()})

  @spec request(method(), String.t(), map() | nil, keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, path, body \\ nil, opts \\ [])
      when method in [:delete, :get, :patch, :post, :put] and is_binary(path) do
    endpoint =
      Keyword.get_lazy(opts, :endpoint, fn ->
        Config.settings!().tracker.endpoint
      end)

    api_key =
      Keyword.get_lazy(opts, :api_key, fn ->
        Config.settings!().tracker.api_key
      end)

    query = Keyword.get(opts, :query)
    url = build_url(endpoint, path)

    with {:ok, headers} <- plane_headers(api_key),
         {:ok, response} <- request_fun(opts).(method, url, headers, query, body),
         {:ok, normalized} <- normalize_response(response) do
      {:ok, normalized}
    else
      {:error, {:unexpected_response, response}} ->
        {:error, {:plane_api_request, {:unexpected_response, response}}}

      {:error, reason} ->
        {:error, normalize_request_error(reason)}
    end
  end

  @spec request_fun(keyword()) :: request_fun()
  def request_fun(opts \\ []) do
    Keyword.get(opts, :request_fun) ||
      Application.get_env(:symphony_elixir, :plane_request_fun, &default_request/5)
  end

  @spec default_request(
          method(),
          String.t(),
          [{String.t(), String.t()}],
          query(),
          map() | nil
        ) ::
          {:ok, response()} | {:error, term()}
  def default_request(method, url, headers, query, body) when is_map(body) do
    request_options =
      [
        method: method,
        url: url,
        headers: headers,
        json: body,
        connect_options: [timeout: 30_000]
      ]
      |> maybe_put_query(query)

    case Req.request(request_options) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def default_request(method, url, headers, query, nil) do
    request_options =
      [
        method: method,
        url: url,
        headers: headers,
        connect_options: [timeout: 30_000]
      ]
      |> maybe_put_query(query)

    case Req.request(request_options) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_query(options, query) when is_map(query), do: Keyword.put(options, :params, query)
  defp maybe_put_query(options, _query), do: options

  defp plane_headers(nil), do: {:error, :missing_plane_api_token}

  defp plane_headers(api_key) when is_binary(api_key) do
    {:ok,
     [
       {"Content-Type", "application/json"},
       {"X-API-Key", api_key}
     ]}
  end

  defp normalize_response(%{status: status, body: body}) when is_integer(status) do
    {:ok, %{status: status, body: body}}
  end

  defp normalize_response(response), do: {:error, {:unexpected_response, response}}

  defp normalize_request_error(:missing_plane_api_token), do: :missing_plane_api_token
  defp normalize_request_error({:plane_api_request, _reason} = reason), do: reason
  defp normalize_request_error(reason), do: {:plane_api_request, reason}

  defp build_url(endpoint, path) when is_binary(endpoint) and is_binary(path) do
    trimmed_endpoint = String.trim_trailing(endpoint, "/")
    lowercase_endpoint = String.downcase(trimmed_endpoint)

    normalized_endpoint =
      cond do
        String.ends_with?(lowercase_endpoint, "/api/v1") -> trimmed_endpoint
        String.ends_with?(lowercase_endpoint, "/api") -> trimmed_endpoint <> "/v1"
        true -> trimmed_endpoint <> "/api/v1"
      end

    normalized_path =
      path
      |> String.trim()
      |> then(fn raw ->
        cond do
          raw in ["/api/v1", "/api/v1/"] -> "/"
          String.starts_with?(raw, "/api/v1/") -> String.replace_prefix(raw, "/api/v1", "")
          String.starts_with?(raw, "/") -> raw
          true -> "/" <> raw
        end
      end)
      |> ensure_trailing_slash()

    normalized_endpoint <> normalized_path
  end

  defp ensure_trailing_slash("/"), do: "/"

  defp ensure_trailing_slash(path) when is_binary(path) do
    case Regex.run(~r/^([^?#]*)(.*)$/, path, capture: :all_but_first) do
      [path_only, suffix] when path_only != "" ->
        normalized_path =
          if String.ends_with?(path_only, "/"), do: path_only, else: path_only <> "/"

        normalized_path <> suffix

      _ ->
        path
    end
  end
end

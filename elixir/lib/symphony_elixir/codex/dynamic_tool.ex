defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Notion.API, as: NotionAPI

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @notion_api_tool "notion_api"
  @notion_api_description """
  Execute a raw Notion REST API request against Symphony's configured Notion workspace auth.
  """
  @notion_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["path"],
    "properties" => %{
      "path" => %{
        "type" => "string",
        "description" => "Relative Notion API path beginning with `/`, for example `/pages/<page-id>` or `/comments?block_id=<page-id>`."
      },
      "method" => %{
        "type" => "string",
        "description" => "Optional HTTP method. Supported values: GET, POST, PATCH, DELETE.",
        "enum" => ["GET", "POST", "PATCH", "DELETE"]
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body for POST and PATCH requests.",
        "additionalProperties" => true
      }
    }
  }
  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case {tool, current_tracker_kind(opts)} do
      {@linear_graphql_tool, "linear"} ->
        execute_linear_graphql(arguments, opts)

      {@notion_api_tool, "notion"} ->
        execute_notion_api(arguments, opts)

      {other, _tracker_kind} ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names(opts)
          }
        })
    end
  end

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts \\ []) do
    case current_tracker_kind(opts) do
      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      "notion" ->
        [
          %{
            "name" => @notion_api_tool,
            "description" => @notion_api_description,
            "inputSchema" => @notion_api_input_schema
          }
        ]

      _ ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload({:linear_tool_failure, reason}))
    end
  end

  defp execute_notion_api(arguments, opts) do
    notion_request = Keyword.get(opts, :notion_request, &NotionAPI.request/4)

    with {:ok, method, path, body} <- normalize_notion_api_arguments(arguments),
         {:ok, response} <- notion_request.(method, path, body, []) do
      notion_api_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload({:notion_tool_failure, reason}))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_notion_api_arguments(arguments) when is_binary(arguments) do
    with {:ok, path} <- normalize_notion_path(arguments) do
      {:ok, :get, path, nil}
    end
  end

  defp normalize_notion_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_notion_method(Map.get(arguments, "method") || Map.get(arguments, :method) || "GET"),
         {:ok, path} <- normalize_notion_path(Map.get(arguments, "path") || Map.get(arguments, :path)),
         {:ok, body} <- normalize_notion_body(arguments, method) do
      {:ok, method, path, body}
    end
  end

  defp normalize_notion_api_arguments(_arguments), do: {:error, :invalid_notion_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_notion_method(method) when is_atom(method) do
    normalize_notion_method(Atom.to_string(method))
  end

  defp normalize_notion_method(method) when is_binary(method) do
    case method |> String.trim() |> String.downcase() do
      "delete" -> {:ok, :delete}
      "get" -> {:ok, :get}
      "patch" -> {:ok, :patch}
      "post" -> {:ok, :post}
      _ -> {:error, :invalid_notion_method}
    end
  end

  defp normalize_notion_method(_method), do: {:error, :invalid_notion_method}

  defp normalize_notion_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:error, :missing_notion_path}

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        {:error, :invalid_notion_path}

      true ->
        case URI.parse(trimmed) do
          %URI{scheme: nil, host: nil, fragment: nil, path: uri_path} when is_binary(uri_path) and uri_path != "" ->
            if String.starts_with?(uri_path, "/") do
              normalized =
                cond do
                  trimmed == "/v1" -> "/"
                  String.starts_with?(trimmed, "/v1/") -> String.replace_prefix(trimmed, "/v1", "")
                  true -> trimmed
                end

              if normalized == "/" do
                {:error, :invalid_notion_path}
              else
                {:ok, normalized}
              end
            else
              {:error, :invalid_notion_path}
            end

          _ ->
            {:error, :invalid_notion_path}
        end
    end
  end

  defp normalize_notion_path(_path), do: {:error, :missing_notion_path}

  defp normalize_notion_body(arguments, method) do
    case Map.get(arguments, "body") || Map.get(arguments, :body) do
      nil ->
        {:ok, nil}

      body when is_map(body) and method in [:patch, :post] ->
        {:ok, body}

      body when is_map(body) ->
        {:error, {:notion_body_not_allowed, method}}

      _ ->
        {:error, :invalid_notion_body}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp notion_api_response(%{status: status, body: body}) when is_integer(status) and status in 200..299 do
    dynamic_tool_response(true, encode_payload(body))
  end

  defp notion_api_response(%{status: status, body: body}) when is_integer(status) do
    failure_response(%{
      "error" => %{
        "message" => "Notion API request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    })
  end

  defp notion_api_response(response) do
    failure_response(%{
      "error" => %{
        "message" => "Notion API returned an unexpected response.",
        "response" => response
      }
    })
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_notion_path) do
    %{
      "error" => %{
        "message" => "`notion_api` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_arguments) do
    %{
      "error" => %{
        "message" => "`notion_api` expects either a relative Notion API path string or an object with `path` and optional `method`/`body`."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_method) do
    %{
      "error" => %{
        "message" => "`notion_api.method` must be one of GET, POST, PATCH, or DELETE."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_path) do
    %{
      "error" => %{
        "message" => "`notion_api.path` must be a relative Notion API path such as `/pages/<page-id>` and must not include a full URL."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_body) do
    %{
      "error" => %{
        "message" => "`notion_api.body` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload({:notion_body_not_allowed, method}) do
    %{
      "error" => %{
        "message" => "`notion_api.body` is only allowed for POST and PATCH requests.",
        "method" => method |> Atom.to_string() |> String.upcase()
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_notion_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Notion auth. Set `tracker.api_key` in `WORKFLOW.md` or export `NOTION_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:notion_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Notion API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:linear_tool_failure, reason}) do
    case reason do
      :missing_query ->
        tool_error_payload(:missing_query)

      :invalid_arguments ->
        tool_error_payload(:invalid_arguments)

      :invalid_variables ->
        tool_error_payload(:invalid_variables)

      :missing_linear_api_token ->
        tool_error_payload(:missing_linear_api_token)

      {:linear_api_status, _status} = status_reason ->
        tool_error_payload(status_reason)

      {:linear_api_request, _inner} = request_reason ->
        tool_error_payload(request_reason)

      other ->
        %{
          "error" => %{
            "message" => "Linear GraphQL tool execution failed.",
            "reason" => inspect(other)
          }
        }
    end
  end

  defp tool_error_payload({:notion_tool_failure, reason}) do
    case reason do
      :missing_notion_path ->
        tool_error_payload(:missing_notion_path)

      :invalid_notion_arguments ->
        tool_error_payload(:invalid_notion_arguments)

      :invalid_notion_method ->
        tool_error_payload(:invalid_notion_method)

      :invalid_notion_path ->
        tool_error_payload(:invalid_notion_path)

      :invalid_notion_body ->
        tool_error_payload(:invalid_notion_body)

      {:notion_body_not_allowed, _method} = body_reason ->
        tool_error_payload(body_reason)

      :missing_notion_api_token ->
        tool_error_payload(:missing_notion_api_token)

      {:notion_api_request, _inner} = request_reason ->
        tool_error_payload(request_reason)

      other ->
        %{
          "error" => %{
            "message" => "Notion API tool execution failed.",
            "reason" => inspect(other)
          }
        }
    end
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp current_tracker_kind(opts) do
    Keyword.get(opts, :tracker_kind) ||
      case Config.settings() do
        {:ok, settings} -> settings.tracker.kind
        _ -> nil
      end
  end

  defp supported_tool_names(opts) do
    Enum.map(tool_specs(opts), & &1["name"])
  end
end

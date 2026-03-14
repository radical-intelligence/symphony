defmodule SymphonyElixir.Notion.Client do
  @moduledoc """
  Thin Notion REST client for polling task board pages.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Notion.API}

  @query_page_size 100
  @max_error_body_log_bytes 1_000

  @type property_spec :: %{
          id: String.t() | nil,
          name: String.t(),
          type: String.t()
        }

  @type data_source_spec :: %{
          id: String.t(),
          assignee: String.t() | nil,
          assignee_property: property_spec() | nil,
          description_property: property_spec() | nil,
          identifier_property: property_spec() | nil,
          labels_property: property_spec() | nil,
          priority_property: property_spec() | nil,
          status_property: property_spec(),
          title_property: property_spec()
        }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, data_source} <- resolve_data_source_spec(tracker),
         {:ok, pages} <- query_pages(data_source, tracker.active_states) do
      {:ok, normalize_pages(pages, data_source)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with {:ok, data_source} <- resolve_data_source_spec(tracker),
         {:ok, pages} <- query_pages(data_source, state_names) do
      {:ok, normalize_pages(pages, data_source)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, data_source} <- resolve_data_source_spec(tracker),
             {:ok, pages} <- retrieve_pages_by_ids(ids) do
          {:ok, normalize_pages(pages, data_source) |> sort_issues_by_requested_ids(issue_order_index(ids))}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(page_id, body) when is_binary(page_id) and is_binary(body) do
    payload = %{
      "parent" => %{"page_id" => page_id},
      "rich_text" => [
        %{
          "type" => "text",
          "text" => %{"content" => body}
        }
      ]
    }

    case request(:post, "/comments", payload) do
      {:ok, %{"id" => _comment_id}} -> :ok
      {:ok, _response} -> {:error, :notion_comment_create_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(page_id, state_name)
      when is_binary(page_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, data_source} <- resolve_data_source_spec(tracker),
         {:ok, property_value} <- state_update_value(data_source.status_property, state_name),
         {:ok, %{"id" => ^page_id}} <-
           request(:patch, "/pages/#{page_id}", %{
             "properties" => %{
               data_source.status_property.name => property_value
             }
           }) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:ok, _response} -> {:error, :notion_issue_update_failed}
      _ -> {:error, :notion_issue_update_failed}
    end
  end

  defp resolve_data_source_spec(tracker) do
    with {:ok, %{"properties" => properties}} <- retrieve_data_source(tracker.data_source_id),
         {:ok, property_specs} <- build_property_specs(properties),
         {:ok, status_property} <-
           resolve_required_property(
             property_specs,
             tracker.status_property,
             :status_property,
             &(&1 in ["status", "select"]),
             ["Status"]
           ),
         {:ok, title_property} <-
           resolve_required_property(
             property_specs,
             tracker.title_property,
             :title_property,
             &(&1 == "title"),
             []
           ) do
      {:ok,
       %{
         id: tracker.data_source_id,
         assignee: tracker.assignee,
         assignee_property:
           resolve_optional_property(
             property_specs,
             tracker.assignee_property,
             :assignee_property,
             &(&1 == "people"),
             ["Assignee", "Assignees"]
           ),
         description_property:
           resolve_optional_property(
             property_specs,
             tracker.description_property,
             :description_property,
             &(&1 in ["rich_text", "title"]),
             ["Description", "Summary"]
           ),
         identifier_property:
           resolve_optional_property(
             property_specs,
             tracker.identifier_property,
             :identifier_property,
             &identifier_property_type?/1,
             ["Identifier", "ID"]
           ),
         labels_property:
           resolve_optional_property(
             property_specs,
             tracker.labels_property,
             :labels_property,
             &(&1 in ["multi_select", "select"]),
             ["Labels", "Tags"]
           ),
         priority_property:
           resolve_optional_property(
             property_specs,
             tracker.priority_property,
             :priority_property,
             &(&1 in ["number", "rich_text", "select"]),
             ["Priority"]
           ),
         status_property: status_property,
         title_property: title_property
       }}
    end
  end

  defp build_property_specs(properties) when is_map(properties) do
    {:ok,
     Enum.map(properties, fn {key, value} ->
       %{
         id: value["id"],
         name: value["name"] || key,
         type: value["type"]
       }
     end)}
  end

  defp build_property_specs(_properties), do: {:error, :notion_invalid_data_source_properties}

  defp resolve_required_property(property_specs, configured, field, type_matcher, preferred_names)
       when is_list(property_specs) and is_atom(field) and is_function(type_matcher, 1) do
    case resolve_property(property_specs, configured, type_matcher, preferred_names) do
      nil -> {:error, {:notion_property_not_found, field}}
      property_spec -> {:ok, property_spec}
    end
  end

  defp resolve_optional_property(property_specs, configured, _field, type_matcher, preferred_names)
       when is_list(property_specs) and is_function(type_matcher, 1) do
    resolve_property(property_specs, configured, type_matcher, preferred_names)
  end

  defp resolve_property(property_specs, configured, type_matcher, preferred_names)
       when is_list(property_specs) and is_function(type_matcher, 1) do
    configured
    |> normalize_property_reference()
    |> case do
      nil ->
        property_specs
        |> find_preferred_property(type_matcher, preferred_names)
        |> case do
          nil -> Enum.find(property_specs, &type_matcher.(&1.type))
          property_spec -> property_spec
        end

      reference ->
        Enum.find(property_specs, fn property_spec ->
          normalized = normalize_property_reference(property_spec.name)
          normalized_id = normalize_property_reference(property_spec.id)

          reference in [normalized, normalized_id] and type_matcher.(property_spec.type)
        end)
    end
  end

  defp find_preferred_property(property_specs, type_matcher, preferred_names) do
    normalized_names = Enum.map(preferred_names, &normalize_property_reference/1)

    Enum.find(property_specs, fn property_spec ->
      type_matcher.(property_spec.type) and
        normalize_property_reference(property_spec.name) in normalized_names
    end)
  end

  defp normalize_property_reference(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_property_reference(_value), do: nil

  defp identifier_property_type?(type) when is_binary(type) do
    type in ["title", "rich_text", "unique_id", "number", "formula", "select", "status"]
  end

  defp query_pages(_data_source, state_names)
       when is_list(state_names) and state_names == [],
       do: {:ok, []}

  defp query_pages(data_source, state_names) when is_map(data_source) and is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case normalized_states do
      [] -> {:ok, []}
      _ -> do_query_pages(data_source, normalized_states, nil, [])
    end
  end

  defp do_query_pages(data_source, state_names, start_cursor, acc_pages) do
    payload =
      %{
        "page_size" => @query_page_size,
        "result_type" => "page",
        "filter" => state_filter(data_source.status_property, state_names)
      }
      |> maybe_put_cursor(start_cursor)

    with {:ok, %{"results" => results} = body} <-
           request(:post, "/data_sources/#{data_source.id}/query", payload) do
      pages = Enum.filter(results, &page_object?/1)
      updated_acc = Enum.reverse(pages, acc_pages)

      if body["has_more"] == true and is_binary(body["next_cursor"]) do
        do_query_pages(data_source, state_names, body["next_cursor"], updated_acc)
      else
        {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp maybe_put_cursor(payload, start_cursor) when is_binary(start_cursor) do
    Map.put(payload, "start_cursor", start_cursor)
  end

  defp maybe_put_cursor(payload, _start_cursor), do: payload

  defp state_filter(property_spec, [state_name]) do
    %{
      "property" => property_spec.name,
      property_spec.type => %{"equals" => state_name}
    }
  end

  defp state_filter(property_spec, state_names) do
    %{
      "or" =>
        Enum.map(state_names, fn state_name ->
          %{
            "property" => property_spec.name,
            property_spec.type => %{"equals" => state_name}
          }
        end)
    }
  end

  defp retrieve_pages_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc_pages} ->
      case request(:get, "/pages/#{issue_id}") do
        {:ok, page} when is_map(page) ->
          if page_object?(page) do
            {:cont, {:ok, [page | acc_pages]}}
          else
            {:halt, {:error, :notion_unknown_payload}}
          end

        {:error, {:notion_api_status, 404}} ->
          {:cont, {:ok, acc_pages}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        _ ->
          {:halt, {:error, :notion_unknown_payload}}
      end
    end)
    |> case do
      {:ok, pages} -> {:ok, Enum.reverse(pages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_pages(pages, data_source) when is_list(pages) and is_map(data_source) do
    pages
    |> Enum.map(&normalize_page(&1, data_source))
    |> Enum.reject(&is_nil(&1))
  end

  defp normalize_page(page, data_source) when is_map(page) and is_map(data_source) do
    identifier = property_text(page, data_source.identifier_property) || page["id"]
    title = property_text(page, data_source.title_property) || identifier || "Untitled"
    assignee_ids = people_ids(page, data_source.assignee_property)

    %Issue{
      id: page["id"],
      identifier: identifier,
      title: title,
      description: property_text(page, data_source.description_property),
      priority: property_priority(page, data_source.priority_property),
      state: property_state(page, data_source.status_property),
      branch_name: nil,
      url: page["url"],
      assignee_id: List.first(assignee_ids),
      blocked_by: [],
      labels: property_labels(page, data_source.labels_property),
      assigned_to_worker: assigned_to_worker?(assignee_ids, data_source.assignee),
      created_at: parse_datetime(page["created_time"]),
      updated_at: parse_datetime(page["last_edited_time"])
    }
  end

  defp normalize_page(_page, _data_source), do: nil

  defp property_text(_page, nil), do: nil

  defp property_text(page, property_spec) when is_map(page) and is_map(property_spec) do
    page
    |> page_property(property_spec)
    |> property_text_value()
    |> normalize_optional_string()
  end

  defp property_state(page, property_spec) when is_map(page) and is_map(property_spec) do
    page
    |> page_property(property_spec)
    |> case do
      %{"type" => "status", "status" => %{"name" => name}} -> name
      %{"type" => "select", "select" => %{"name" => name}} -> name
      _ -> nil
    end
  end

  defp property_labels(_page, nil), do: []

  defp property_labels(page, property_spec) when is_map(page) and is_map(property_spec) do
    page
    |> page_property(property_spec)
    |> case do
      %{"type" => "multi_select", "multi_select" => values} when is_list(values) ->
        values
        |> Enum.map(& &1["name"])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&String.downcase/1)

      %{"type" => "select", "select" => %{"name" => name}} when is_binary(name) ->
        [String.downcase(name)]

      _ ->
        []
    end
  end

  defp property_priority(_page, nil), do: nil

  defp property_priority(page, property_spec) when is_map(page) and is_map(property_spec) do
    page
    |> page_property(property_spec)
    |> case do
      %{"type" => "number", "number" => number} when is_integer(number) ->
        number

      %{"type" => "number", "number" => number} when is_float(number) ->
        trunc(number)

      property ->
        property
        |> property_text_value()
        |> parse_integer_string()
    end
  end

  defp people_ids(_page, nil), do: []

  defp people_ids(page, property_spec) when is_map(page) and is_map(property_spec) do
    page
    |> page_property(property_spec)
    |> case do
      %{"type" => "people", "people" => people} when is_list(people) ->
        Enum.flat_map(people, fn
          %{"id" => id} when is_binary(id) -> [id]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp assigned_to_worker?(_assignee_ids, nil), do: true

  defp assigned_to_worker?(assignee_ids, configured_assignee) when is_list(assignee_ids) do
    Enum.member?(assignee_ids, configured_assignee)
  end

  defp page_property(%{"properties" => properties}, property_spec)
       when is_map(properties) and is_map(property_spec) do
    Map.get(properties, property_spec.name) ||
      Enum.find_value(properties, fn
        {_name, %{"id" => id} = property} when id == property_spec.id -> property
        _ -> nil
      end)
  end

  defp page_property(_page, _property_spec), do: nil

  defp property_text_value(%{"type" => "title", "title" => title}), do: rich_text_plain(title)
  defp property_text_value(%{"type" => "rich_text", "rich_text" => rich_text}), do: rich_text_plain(rich_text)

  defp property_text_value(%{"type" => "unique_id", "unique_id" => %{"number" => number} = unique_id})
       when is_integer(number) do
    case normalize_optional_string(unique_id["prefix"]) do
      nil -> Integer.to_string(number)
      prefix -> prefix <> "-" <> Integer.to_string(number)
    end
  end

  defp property_text_value(%{"type" => "number", "number" => number}) when is_number(number),
    do: to_string(number)

  defp property_text_value(%{"type" => "status", "status" => %{"name" => name}}), do: name
  defp property_text_value(%{"type" => "select", "select" => %{"name" => name}}), do: name

  defp property_text_value(%{"type" => "formula", "formula" => %{"type" => "string", "string" => value}}),
    do: value

  defp property_text_value(%{"type" => "formula", "formula" => %{"type" => "number", "number" => value}})
       when is_number(value),
       do: to_string(value)

  defp property_text_value(%{"type" => "url", "url" => value}), do: value
  defp property_text_value(_property), do: nil

  defp rich_text_plain(items) when is_list(items) do
    items
    |> Enum.map(&(&1["plain_text"] || ""))
    |> Enum.join("")
  end

  defp rich_text_plain(_items), do: nil

  defp parse_integer_string(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp parse_integer_string(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp state_update_value(%{type: "status"}, state_name) when is_binary(state_name) do
    {:ok, %{"status" => %{"name" => state_name}}}
  end

  defp state_update_value(%{type: "select"}, state_name) when is_binary(state_name) do
    {:ok, %{"select" => %{"name" => state_name}}}
  end

  defp state_update_value(_property_spec, _state_name), do: {:error, :notion_invalid_status_property}

  defp retrieve_data_source(data_source_id) when is_binary(data_source_id) do
    request(:get, "/data_sources/#{data_source_id}")
  end

  defp request(method, path, body \\ nil)
       when method in [:get, :patch, :post] and is_binary(path) do
    with {:ok, response} <- API.request(method, path, body) do
      case response do
        %{status: status, body: response_body} when status in 200..299 ->
          {:ok, response_body}

        %{status: status, body: response_body} ->
          Logger.error("Notion request failed status=#{status} path=#{path} body=#{summarize_error_body(response_body)}")
          {:error, {:notion_api_status, status}}

        other ->
          Logger.error("Notion request returned unexpected response for path=#{path}: #{inspect(other)}")
          {:error, :notion_unknown_payload}
      end
    else
      {:error, reason} ->
        Logger.error("Notion request failed path=#{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp page_object?(%{"object" => "page"}), do: true
  defp page_object?(_page), do: false

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end
end

defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Thin Plane REST client for polling work items.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Plane.API}

  @query_page_size 100
  @expand_fields "assignees,labels,state,project"
  @max_error_body_log_bytes 1_000

  @type tracker_context :: %{
          workspace_slug: String.t(),
          project_id: String.t(),
          project_identifier: String.t() | nil,
          assignee: String.t() | nil,
          states: [map()]
        }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, context} <- resolve_tracker_context(tracker),
         {:ok, state_ids} <- resolve_state_ids(context.states, tracker.active_states),
         {:ok, work_items} <- list_work_items_by_state_ids(context, state_ids) do
      {:ok, normalize_work_items(work_items, context)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with {:ok, context} <- resolve_tracker_context(tracker),
         {:ok, state_ids} <- resolve_state_ids(context.states, state_names),
         {:ok, work_items} <- list_work_items_by_state_ids(context, state_ids, assignee: nil) do
      {:ok, normalize_work_items(work_items, context)}
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
        with {:ok, context} <- resolve_tracker_context(tracker),
             {:ok, work_items} <- retrieve_work_items_by_ids(context, ids) do
          {:ok,
           work_items
           |> normalize_work_items(context)
           |> sort_issues_by_requested_ids(issue_order_index(ids))}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(work_item_id, body) when is_binary(work_item_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, context} <- resolve_comment_context(tracker),
         {:ok, %{"id" => _comment_id}} <-
           request(
             :post,
             comment_path(context, work_item_id),
             %{"comment_html" => comment_html(body)}
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:ok, _response} -> {:error, :plane_comment_create_failed}
      _ -> {:error, :plane_comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(work_item_id, state_name)
      when is_binary(work_item_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, context} <- resolve_tracker_context(tracker),
         {:ok, state_id} <- resolve_single_state_id(context.states, state_name),
         :ok <- patch_issue_state(context, work_item_id, state_id) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_tracker_context(tracker, opts \\ []) do
    include_states = Keyword.get(opts, :include_states, true)

    with {:ok, project} <- retrieve_project(tracker.workspace_slug, tracker.project_id),
         {:ok, states} <- maybe_list_states(tracker.workspace_slug, tracker.project_id, include_states) do
      {:ok,
       %{
         workspace_slug: tracker.workspace_slug,
         project_id: tracker.project_id,
         project_identifier: project["identifier"],
         assignee: tracker.assignee,
         states: states
       }}
    end
  end

  defp resolve_comment_context(tracker) do
    {:ok,
     %{
       workspace_slug: tracker.workspace_slug,
       project_id: tracker.project_id
     }}
  end

  defp maybe_list_states(_workspace_slug, _project_id, false), do: {:ok, []}
  defp maybe_list_states(workspace_slug, project_id, true), do: list_states(workspace_slug, project_id)

  defp retrieve_project(workspace_slug, project_id)
       when is_binary(workspace_slug) and is_binary(project_id) do
    request(:get, "/workspaces/#{workspace_slug}/projects/#{project_id}")
  end

  defp list_states(workspace_slug, project_id)
       when is_binary(workspace_slug) and is_binary(project_id) do
    with {:ok, response} <- request(:get, "/workspaces/#{workspace_slug}/projects/#{project_id}/states"),
         {:ok, states} <- extract_results(response, :states) do
      {:ok, Enum.filter(states, &is_map/1)}
    end
  end

  defp resolve_state_ids(_states, state_names) when is_list(state_names) and state_names == [],
    do: {:ok, []}

  defp resolve_state_ids(states, state_names) when is_list(states) and is_list(state_names) do
    normalized_names =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    state_map =
      Map.new(states, fn state ->
        {normalize_state_name(state["name"]), state["id"]}
      end)

    case Enum.find(normalized_names, fn state_name ->
           not is_binary(Map.get(state_map, normalize_state_name(state_name)))
         end) do
      nil ->
        {:ok,
         normalized_names
         |> Enum.map(&Map.fetch!(state_map, normalize_state_name(&1)))
         |> Enum.uniq()}

      missing_state ->
        {:error, {:plane_state_not_found, missing_state}}
    end
  end

  defp resolve_single_state_id(states, state_name) when is_list(states) and is_binary(state_name) do
    case resolve_state_ids(states, [state_name]) do
      {:ok, [state_id]} -> {:ok, state_id}
      {:ok, _state_ids} -> {:error, {:plane_state_not_found, state_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_work_items_by_state_ids(context, state_ids, opts \\ [])

  defp list_work_items_by_state_ids(_context, state_ids, _opts) when state_ids == [], do: {:ok, []}

  defp list_work_items_by_state_ids(context, state_ids, opts) when is_map(context) and is_list(state_ids) do
    assignee = Keyword.get(opts, :assignee, context.assignee)

    Enum.reduce_while(state_ids, {:ok, []}, fn state_id, {:ok, acc_work_items} ->
      case list_work_items_by_state_id(context, state_id, assignee) do
        {:ok, work_items} ->
          {:cont, {:ok, acc_work_items ++ work_items}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, work_items} -> {:ok, dedupe_work_items_by_id(work_items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_work_items_by_state_id(context, state_id, assignee) do
    do_list_work_items_by_state_id(context, state_id, assignee, nil, [])
  end

  defp do_list_work_items_by_state_id(context, state_id, assignee, cursor, acc_work_items) do
    query =
      %{
        "expand" => @expand_fields,
        "per_page" => @query_page_size,
        "state" => state_id
      }
      |> maybe_put_query_value("assignee", assignee)
      |> maybe_put_query_value("cursor", cursor)

    with {:ok, response} <-
           request(
             :get,
             "/workspaces/#{context.workspace_slug}/projects/#{context.project_id}/work-items",
             nil,
             query: query
           ),
         {:ok, work_items} <- extract_results(response, :work_items) do
      updated_acc = acc_work_items ++ Enum.filter(work_items, &is_map/1)

      if response["next_page_results"] == true and is_binary(response["next_cursor"]) and response["next_cursor"] != "" do
        do_list_work_items_by_state_id(context, state_id, assignee, response["next_cursor"], updated_acc)
      else
        {:ok, updated_acc}
      end
    end
  end

  defp maybe_put_query_value(query, _key, nil), do: query
  defp maybe_put_query_value(query, _key, ""), do: query
  defp maybe_put_query_value(query, key, value), do: Map.put(query, key, value)

  defp retrieve_work_items_by_ids(context, issue_ids) when is_map(context) and is_list(issue_ids) do
    issue_ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc_work_items} ->
      case request(
             :get,
             "/workspaces/#{context.workspace_slug}/projects/#{context.project_id}/work-items/#{issue_id}",
             nil,
             query: %{"expand" => @expand_fields}
           ) do
        {:ok, work_item} when is_map(work_item) ->
          {:cont, {:ok, [work_item | acc_work_items]}}

        {:error, {:plane_api_status, 404}} ->
          {:cont, {:ok, acc_work_items}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        _ ->
          {:halt, {:error, :plane_unknown_payload}}
      end
    end)
    |> case do
      {:ok, work_items} -> {:ok, Enum.reverse(work_items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp patch_issue_state(context, work_item_id, state_id) do
    work_item_path = "/workspaces/#{context.workspace_slug}/projects/#{context.project_id}/work-items/#{work_item_id}"

    case request(:patch, work_item_path, %{"state" => state_id}) do
      {:ok, %{"id" => ^work_item_id}} ->
        :ok

      {:error, {:plane_api_status, status}} when status in [400, 422] ->
        patch_issue_state_with_fallback_key(work_item_path, work_item_id, state_id)

      {:error, reason} ->
        {:error, reason}

      {:ok, _response} ->
        {:error, :plane_issue_update_failed}

      _ ->
        {:error, :plane_issue_update_failed}
    end
  end

  defp patch_issue_state_with_fallback_key(work_item_path, work_item_id, state_id) do
    case request(:patch, work_item_path, %{"state_id" => state_id}) do
      {:ok, %{"id" => ^work_item_id}} -> :ok
      {:error, reason} -> {:error, reason}
      {:ok, _response} -> {:error, :plane_issue_update_failed}
      _ -> {:error, :plane_issue_update_failed}
    end
  end

  defp comment_path(context, work_item_id) do
    "/workspaces/#{context.workspace_slug}/projects/#{context.project_id}/work-items/#{work_item_id}/comments"
  end

  defp normalize_work_items(work_items, context) when is_list(work_items) and is_map(context) do
    work_items
    |> Enum.map(&normalize_work_item(&1, context))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_work_item(work_item, context) when is_map(work_item) and is_map(context) do
    identifier = build_issue_identifier(work_item, context.project_identifier)
    assignee_ids = assignee_ids(work_item["assignees"])

    %Issue{
      id: work_item["id"],
      identifier: identifier,
      title: normalize_optional_string(work_item["name"]) || identifier || "Untitled",
      description:
        normalize_optional_string(work_item["description_stripped"]) ||
          strip_html(work_item["description_html"]),
      priority: map_priority(work_item["priority"]),
      state: state_name(work_item["state"], context.states),
      branch_name: nil,
      url: normalize_optional_string(work_item["url"]),
      assignee_id: List.first(assignee_ids),
      blocked_by: [],
      labels: label_names(work_item["labels"]),
      assigned_to_worker: assigned_to_worker?(assignee_ids, context.assignee),
      created_at: parse_datetime(work_item["created_at"]),
      updated_at: parse_datetime(work_item["updated_at"])
    }
  end

  defp normalize_work_item(_work_item, _context), do: nil

  defp build_issue_identifier(work_item, fallback_project_identifier) when is_map(work_item) do
    project_identifier =
      case work_item["project"] do
        %{"identifier" => identifier} when is_binary(identifier) -> identifier
        _ -> fallback_project_identifier
      end

    case {project_identifier, work_item["sequence_id"], work_item["id"]} do
      {identifier, sequence_id, _id} when is_binary(identifier) and is_integer(sequence_id) ->
        "#{identifier}-#{sequence_id}"

      {_identifier, sequence_id, _id} when is_integer(sequence_id) ->
        Integer.to_string(sequence_id)

      {_identifier, _sequence_id, id} when is_binary(id) ->
        id

      _ ->
        nil
    end
  end

  defp state_name(%{"name" => name}, _states) when is_binary(name), do: name

  defp state_name(state_id, states) when is_binary(state_id) and is_list(states) do
    states
    |> Enum.find_value(fn
      %{"id" => ^state_id, "name" => name} when is_binary(name) -> name
      _ -> nil
    end)
  end

  defp state_name(_state, _states), do: nil

  defp assignee_ids(assignees) when is_list(assignees) do
    Enum.flat_map(assignees, fn
      %{"id" => id} when is_binary(id) -> [id]
      id when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp assignee_ids(_assignees), do: []

  defp assigned_to_worker?(_assignee_ids, nil), do: true

  defp assigned_to_worker?(assignee_ids, configured_assignee) when is_list(assignee_ids) do
    Enum.member?(assignee_ids, configured_assignee)
  end

  defp label_names(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [String.downcase(name)]
      name when is_binary(name) -> [String.downcase(name)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp label_names(_labels), do: []

  defp map_priority("urgent"), do: 1
  defp map_priority("high"), do: 2
  defp map_priority("medium"), do: 3
  defp map_priority("low"), do: 4
  defp map_priority(_priority), do: nil

  defp strip_html(nil), do: nil

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> html_unescape()
    |> normalize_optional_string()
  end

  defp strip_html(_html), do: nil

  defp html_unescape(value) when is_binary(value) do
    value
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp comment_html(body) when is_binary(body) do
    escaped_body =
      body
      |> html_escape()
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace("\n", "<br>")

    "<p>" <> escaped_body <> "</p>"
  end

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp normalize_state_name(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state_name(_state_name), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp dedupe_work_items_by_id(work_items) when is_list(work_items) do
    {_seen_ids, deduped_items} =
      Enum.reduce(work_items, {MapSet.new(), []}, fn work_item, {seen_ids, acc_work_items} ->
        work_item_id =
          case work_item do
            %{"id" => id} when is_binary(id) -> id
            _ -> inspect(work_item)
          end

        if MapSet.member?(seen_ids, work_item_id) do
          {seen_ids, acc_work_items}
        else
          {MapSet.put(seen_ids, work_item_id), [work_item | acc_work_items]}
        end
      end)

    Enum.reverse(deduped_items)
  end

  defp extract_results(%{"results" => results}, _kind) when is_list(results), do: {:ok, results}
  defp extract_results(results, _kind) when is_list(results), do: {:ok, results}
  defp extract_results(_response, :states), do: {:error, :plane_invalid_states_payload}
  defp extract_results(_response, :work_items), do: {:error, :plane_invalid_work_items_payload}

  defp request(method, path, body \\ nil, opts \\ [])
       when method in [:get, :patch, :post] and is_binary(path) do
    query = Keyword.get(opts, :query)

    with {:ok, response} <- API.request(method, path, body, query: query) do
      case response do
        %{status: status, body: response_body} when status in 200..299 ->
          {:ok, response_body}

        %{status: status, body: response_body} ->
          Logger.error("Plane request failed status=#{status} path=#{path} body=#{summarize_error_body(response_body)}")
          {:error, {:plane_api_status, status}}

        other ->
          Logger.error("Plane request returned unexpected response for path=#{path}: #{inspect(other)}")
          {:error, :plane_unknown_payload}
      end
    else
      {:error, reason} ->
        Logger.error("Plane request failed path=#{path}: #{inspect(reason)}")
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

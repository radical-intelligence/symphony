defmodule SymphonyElixir.Plane.StateSync do
  @moduledoc false

  alias SymphonyElixir.Plane.API

  @default_endpoint "https://api.plane.so"

  @required_specs [
    %{
      name: "Backlog",
      aliases: [],
      group: "backlog",
      color: "#6B7280",
      purpose: "Out-of-scope or not-yet-ready work. Symphony should not start from here."
    },
    %{
      name: "Todo",
      aliases: [],
      group: "unstarted",
      color: "#64748B",
      purpose: "Agent-ready queued work. Symphony can pick tickets up from this state."
    },
    %{
      name: "In Progress",
      aliases: [],
      group: "started",
      color: "#2563EB",
      purpose: "Active implementation by Symphony."
    },
    %{
      name: "Done",
      aliases: [],
      group: "completed",
      color: "#16A34A",
      purpose: "Terminal completed work. Symphony stops here."
    },
    %{
      name: "Cancelled",
      aliases: ["Canceled"],
      group: "cancelled",
      color: "#EF4444",
      purpose: "Terminal non-completed work. Symphony also stops here."
    }
  ]

  @optional_review_loop_specs [
    %{
      name: "Human Review",
      aliases: [],
      group: "unstarted",
      color: "#F59E0B",
      purpose: "Non-active handoff state while a human reviews the agent's result."
    },
    %{
      name: "Merging",
      aliases: [],
      group: "started",
      color: "#7C3AED",
      purpose: "Post-approval active state used for final landing and merge work."
    },
    %{
      name: "Rework",
      aliases: [],
      group: "started",
      color: "#DC2626",
      purpose: "Post-review reset state for another implementation attempt, not just a return to Todo."
    }
  ]

  @type config :: %{
          endpoint: String.t(),
          api_key: String.t(),
          workspace_slug: String.t(),
          project_id: String.t()
        }

  @type action :: %{
          type: :create | :update,
          state_id: String.t() | nil,
          state_name: String.t(),
          group: String.t(),
          attrs: map(),
          purpose: String.t(),
          reason: String.t()
        }

  @type section :: %{
          actions: [action()],
          unchanged: [map()],
          warnings: [String.t()]
        }

  @type plan :: %{
          required: section(),
          optional_review_loop: section(),
          extras: [map()],
          warnings: [String.t()],
          current_states: [map()],
          include_review_loop: boolean()
        }

  @spec default_endpoint() :: String.t()
  def default_endpoint, do: @default_endpoint

  @spec required_specs() :: [map()]
  def required_specs, do: @required_specs

  @spec optional_review_loop_specs() :: [map()]
  def optional_review_loop_specs, do: @optional_review_loop_specs

  @spec list_states(config(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_states(config, opts \\ []) when is_map(config) do
    with {:ok, body} <- request(config, :get, states_path(config), nil, opts) do
      case body do
        %{"results" => results} when is_list(results) -> {:ok, Enum.filter(results, &is_map/1)}
        results when is_list(results) -> {:ok, Enum.filter(results, &is_map/1)}
        _ -> {:error, :plane_invalid_states_payload}
      end
    end
  end

  @spec build_plan([map()], keyword()) :: plan()
  def build_plan(current_states, opts \\ []) when is_list(current_states) do
    include_review_loop = Keyword.get(opts, :include_review_loop, false)
    required = plan_section(current_states, @required_specs)
    optional_review_loop = plan_section(current_states, @optional_review_loop_specs)
    known_state_names = known_state_names()

    extras =
      Enum.filter(current_states, fn state ->
        normalize_name(state["name"]) not in known_state_names
      end)

    %{
      required: required,
      optional_review_loop: optional_review_loop,
      extras: extras,
      warnings: required.warnings ++ optional_review_loop.warnings,
      current_states: current_states,
      include_review_loop: include_review_loop
    }
  end

  @spec actions_to_apply(plan()) :: [action()]
  def actions_to_apply(plan) when is_map(plan) do
    required_actions = plan.required.actions

    if plan.include_review_loop do
      required_actions ++ plan.optional_review_loop.actions
    else
      required_actions
    end
  end

  @spec apply_actions(config(), [action()], keyword()) ::
          {:ok, [%{action: action(), response: map()}]} | {:error, term()}
  def apply_actions(config, actions, opts \\ []) when is_map(config) and is_list(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, applied} ->
      case apply_action(config, action, opts) do
        {:ok, response} ->
          {:cont, {:ok, applied ++ [%{action: action, response: response}]}}

        {:error, reason} ->
          {:halt, {:error, {:plane_state_sync_failed, action, reason}}}
      end
    end)
  end

  defp plan_section(current_states, specs) do
    Enum.reduce(specs, %{actions: [], unchanged: [], warnings: []}, fn spec, acc ->
      case match_state(current_states, spec) do
        {:missing, _duplicates} ->
          action = %{
            type: :create,
            state_id: nil,
            state_name: spec.name,
            group: spec.group,
            attrs: %{"name" => spec.name, "group" => spec.group, "color" => spec.color},
            purpose: spec.purpose,
            reason: "create missing #{spec.name} state in #{spec.group}"
          }

          %{acc | actions: acc.actions ++ [action]}

        {:matched, state, duplicates} ->
          attrs = update_attrs(state, spec)
          warnings = acc.warnings ++ duplicate_warnings(spec, duplicates)

          if map_size(attrs) == 0 do
            %{acc | unchanged: acc.unchanged ++ [state], warnings: warnings}
          else
            action = %{
              type: :update,
              state_id: state["id"],
              state_name: spec.name,
              group: spec.group,
              attrs: attrs,
              purpose: spec.purpose,
              reason: update_reason(state, spec, attrs)
            }

            %{acc | actions: acc.actions ++ [action], warnings: warnings}
          end

        {:ambiguous, matches} ->
          warning =
            "Multiple states match #{spec.name}: " <>
              Enum.map_join(matches, ", ", fn state -> format_state_name(state) end)

          %{acc | warnings: acc.warnings ++ [warning]}
      end
    end)
  end

  defp duplicate_warnings(_spec, []), do: []

  defp duplicate_warnings(spec, duplicates) do
    [
      "#{spec.name} has extra alias-matched states that were left unchanged: " <>
        Enum.map_join(duplicates, ", ", &format_state_name/1)
    ]
  end

  defp update_attrs(state, spec) when is_map(state) and is_map(spec) do
    %{}
    |> maybe_put_attr("name", state["name"], spec.name)
    |> maybe_put_attr("group", state["group"], spec.group)
  end

  defp maybe_put_attr(attrs, _key, current_value, desired_value) when current_value == desired_value,
    do: attrs

  defp maybe_put_attr(attrs, key, _current_value, desired_value), do: Map.put(attrs, key, desired_value)

  defp update_reason(state, spec, attrs) do
    fragments =
      [
        if(attrs["name"], do: "rename #{inspect(state["name"])} to #{inspect(spec.name)}"),
        if(attrs["group"], do: "change group from #{inspect(state["group"])} to #{inspect(spec.group)}")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(fragments, " and ")
  end

  defp match_state(current_states, spec) do
    exact_matches =
      Enum.filter(current_states, fn state ->
        normalize_name(state["name"]) == normalize_name(spec.name)
      end)

    alias_names =
      [spec.name | spec.aliases]
      |> Enum.map(&normalize_name/1)
      |> MapSet.new()

    alias_matches =
      Enum.filter(current_states, fn state ->
        normalize_name(state["name"]) in alias_names
      end)

    cond do
      length(exact_matches) == 1 ->
        [exact_match] = exact_matches
        duplicates = Enum.reject(alias_matches, &(&1["id"] == exact_match["id"]))
        {:matched, exact_match, duplicates}

      length(exact_matches) > 1 ->
        {:ambiguous, exact_matches}

      length(alias_matches) == 1 ->
        [alias_match] = alias_matches
        {:matched, alias_match, []}

      length(alias_matches) > 1 ->
        {:ambiguous, alias_matches}

      true ->
        {:missing, []}
    end
  end

  defp known_state_names do
    (@required_specs ++ @optional_review_loop_specs)
    |> Enum.flat_map(fn spec -> [spec.name | spec.aliases] end)
    |> Enum.map(&normalize_name/1)
    |> MapSet.new()
  end

  @spec state_purpose(String.t()) :: String.t() | nil
  def state_purpose(state_name) when is_binary(state_name) do
    normalized = normalize_name(state_name)

    (@required_specs ++ @optional_review_loop_specs)
    |> Enum.find_value(fn spec ->
      names = [spec.name | spec.aliases] |> Enum.map(&normalize_name/1)

      if normalized in names do
        spec.purpose
      else
        nil
      end
    end)
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(_value), do: nil

  defp format_state_name(%{"name" => name, "group" => group}) when is_binary(name) and is_binary(group) do
    "#{name} [#{group}]"
  end

  defp format_state_name(%{"name" => name}) when is_binary(name), do: name
  defp format_state_name(state), do: inspect(state)

  defp apply_action(config, %{type: :create, attrs: attrs}, opts) when is_map(attrs) do
    request(config, :post, states_path(config), attrs, opts)
  end

  defp apply_action(config, %{type: :update, state_id: state_id, attrs: attrs}, opts)
       when is_binary(state_id) and is_map(attrs) do
    request(config, :patch, state_path(config, state_id), attrs, opts)
  end

  defp request(config, method, path, body, opts)
       when method in [:get, :patch, :post] and is_binary(path) do
    request_opts =
      [
        endpoint: config.endpoint,
        api_key: config.api_key,
        query: Keyword.get(opts, :query),
        request_fun: Keyword.get(opts, :request_fun)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, response} <- API.request(method, path, body, request_opts) do
      case response do
        %{status: status, body: response_body} when status in 200..299 ->
          {:ok, response_body}

        %{status: status, body: response_body} ->
          {:error, {:plane_api_status, status, response_body}}

        other ->
          {:error, {:plane_api_unexpected_response, other}}
      end
    end
  end

  defp states_path(config) do
    "/workspaces/#{config.workspace_slug}/projects/#{config.project_id}/states/"
  end

  defp state_path(config, state_id) do
    "/workspaces/#{config.workspace_slug}/projects/#{config.project_id}/states/#{state_id}/"
  end
end

defmodule Mix.Tasks.Plane.SyncStates do
  use Mix.Task

  alias SymphonyElixir.Plane.StateSync

  @shortdoc "Check and sync the configured Plane project states for Symphony"

  @moduledoc """
  Checks the configured Plane project's workflow states, prints recommendations, and applies the
  required changes for Symphony.

  By default this syncs the minimal Symphony workflow:

      Backlog -> Todo -> In Progress -> Done/Cancelled

  If `--with-review-loop` (or `--with-rework`) is supplied, the task also ensures the richer review
  loop states:

      Human Review, Merging, Rework

  Usage:

      mix plane.sync_states
      mix plane.sync_states --dry-run
      mix plane.sync_states --with-review-loop
      mix plane.sync_states --project-id <project-id>

  Configuration resolution order:

  1. CLI flags
  2. Environment variables:
     - `PLANE_API_KEY`
     - `PLANE_WORKSPACE_SLUG`
     - `PLANE_PROJECT_ID`
     - `SYMPHONY_LIVE_PLANE_ENDPOINT` (optional)
  """

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          api_key: :string,
          dry_run: :boolean,
          endpoint: :string,
          help: :boolean,
          project_id: :string,
          with_review_loop: :boolean,
          with_rework: :boolean,
          workspace_slug: :string
        ],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        ensure_req_started!()
        config = resolve_config!(opts)
        include_review_loop = opts[:with_review_loop] || opts[:with_rework] || false
        dry_run? = opts[:dry_run] || false

        case StateSync.list_states(config) do
          {:ok, current_states} ->
            plan = StateSync.build_plan(current_states, include_review_loop: include_review_loop)
            print_plan(config, plan)
            maybe_apply_changes(config, plan, dry_run?)

          {:error, reason} ->
            Mix.raise("Failed to list Plane project states: #{inspect(reason)}")
        end
    end
  end

  defp ensure_req_started! do
    case Application.ensure_all_started(:req) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("Failed to start Req for Plane API access: #{inspect(reason)}")
    end
  end

  defp resolve_config!(opts) do
    config = %{
      api_key: opts[:api_key] || System.get_env("PLANE_API_KEY"),
      endpoint: opts[:endpoint] || System.get_env("SYMPHONY_LIVE_PLANE_ENDPOINT") || StateSync.default_endpoint(),
      workspace_slug: opts[:workspace_slug] || System.get_env("PLANE_WORKSPACE_SLUG"),
      project_id: opts[:project_id] || System.get_env("PLANE_PROJECT_ID")
    }

    missing =
      [
        {"PLANE_API_KEY", config.api_key},
        {"PLANE_WORKSPACE_SLUG", config.workspace_slug},
        {"PLANE_PROJECT_ID", config.project_id}
      ]
      |> Enum.flat_map(fn
        {_name, value} when is_binary(value) and value != "" -> []
        {name, _value} -> [name]
      end)

    case missing do
      [] ->
        config

      names ->
        Mix.raise(
          "Missing required Plane configuration: #{Enum.join(names, ", ")}. " <>
            "Set them in your environment or pass CLI flags."
        )
    end
  end

  defp print_plan(config, plan) do
    Mix.shell().info("Plane state sync")
    Mix.shell().info("Workspace: #{config.workspace_slug}")
    Mix.shell().info("Project: #{config.project_id}")
    Mix.shell().info("")
    Mix.shell().info("Current states:")

    Enum.each(plan.current_states, fn state ->
      Mix.shell().info("  - #{state["name"]} [#{state["group"]}]")
    end)

    Mix.shell().info("")
    print_section("Required Symphony states", plan.required)
    Mix.shell().info("")

    if plan.include_review_loop do
      print_section("Optional review-loop states (will be applied)", plan.optional_review_loop)
    else
      print_section(
        "Optional review-loop states (not applied unless --with-review-loop)",
        plan.optional_review_loop
      )
    end

    if plan.extras != [] do
      Mix.shell().info("")
      Mix.shell().info("Extra project states left unchanged:")

      Enum.each(plan.extras, fn state ->
        Mix.shell().info("  - #{state["name"]} [#{state["group"]}]")
      end)
    end

    if plan.warnings != [] do
      Mix.shell().info("")
      Mix.shell().info("Warnings:")

      Enum.each(plan.warnings, fn warning ->
        Mix.shell().info("  - #{warning}")
      end)
    end

    Mix.shell().info("")
    Mix.shell().info("Suggested Symphony config:")
    Mix.shell().info("  active_states: [\"Todo\", \"In Progress\"]")
    Mix.shell().info("  terminal_states: [\"Done\", \"Cancelled\", \"Canceled\"]")

    if plan.include_review_loop do
      Mix.shell().info("  review-loop active_states: [\"Todo\", \"In Progress\", \"Merging\", \"Rework\"]")
      Mix.shell().info("  review-loop non-active handoff state: \"Human Review\"")
    else
      Mix.shell().info("  optional review-loop active_states: [\"Todo\", \"In Progress\", \"Merging\", \"Rework\"]")
      Mix.shell().info("  optional review-loop non-active handoff state: \"Human Review\"")
    end
  end

  defp print_section(title, section) do
    Mix.shell().info(title <> ":")

    cond do
      section.actions == [] and section.unchanged == [] ->
        Mix.shell().info("  - No matching states found.")

      true ->
        Enum.each(section.actions, fn action ->
          Mix.shell().info("  - #{String.capitalize(to_string(action.type))}: #{action.reason}")
          Mix.shell().info("    Purpose: #{action.purpose}")
        end)

        Enum.each(section.unchanged, fn state ->
          Mix.shell().info("  - Keep: #{state["name"]} [#{state["group"]}]")

          case StateSync.state_purpose(state["name"]) do
            purpose when is_binary(purpose) ->
              Mix.shell().info("    Purpose: #{purpose}")

            _ ->
              :ok
          end
        end)
    end
  end

  defp maybe_apply_changes(_config, _plan, true) do
    Mix.shell().info("")
    Mix.shell().info("Dry run only. No Plane changes were applied.")
  end

  defp maybe_apply_changes(config, plan, false) do
    actions = StateSync.actions_to_apply(plan)

    if actions == [] do
      Mix.shell().info("")
      Mix.shell().info("No Plane state changes were needed.")
    else
      Mix.shell().info("")
      Mix.shell().info("Applying #{length(actions)} Plane state change(s)...")

      case StateSync.apply_actions(config, actions) do
        {:ok, applied} ->
          Enum.each(applied, fn %{action: action, response: response} ->
            state_name = response["name"] || action.state_name
            group = response["group"] || action.group
            Mix.shell().info("  - Applied #{action.type}: #{state_name} [#{group}]")
          end)

          if not plan.include_review_loop and plan.optional_review_loop.actions != [] do
            Mix.shell().info("")
            Mix.shell().info("Optional review-loop states are available. Re-run with --with-review-loop to add Human Review, Merging, and Rework.")
          end

        {:error, {:plane_state_sync_failed, action, reason}} ->
          Mix.raise("Failed to apply #{action.type} for #{action.state_name}: #{inspect(reason)}")
      end
    end
  end
end

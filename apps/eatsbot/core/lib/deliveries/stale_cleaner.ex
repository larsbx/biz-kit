defmodule EatsbotCore.Deliveries.StaleCleaner do
  use GenServer
  require Logger
  alias EatsbotCore.Deliveries
  alias EatsbotCore.Deliveries.Delivery

  @actor Deliveries.Actors.admin()
  @days Application.compile_env(:eatsbot, :days_for_stale, 2)

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    if @days != 0 do
      run_cleanup()
      schedule_next_run()
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:run_cleanup, state) do
    run_cleanup()
    schedule_next_run()
    {:noreply, state}
  end

  defp schedule_next_run do
    now = NaiveDateTime.utc_now()
    next_run = next_x00_time(now)

    delay = NaiveDateTime.diff(next_run, now, :millisecond)
    Process.send_after(self(), :run_cleanup, delay)
  end

  # get next x:00 time
  defp next_x00_time(now) do
    next_hour = NaiveDateTime.add(now, 3600 - rem(now.minute * 60 + now.second, 3600), :second)
    NaiveDateTime.truncate(next_hour, :second)
  end

  defp run_cleanup do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Running Delivery cleanup at #{NaiveDateTime.utc_now()}")

    {success_count, error_count, errors} =
      Delivery.get_pending_stale!(nil, actor: @actor)
      |> Enum.reduce({0, 0, []}, fn delivery, {success, errors, error_list} ->
        case process_stale_delivery(delivery) do
          {:ok, _} ->
            {success + 1, errors, error_list}

          {:error, reason} ->
            error_detail = %{
              delivery_id: delivery.id,
              state: delivery.state,
              reason: inspect(reason),
              timestamp: NaiveDateTime.utc_now()
            }

            Logger.error(
              "Failed to update delivery #{delivery.id} to stale: #{inspect(reason)}"
            )

            {success, errors + 1, [error_detail | error_list]}
        end
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Delivery cleanup completed: #{success_count} successful, #{error_count} failed, took #{elapsed}ms"
    )

    # Emit telemetry for monitoring
    :telemetry.execute(
      [:eatsbot, :delivery, :stale_cleanup],
      %{success_count: success_count, error_count: error_count, duration: elapsed},
      %{errors: errors}
    )

    if error_count > 0 do
      Logger.warning("Stale cleaner encountered #{error_count} errors: #{inspect(errors)}")
    end
  end

  # Process a single delivery with retry logic
  defp process_stale_delivery(delivery, retry_count \\ 0) do
    max_retries = 3

    try do
      result = make_stale!(delivery)
      {:ok, result}
    rescue
      e ->
        if retry_count < max_retries do
          Logger.warning(
            "Retry #{retry_count + 1}/#{max_retries} for delivery #{delivery.id}: #{Exception.message(e)}"
          )

          # Exponential backoff: 100ms, 200ms, 400ms
          Process.sleep(100 * :math.pow(2, retry_count))
          process_stale_delivery(delivery, retry_count + 1)
        else
          {:error, Exception.message(e)}
        end
    end
  end

  defp update_state!(delivery, state), do: Delivery.update_state!(delivery, state, actor: @actor)

  defp make_stale!(%{state: "Init"} = delivery),
    do: delivery |> update_state!("Delivery_Aborted") |> make_stale!()

  defp make_stale!(%{state: "In_Preparation"} = delivery),
    do: delivery |> update_state!("Delivery_Aborted") |> make_stale!()

  defp make_stale!(%{state: "Delivery_Aborted"} = delivery),
    do: delivery |> update_state!("Stale_Delivery_Aborted") |> make_stale!()

  defp make_stale!(%{state: "Ready_To_Pickup"} = delivery),
    do: delivery |> update_state!("Delivery_Aborted") |> make_stale!()

  defp make_stale!(%{state: "In_Delivery"} = delivery),
    do: delivery |> update_state!("Delivery_With_Problems") |> make_stale!()

  defp make_stale!(%{state: "Delivery_With_Problems"} = delivery),
    do: delivery |> update_state!("Stale_Delivery_With_Problems") |> make_stale!()

  defp make_stale!(%{state: "Delivery_Done"} = delivery),
    do: delivery |> update_state!("Stale_Delivery_Done") |> make_stale!()

  defp make_stale!(delivery), do: delivery
end

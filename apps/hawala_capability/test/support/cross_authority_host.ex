defmodule HawalaCapability.TestHost do
  @moduledoc """
  TEST-ONLY adapter for the pinned canonical model. Compiled only in MIX_ENV=test.
  Control events are a fault driver, not signed financial messages or grants.
  Three independent actor journals; there is no cross-store atomic append.
  """
  alias HawalaCapability.TestJournal, as: Journal

  @fields ~w(requested requestEpoch voteL voteR seenL seenR decision wire wireEpoch localL localR upC upL upR netL netR epoch installedL installedR recoveryWire fenceC fenceL fenceR recovered)
  @roles [
    coordinator:
      ~w(requested requestEpoch seenL seenR decision wire wireEpoch epoch recoveryWire fenceC recovered),
    left: ~w(voteL localL installedL fenceL),
    right: ~w(voteR localR installedR fenceR)
  ]
  @environment ~w(upC upL upR netL netR)
  @plain ~w(sendPrepare refuseL refuseR receiveL receiveR commit abort publish deliverL deliverR foreignAttempt foreignAuthority crashC restartC crashL restartL crashR restartR partitionL healL partitionR healR timeout fenceCoordinator fenceLeft fenceRight recoverLog publishRecovery installL installR activateL activateR recover)

  def fields, do: @fields

  def create(root) do
    with :ok <- File.mkdir(root), do: open(root, true)
  end

  def open_existing(root), do: open(root, false)

  defp open(root, create) do
    result =
      Enum.reduce_while(@roles, {:ok, %{}}, fn {role, keys}, {:ok, pids} ->
        initial = Map.new(keys, &{&1, 0})

        case Journal.start(Path.join(root, "#{role}.log"), role, initial, create) do
          {:ok, pid} ->
            {:cont, {:ok, Map.put(pids, role, pid)}}

          error ->
            Enum.each(pids, fn {_, pid} -> Journal.close(pid) end)
            {:halt, error}
        end
      end)

    with {:ok, pids} <- result do
      host = %{root: root, pids: pids, environment: Map.new(@environment, &{&1, 1})}

      if safe?(projection(host)),
        do: {:ok, host},
        else:
          (
            close(host)
            {:error, :hold_conflicting_history}
          )
    end
  end

  def close(host),
    do: Enum.each(host.pids, fn {_, pid} -> if Process.alive?(pid), do: Journal.close(pid) end)

  def reopen(host) do
    close(host)

    with {:ok, fresh} <- open_existing(host.root),
         do: {:ok, %{fresh | environment: host.environment}}
  end

  def projection(host), do: elem(snapshot(host), 0)

  defp snapshot(host) do
    Enum.reduce(host.pids, {host.environment, %{}}, fn {role, pid}, {result, versions} ->
      {version, local} = Journal.snapshot(pid)
      {Map.merge(result, local), Map.put(versions, role, version)}
    end)
  end

  def safe?(s) do
    Enum.all?(~w(voteL voteR decision wire localL localR), &(s[&1] in 0..2)) and
      (s["seenL"] == 0 or s["voteL"] == 1) and (s["seenR"] == 0 or s["voteR"] == 1) and
      (s["decision"] != 1 or (s["seenL"] == 1 and s["seenR"] == 1)) and
      Enum.all?(~w(wire localL localR), &(s[&1] == 0 or s[&1] == s["decision"])) and
      Enum.all?(~w(localL localR), &(s[&1] == 0 or s[&1] == s["wire"]))
  end

  def held?(host, side) do
    s = projection(host)

    case side do
      :left -> s["voteL"] == 1 and s["localL"] == 0
      :right -> s["voteR"] == 1 and s["localR"] == 0
    end
  end

  def parse(text) when is_binary(text) do
    cond do
      text in @plain ->
        {:ok, {text, []}}

      true ->
        case Regex.run(
               ~r/\A(prepare[LR])\((0|[1-9][0-9]*),(0|[1-9][0-9]*),(0|[1-9][0-9]*)\)\z/,
               text
             ) do
          [_, name | values] ->
            args = Enum.map(values, &String.to_integer/1)

            if Enum.all?(args, &(&1 <= 18_446_744_073_709_551_615)),
              do: {:ok, {name, args}},
              else: {:error, :invalid_integer}

          _ ->
            {:error, :unknown_event}
        end
    end
  end

  def parse(_), do: {:error, :unknown_event}

  defp role(name) do
    cond do
      name in ~w(prepareL refuseL deliverL foreignAttempt foreignAuthority fenceLeft installL activateL) ->
        :left

      name in ~w(prepareR refuseR deliverR fenceRight installR activateR) ->
        :right

      name in ~w(crashC restartC crashL restartL crashR restartR partitionL healL partitionR healR) ->
        nil

      true ->
        :coordinator
    end
  end

  def apply(host, id, text) do
    try do
      do_apply(host, id, text)
    catch
      :exit, _ -> {:error, {:hold, :unavailable_actor}}
    end
  end

  defp do_apply(host, id, text) do
    with {:ok, {name, args}} <- parse(text) do
      {before, versions} = snapshot(host)

      if safe?(before) do
        next = reduce(before, name, args)

        case persist(host, role(name), id, text, next, versions) do
          {:ok, receipt} ->
            updated =
              if receipt != nil and receipt.replayed,
                do: host,
                else: %{host | environment: Map.take(next, @environment)}

            if safe?(projection(updated)),
              do: {:ok, updated, receipt},
              else: {:error, :hold_conflict}

          error ->
            error
        end
      else
        {:error, :hold_conflict}
      end
    end
  end

  defp persist(_host, nil, _id, _text, _next, _versions), do: {:ok, nil}

  defp persist(host, role, id, text, next, versions) do
    pid = host.pids[role]
    Journal.apply(pid, id, text, versions[role], Map.take(next, @roles[role]))
  end

  defp put(s, condition, values), do: if(condition, do: Map.merge(s, Map.new(values)), else: s)

  defp reduce(s, "prepare" <> side, [ctx, ae, ce]) do
    vote = "vote" <> side
    local = "local" <> side
    up = "up" <> side
    net = "net" <> side
    fence = "fence" <> side

    put(
      s,
      ctx == 0 and ae == 0 and ce == s["epoch"] and s["requested"] == 1 and
        ce == s["requestEpoch"] and s[up] == 1 and s[net] == 1 and s[fence] == 0 and s[local] == 0 and
        s[vote] == 0,
      [{vote, 1}]
    )
  end

  defp reduce(s, "sendPrepare", _),
    do:
      put(s, s["upC"] == 1 and s["fenceC"] == 0 and s["decision"] == 0, [
        {"requested", 1},
        {"requestEpoch", s["epoch"]}
      ])

  defp reduce(s, "refuse" <> side, _),
    do: put(s, s["up" <> side] == 1 and s["vote" <> side] == 0, [{"vote" <> side, 2}])

  defp reduce(s, "receive" <> side, _),
    do:
      put(s, s["upC"] == 1 and s["net" <> side] == 1 and s["vote" <> side] == 1, [
        {"seen" <> side, 1}
      ])

  defp reduce(s, "commit", _),
    do:
      put(
        s,
        s["upC"] == 1 and s["fenceC"] == 0 and s["decision"] == 0 and s["seenL"] == 1 and
          s["seenR"] == 1,
        [{"decision", 1}]
      )

  defp reduce(s, "abort", _),
    do: put(s, s["upC"] == 1 and s["fenceC"] == 0 and s["decision"] == 0, [{"decision", 2}])

  defp reduce(s, "publish", _),
    do:
      put(s, s["upC"] == 1 and s["fenceC"] == 0 and s["wire"] == 0 and s["decision"] != 0, [
        {"wire", s["decision"]},
        {"wireEpoch", s["epoch"]}
      ])

  defp reduce(s, "deliver" <> side, _),
    do:
      put(
        s,
        s["up" <> side] == 1 and s["net" <> side] == 1 and s["wire"] != 0 and
          s["wireEpoch"] <= s["epoch"],
        [{"local" <> side, s["wire"]}]
      )

  defp reduce(s, "foreignAttempt", _), do: s
  defp reduce(s, "foreignAuthority", _), do: s
  defp reduce(s, "timeout", _), do: s
  defp reduce(s, "crash" <> side, _), do: Map.put(s, "up" <> side, 0)
  defp reduce(s, "restartC", _), do: put(s, s["fenceC"] == 0, [{"upC", 1}])
  defp reduce(s, "restart" <> side, _), do: Map.put(s, "up" <> side, 1)
  defp reduce(s, "partition" <> side, _), do: Map.put(s, "net" <> side, 0)
  defp reduce(s, "heal" <> side, _), do: Map.put(s, "net" <> side, 1)

  defp reduce(s, "fenceCoordinator", _),
    do: Map.merge(s, %{"fenceC" => 1, "upC" => 0, "recovered" => 0})

  defp reduce(s, "fenceLeft", _),
    do: put(s, s["fenceC"] == 1 and s["upL"] == 1 and s["netL"] == 1, [{"fenceL", 1}])

  defp reduce(s, "fenceRight", _),
    do: put(s, s["fenceC"] == 1 and s["upR"] == 1 and s["netR"] == 1, [{"fenceR", 1}])

  defp reduce(s, "recoverLog", _), do: put(s, s["fenceC"] == 1, [{"recovered", 1}])

  defp reduce(s, "publishRecovery", _),
    do:
      put(s, s["fenceC"] == 1 and s["fenceL"] == 1 and s["fenceR"] == 1 and s["recovered"] == 1, [
        {"recoveryWire", 1}
      ])

  defp reduce(s, "install" <> side, _),
    do:
      put(s, s["recoveryWire"] == 1 and s["up" <> side] == 1 and s["net" <> side] == 1, [
        {"installed" <> side, 1}
      ])

  defp reduce(s, "recover", _),
    do:
      put(
        s,
        s["fenceC"] == 1 and s["fenceL"] == 1 and s["fenceR"] == 1 and s["recovered"] == 1 and
          s["installedL"] == 1 and s["installedR"] == 1 and s["epoch"] == 0,
        [{"epoch", 1}, {"upC", 1}, {"fenceC", 0}]
      )

  defp reduce(s, "activate" <> side, _),
    do:
      put(
        s,
        s["epoch"] == 1 and s["installed" <> side] == 1 and s["up" <> side] == 1 and
          s["net" <> side] == 1,
        [{"fence" <> side, 0}]
      )

  def workflow_gate(verified, stage, action) when is_boolean(verified) do
    if stage in ~w(proposed committed executed settled held aborted) and
         action in ~w(recordProposal reserveCancelableOrder checkoutFulfill dispatchPaid groupBuyRelease remittanceDelivered) do
      {:ok,
       verified and stage not in ~w(held aborted) and
         (action == "recordProposal" or stage == "settled" or
            (action == "reserveCancelableOrder" and stage in ~w(committed executed)))}
    else
      {:error, :unknown_workflow_input}
    end
  end

  def workflow_gate(_, _, _), do: {:error, :unknown_workflow_input}
end

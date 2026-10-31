<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import {
    type AppInfo,
    type BoardLoad,
    type BoardTrip,
    type DispatchStatus,
    type Fleet,
    type Problem,
    type RoleChoice,
    dispatchRequest,
    dispatchSignIn,
    dispatchSignOut,
    dispatchStatus,
  } from "../api";
  import { confirm } from "../confirmation.svelte";

  let { info }: { info: AppInfo } = $props();

  const ROLE_KEY = "dispatch.roleAssignmentId";
  const STATUSES = ["DRAFT", "TENDERED", "BOOKED", "IN_TRANSIT", "DELIVERED", "CANCELLED"] as const;

  let status = $state<DispatchStatus | null>(null);
  let roles = $state<RoleChoice[]>([]);
  let role = $state<string>(localStorage.getItem(ROLE_KEY) ?? "");
  let loads = $state<BoardLoad[]>([]);
  let fleet = $state<Fleet>({ drivers: [], vehicles: [], trailers: [] });
  let selectedId = $state<string | null>(null);
  let filter = $state<"open" | "all">("open");
  let q = $state("");
  let busy = $state(false);
  let err = $state<string | null>(null);

  // Forms. Each is reset after a successful write.
  let newLoad = $state({ external_reference: "", commodity_text: "" });
  let edit = $state<{ external_reference: string; commodity_text: string } | null>(null);
  let newStop = $state(blankStop());
  let newTrip = $state(blankTrip());

  function blankStop() {
    return { kind: "PICKUP", address_text: "", window_start: "", window_end: "", contact_name: "", contact_phone_e164: "" };
  }
  function blankTrip() {
    return { operator_participant_id: "", vehicle_id: "", trailer_id: "", starts_at: "" };
  }

  const selected = $derived(loads.find((l) => l.load_id === selectedId) ?? null);
  const driverName = $derived(new Map(fleet.drivers.map((d) => [d.participant_id, d.public_name])));
  const unitName = $derived(
    new Map([...fleet.vehicles, ...fleet.trailers].map((u) => [u.id, u.unit_number])),
  );

  const shown = $derived.by(() => {
    const needle = q.trim().toLowerCase();
    return loads
      .filter((l) => filter === "all" || !["DELIVERED", "CANCELLED"].includes(l.status))
      .filter(
        (l) =>
          !needle ||
          [l.external_reference, l.commodity_text, ...l.stops.map((s) => s.address_text)]
            .some((t) => t?.toLowerCase().includes(needle)),
      );
  });

  function problem(body: unknown, status: number) {
    const p = body as Partial<Problem> | null;
    return p?.detail ? `${p.detail}${p.code ? ` (${p.code})` : ""}` : `HTTP ${status}`;
  }

  /** One call to /v1 as the selected role; throws a readable message on refusal. */
  async function api<T>(method: "GET" | "POST" | "PATCH", path: string, body?: unknown): Promise<T> {
    const reply = await dispatchRequest<T>(method, path, {
      body,
      roleAssignmentId: role || undefined,
      // A fresh key per user action: a retry inside the backend replays it,
      // a second click is a second request.
      idempotencyKey: method === "GET" ? undefined : crypto.randomUUID(),
    });
    if (reply.status === 401) {
      status = await dispatchStatus();
      throw new Error("Signed out. Sign in again.");
    }
    if (reply.status >= 400) throw new Error(problem(reply.body, reply.status));
    return reply.body;
  }

  async function refresh() {
    if (!status?.signedIn) return;
    busy = true;
    err = null;
    try {
      const list = await api<{ role_assignments: RoleChoice[] }>("GET", "/v1/me/role-assignments");
      roles = list.role_assignments;
      if (!roles.some((r) => r.id === role)) role = roles.length === 1 ? roles[0].id : "";
      if (!role) {
        loads = [];
        return;
      }
      const [board, f] = await Promise.all([
        api<{ loads: BoardLoad[] }>("GET", "/v1/operations/loads"),
        api<Fleet>("GET", "/v1/operations/fleet"),
      ]);
      loads = board.loads;
      fleet = f;
      if (selectedId && !loads.some((l) => l.load_id === selectedId)) selectedId = null;
    } catch (e) {
      err = String(e instanceof Error ? e.message : e);
    } finally {
      busy = false;
    }
  }

  /** Runs a write and puts the load it returns in place. */
  async function write(run: () => Promise<BoardLoad>, after?: () => void) {
    busy = true;
    err = null;
    try {
      const load = await run();
      const i = loads.findIndex((l) => l.load_id === load.load_id);
      if (i >= 0) loads[i] = load;
      else loads = [load, ...loads];
      selectedId = load.load_id;
      after?.();
    } catch (e) {
      err = String(e instanceof Error ? e.message : e);
    } finally {
      busy = false;
    }
  }

  const blank = (s: string) => (s.trim() === "" ? null : s.trim());
  const iso = (local: string) => (local ? new Date(local).toISOString() : null);

  function createLoad() {
    write(
      () =>
        api<BoardLoad>("POST", "/v1/operations/loads", {
          external_reference: blank(newLoad.external_reference),
          commodity_text: blank(newLoad.commodity_text),
        }),
      () => (newLoad = { external_reference: "", commodity_text: "" }),
    );
  }

  function saveLoad(load: BoardLoad) {
    if (!edit) return;
    const body = {
      external_reference: blank(edit.external_reference),
      commodity_text: blank(edit.commodity_text),
      expected_version: load.version,
    };
    write(() => api<BoardLoad>("PATCH", `/v1/operations/loads/${load.load_id}`, body), () => (edit = null));
  }

  function addStop(load: BoardLoad) {
    const s = newStop;
    write(
      () =>
        api<BoardLoad>("POST", `/v1/operations/loads/${load.load_id}/stops`, {
          kind: s.kind,
          address_text: s.address_text.trim(),
          window_start: iso(s.window_start),
          window_end: iso(s.window_end),
          contact_name: blank(s.contact_name),
          contact_phone_e164: blank(s.contact_phone_e164),
        }),
      () => (newStop = blankStop()),
    );
  }

  function planTrip(load: BoardLoad) {
    const t = newTrip;
    write(
      () =>
        api<BoardLoad>("POST", `/v1/operations/loads/${load.load_id}/trips`, {
          operator_participant_id: t.operator_participant_id,
          vehicle_id: blank(t.vehicle_id),
          trailer_id: blank(t.trailer_id),
          starts_at: iso(t.starts_at),
        }),
      () => (newTrip = blankTrip()),
    );
  }

  function move(trip: BoardTrip, action: "activate" | "complete" | "cancel") {
    const run = () =>
      write(() =>
        api<BoardLoad>("POST", `/v1/operations/trips/${trip.assignment_id}/transitions`, {
          action,
          expected_version: trip.version,
        }),
      );
    if (action === "activate") return run();
    confirm({
      title: `${action === "cancel" ? "Cancel" : "Complete"} ${driverName.get(trip.operator_participant_id) ?? "this driver"}'s trip?`,
      why: "This ends the trip, and with it any location sharing that covered it. It cannot be undone.",
      command: `POST /v1/operations/trips/${trip.assignment_id}/transitions\n{"action": "${action}", "expected_version": ${trip.version}}`,
      danger: true,
      run: async () => {
        await run();
        if (err) throw new Error(err);
      },
    });
  }

  async function signIn() {
    busy = true;
    err = null;
    try {
      await dispatchSignIn();
      status = await dispatchStatus();
      await refresh();
    } catch (e) {
      err = String(e);
    } finally {
      busy = false;
    }
  }

  async function signOut() {
    await dispatchSignOut();
    status = await dispatchStatus();
    loads = [];
    roles = [];
    selectedId = null;
  }

  $effect(() => {
    try { if (role) localStorage.setItem(ROLE_KEY, role); } catch { /* per-viewer nicety only */ }
  });

  let timer: ReturnType<typeof setInterval> | undefined;
  onMount(async () => {
    try {
      status = await dispatchStatus();
      await refresh();
    } catch (e) {
      err = String(e);
    }
    // The board changes under other dispatchers and drivers; keep it current.
    timer = setInterval(() => { if (!busy) refresh(); }, 20_000);
  });
  onDestroy(() => clearInterval(timer));

  const fmt = (t: string | null) => (t ? new Date(t).toLocaleString([], { dateStyle: "short", timeStyle: "short" }) : "—");
  const tripClass = (s: string) => (s === "ACTIVE" ? "ok" : s === "CANCELLED" ? "bad" : s === "PLANNED" ? "warn" : "");
  const loadClass = (s: string) => (s === "IN_TRANSIT" ? "ok" : s === "CANCELLED" ? "bad" : s === "DRAFT" ? "" : "warn");
  const activeTrip = (l: BoardLoad) => l.trips.find((t) => t.status === "ACTIVE") ?? l.trips.find((t) => t.status === "PLANNED");
</script>

<div class="bar">
  <h1>Dispatch</h1>
  {#if status?.signedIn && roles.length > 1}
    <select class="btn" bind:value={role} onchange={refresh}>
      <option value="" disabled>Choose a role…</option>
      {#each roles as r (r.id)}<option value={r.id}>{r.label}</option>{/each}
    </select>
  {/if}
  {#if status?.signedIn && role}
    <div class="chips">
      <button class={"chip" + (filter === "open" ? " on" : "")} onclick={() => (filter = "open")}>open</button>
      <button class={"chip" + (filter === "all" ? " on" : "")} onclick={() => (filter = "all")}>all</button>
    </div>
    <input type="text" placeholder="Filter…" bind:value={q} style="width: 13rem" />
  {/if}
  <div class="spacer"></div>
  {#if status?.signedIn}
    <button class="btn" onclick={refresh} disabled={busy}>{busy ? "Loading…" : "Refresh"}</button>
    <button class="btn" onclick={signOut} disabled={busy}>Sign out</button>
  {/if}
</div>

<div class="body">
  {#if err}<p class="err">{err}</p>{/if}

  {#if !status}
    <div class="empty">Loading…</div>
  {:else if !status.api}
    <div class="empty">
      Dispatch is not configured. Add a <code class="mono">dispatch</code> section to
      <code class="mono">{info.configPath}</code>:
      <pre class="out" style="text-align: left; margin-top: 8px">{`"dispatch": {
  "api": "http://localhost:4000",
  "auth": "http://127.0.0.1:4001",
  "provider": "dispatcher"
}`}</pre>
    </div>
  {:else if !status.signedIn}
    <div class="empty">
      <p>Sign in to dispatch at <code class="mono">{status.api}</code>. Your browser opens to finish.</p>
      <button class="btn go" onclick={signIn} disabled={busy}>{busy ? "Waiting for the browser…" : "Sign in"}</button>
    </div>
  {:else if !role}
    <div class="empty">{roles.length ? "Choose the role to act under." : "This account holds no dispatch role."}</div>
  {:else}
    <div class="board">
      <section class="list">
        <form class="card new" onsubmit={(e) => { e.preventDefault(); createLoad(); }}>
          <h3>New load</h3>
          <input type="text" placeholder="Reference (PO, BOL…)" bind:value={newLoad.external_reference} />
          <input type="text" placeholder="Commodity" bind:value={newLoad.commodity_text} />
          <button class="btn go" disabled={busy}>Create</button>
        </form>

        {#if shown.length === 0}<div class="empty">No {filter === "open" ? "open " : ""}loads.</div>{/if}
        {#each shown as l (l.load_id)}
          {@const trip = activeTrip(l)}
          <button class={"load" + (l.load_id === selectedId ? " on" : "")} onclick={() => { selectedId = l.load_id; edit = null; }}>
            <div class="row">
              <strong class="trunc">{l.external_reference || l.commodity_text || "Untitled load"}</strong>
              <div class="spacer"></div>
              <span class={"pill " + loadClass(l.status)}>{l.status.replace("_", " ").toLowerCase()}</span>
            </div>
            <div class="sub trunc">
              {l.stops.length ? `${l.stops[0].address_text}${l.stops.length > 1 ? ` → ${l.stops[l.stops.length - 1].address_text}` : ""}` : "no stops"}
            </div>
            <div class="sub">
              {#if trip}
                <span class={"pill " + tripClass(trip.status)}>{trip.status.toLowerCase()}</span>
                {driverName.get(trip.operator_participant_id) ?? "driver"}
              {:else}
                unplanned
              {/if}
            </div>
          </button>
        {/each}
      </section>

      <section class="detail">
        {#if !selected}
          <div class="empty">Select a load, or create one.</div>
        {:else}
          {@const l = selected}
          <div class="card">
            <div class="row">
              <h3 style="margin: 0">{l.external_reference || "Untitled load"}</h3>
              <span class={"pill " + loadClass(l.status)}>{l.status.replace("_", " ").toLowerCase()}</span>
              <div class="spacer"></div>
              {#if !edit}
                <button class="btn" onclick={() => (edit = { external_reference: l.external_reference ?? "", commodity_text: l.commodity_text ?? "" })}>Edit</button>
              {/if}
            </div>
            {#if edit}
              <form class="grid" onsubmit={(e) => { e.preventDefault(); saveLoad(l); }}>
                <label>Reference <input type="text" bind:value={edit.external_reference} /></label>
                <label>Commodity <input type="text" bind:value={edit.commodity_text} /></label>
                <div class="row">
                  <button class="btn go" disabled={busy}>Save</button>
                  <button type="button" class="btn" onclick={() => (edit = null)}>Cancel</button>
                </div>
              </form>
            {:else}
              <div class="kv"><span>commodity</span><span>{l.commodity_text || "—"}</span></div>
              <div class="kv"><span>created</span><span>{fmt(l.created_at)}</span></div>
              <div class="kv"><span>load id</span><span class="mono">{l.load_id}</span></div>
            {/if}
          </div>

          <div class="card">
            <h3>Stops</h3>
            {#if l.stops.length === 0}<div class="sub">No stops yet.</div>{/if}
            <ol class="stops">
              {#each l.stops as s (s.stop_id)}
                <li>
                  <span class="pill">{s.kind.toLowerCase()}</span>
                  <strong>{s.address_text}</strong>
                  {#if s.window_start || s.window_end}<span class="sub">{fmt(s.window_start)} – {fmt(s.window_end)}</span>{/if}
                  {#if s.contact_name || s.contact_phone_e164}
                    <span class="sub">{s.contact_name ?? ""} {s.contact_phone_e164 ?? ""}</span>
                  {/if}
                </li>
              {/each}
            </ol>
            <form class="grid" onsubmit={(e) => { e.preventDefault(); addStop(l); }}>
              <label>Kind
                <select class="btn" bind:value={newStop.kind}>
                  <option>PICKUP</option><option>DELIVERY</option><option>OTHER</option>
                </select>
              </label>
              <label class="wide">Address <input type="text" required bind:value={newStop.address_text} /></label>
              <label>Window from <input type="datetime-local" bind:value={newStop.window_start} /></label>
              <label>to <input type="datetime-local" bind:value={newStop.window_end} /></label>
              <label>Contact <input type="text" bind:value={newStop.contact_name} /></label>
              <label>Phone <input type="tel" placeholder="+15551234567" bind:value={newStop.contact_phone_e164} /></label>
              <div class="row"><button class="btn go" disabled={busy || !newStop.address_text.trim()}>Add stop</button></div>
            </form>
          </div>

          <div class="card">
            <h3>Trips</h3>
            {#if l.trips.length === 0}<div class="sub">Not planned yet.</div>{/if}
            {#if l.trips.length}
              <table>
                <thead><tr><th>driver</th><th>equipment</th><th>status</th><th>start</th><th>end</th><th></th></tr></thead>
                <tbody>
                  {#each l.trips as t (t.assignment_id)}
                    <tr>
                      <td>{driverName.get(t.operator_participant_id) ?? t.operator_participant_id.slice(0, 8)}</td>
                      <td class="mono">{[t.vehicle_id, t.trailer_id].filter(Boolean).map((id) => unitName.get(id!) ?? "?").join(" + ") || "—"}</td>
                      <td><span class={"pill " + tripClass(t.status)}>{t.status.toLowerCase()}</span></td>
                      <td>{fmt(t.starts_at)}</td>
                      <td>{fmt(t.ends_at)}</td>
                      <td>
                        <div class="row" style="justify-content: flex-end">
                          {#if t.status === "PLANNED"}
                            <button class="btn go" disabled={busy} onclick={() => move(t, "activate")}>Start</button>
                          {/if}
                          {#if t.status === "ACTIVE"}
                            <button class="btn" disabled={busy} onclick={() => move(t, "complete")}>Complete</button>
                          {/if}
                          {#if t.status === "PLANNED" || t.status === "ACTIVE"}
                            <button class="btn danger" disabled={busy} onclick={() => move(t, "cancel")}>Cancel</button>
                          {/if}
                        </div>
                      </td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            {/if}
            <form class="grid" onsubmit={(e) => { e.preventDefault(); planTrip(l); }}>
              <label>Driver
                <select class="btn" required bind:value={newTrip.operator_participant_id}>
                  <option value="" disabled>Choose…</option>
                  {#each fleet.drivers as d (d.participant_id)}<option value={d.participant_id}>{d.public_name}</option>{/each}
                </select>
              </label>
              <label>Vehicle
                <select class="btn" bind:value={newTrip.vehicle_id}>
                  <option value="">none</option>
                  {#each fleet.vehicles as v (v.id)}<option value={v.id}>{v.unit_number}{v.plate ? ` · ${v.plate}` : ""}</option>{/each}
                </select>
              </label>
              <label>Trailer
                <select class="btn" bind:value={newTrip.trailer_id}>
                  <option value="">none</option>
                  {#each fleet.trailers as v (v.id)}<option value={v.id}>{v.unit_number}{v.plate ? ` · ${v.plate}` : ""}</option>{/each}
                </select>
              </label>
              <label>Starts <input type="datetime-local" bind:value={newTrip.starts_at} /></label>
              <div class="row"><button class="btn go" disabled={busy || !newTrip.operator_participant_id}>Plan trip</button></div>
            </form>
            {#if fleet.drivers.length === 0}<div class="sub">No drivers in this organization.</div>{/if}
          </div>
        {/if}
      </section>
    </div>
  {/if}
</div>

<style>
  .board {
    display: grid;
    grid-template-columns: minmax(18rem, 24rem) 1fr;
    gap: 16px;
    align-items: start;
  }
  @media (max-width: 760px) {
    .board { grid-template-columns: 1fr; }
  }
  .list { display: flex; flex-direction: column; gap: 6px; }
  .detail { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
  .new { display: flex; flex-direction: column; gap: 6px; }
  .new h3 { margin: 0; }
  .load {
    text-align: left;
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: .6rem .75rem;
    color: inherit;
    font: inherit;
    cursor: pointer;
    display: flex;
    flex-direction: column;
    gap: 3px;
    min-width: 0;
  }
  .load.on { border-color: var(--accent); box-shadow: inset 3px 0 0 var(--accent); }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr));
    gap: 8px;
    margin-top: 10px;
    align-items: end;
  }
  .grid label { display: flex; flex-direction: column; gap: 3px; font-size: .92rem; color: var(--dim); }
  .grid .wide { grid-column: span 2; }
  .grid input, .grid select { width: 100%; box-sizing: border-box; }
  .stops { margin: 6px 0 0; padding-left: 20px; display: flex; flex-direction: column; gap: 6px; }
  .stops li { display: flex; flex-wrap: wrap; gap: 6px; align-items: baseline; }
  .detail table { margin-top: 6px; }
  .load .sub, .stops .sub { color: var(--dim); font-size: .85rem; }
</style>

// Shared drawing code for the app window, the OBS overlay and the OBS dock.

const SOURCES = ["Off", "Random (RNG)", "Lobby votes", "Twitch votes"];

function esc(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function meterLabel(m) {
  if (m >= 60) return ["Cursed", "hinder"];
  if (m >= 25) return ["Greedy", "hinder"];
  if (m <= -60) return ["Blessed", "help"];
  if (m <= -25) return ["Lucky", "help"];
  return ["Fair", ""];
}

// Live state: the app window asks Rust directly; OBS pages ask the local server.
async function fetchState() {
  // Pages served by the app's web server (OBS, and the style preview inside the app window) use /state.
  // Tauri also exposes __TAURI__ to that embedded preview, but it isn't allowed to call commands, so check origin.
  const served = location.protocol === "http:" && location.port === "7480";
  if (window.__TAURI__ && !served) return window.__TAURI__.core.invoke("get_state");
  const r = await fetch("/state", { cache: "no-store" });
  return r.json();
}

// The vote panel. Returns "" when no vote is open.
function voteHtml(s) {
  const g = s.game;
  if (!s.gameOnline || g.phase !== 2 || !g.options.length) return "";
  const counts = s.votes.shown;
  const total = counts.reduce((a, b) => a + b, 0);
  const lead = Math.max(...counts.slice(0, g.options.length));
  const pct = g.total > 0 ? Math.max(0, Math.min(100, (g.secs / g.total) * 100)) : 0;
  const how = g.source === 3 ? `Type 1-${g.options.length} in chat` : `Type /vote 1-${g.options.length} in game`;
  const rows = g.options.map((o, i) => {
    const c = counts[i] || 0;
    const share = total > 0 ? (c / total) * 100 : 0;
    const kind = o.kind === "help" ? "help" : "hinder";
    const leading = c > 0 && c === lead;
    return `<div class="row ${kind} ${leading ? "leading" : ""}">
      <div class="fill" style="width:${share}%"></div>
      <span class="num">${i + 1}</span>
      <span class="name">${esc(o.name)}</span>
      ${leading ? '<span class="star">&#9733;</span>' : ""}
      <span class="kind ${kind}">${kind}</span>
      <span class="count">${c}</span>
    </div>`;
  }).join("");
  // each title letter is its own span so themes can colour them (the Mario 64 style does)
  const title = [..."CHAOS VOTE"].map((ch) => ch === " " ? '<span class="gap"> </span>' : `<span class="l">${ch}</span>`).join("");
  return `<div class="vote">
    <div class="vote-title"><h2 class="title">${title}</h2><span class="how">${how} &middot; <b class="secs">${g.secs}s</b></span></div>
    <div class="timer"><div style="width:${pct}%"></div></div>
    ${rows}
  </div>`;
}

// Fake vote used by the style preview when no real vote is open.
function sampleState(numOptions) {
  const names = [["Moon Gravity", "help"], ["Meteor Shower", "hinder"], ["Speed Boost", "help"], ["Drunk", "hinder"],
    ["Coin Shower", "help"], ["Blizzard", "hinder"], ["Hover Boots", "help"], ["Lights Out", "hinder"], ["Rainbow Star", "help"]];
  const n = Math.max(1, Math.min(9, numOptions || 4));
  const shown = [7, 12, 3, 5, 2, 4, 1, 6, 0];
  return {
    gameOnline: true,
    game: { phase: 2, source: 3, secs: 12, total: 20, options: names.slice(0, n).map(([name, kind], i) => ({ id: "p" + i, name, kind })) },
    votes: { shown },
  };
}

function cooldownHtml(s) {
  const g = s.game;
  if (!s.gameOnline || g.phase === 2 || g.source === 0) return "";
  if (g.paused) return `<div class="cooldown">Chaos paused: boss fight!</div>`;
  return `<div class="cooldown">Next chaos in <b>${g.secs}s</b></div>`;
}

function statsHtml(s) {
  const g = s.game;
  const [luck, luckClass] = meterLabel(g.meter || 0);
  const card = (label, value, cls = "") => `<div class="card"><div class="label">${label}</div><div class="value ${cls}">${value}</div></div>`;
  const active = (g.active || []).map((a) =>
    `<div class="item"><span class="${a.kind === "help" ? "help" : "hinder"}">${esc(a.name)}</span><span class="muted">${a.secs}s</span></div>`).join("")
    || `<div class="item muted">Nothing active</div>`;
  const recent = (s.recent || []).map((r) =>
    `<div class="item"><span>${esc(r.user)}</span><span>voted <b>${r.vote}</b></span></div>`).join("")
    || `<div class="item muted">No chat votes yet this round</div>`;
  return `
    <div class="cards">
      ${card("Twitch chat", `<span class="dot ${s.chat.connected ? "on" : ""}"></span>${s.chat.connected ? "On" : "Off"}`)}
      ${card("Game", `<span class="dot ${s.gameOnline ? "on" : ""}"></span>${s.gameOnline ? "Hosting" : "Not found"}`)}
      ${card("Mode", s.gameOnline ? SOURCES[g.source] || "?" : "-")}
      ${card("Streak", g.streak ?? 0, (g.streak || 0) >= 3 ? "hinder" : "")}
      ${card("Best streak", g.best_streak ?? 0)}
      ${card("Effects fired", g.fired ?? 0)}
      ${card("Lobby luck", luck, luckClass)}
      ${card("Chat votes", s.votes.twitchTotal ?? 0)}
      ${card("You are", s.gameOnline ? ({ host: "Host", cohost: "Co-host", player: "Player" }[g.role] || "-") : "-")}
    </div>
    ${peopleHtml(s)}
    <div class="section"><h3>Active effects</h3><div class="list">${active}</div></div>
    <div class="section"><h3>Latest chat votes</h3><div class="list">${recent}</div></div>
    <div class="section"><h3>Last effect</h3><div class="list"><div class="item">${esc(g.last_effect || "-")}</div></div></div>`;
}

// Host and co-hosts: Twitch name when their app is running, otherwise their in-game name.
function peopleHtml(s) {
  const people = (s.gameOnline && s.game.people) || [];
  if (!people.length) return "";
  const rows = people.map((p) => {
    const status = p.connected === 1 ? "app connected" : p.connected === 0 ? "in game, app not connected" : "not in the game";
    const other = p.display.toLowerCase() !== p.game_name.toLowerCase() ? ` <span class="muted">(${esc(p.game_name)})</span>` : "";
    return `<div class="item"><span><span class="dot ${p.connected === 1 ? "on" : ""}"></span>${p.role === "host" ? "&#9733; " : ""}${esc(p.display)}${other}</span>
      <span class="muted">${status}${p.connected === 1 ? ` &middot; <b>${p.votes}</b> votes` : ""}</span></div>`;
  }).join("");
  return `<div class="section"><h3>Host and co-hosts</h3><div class="list">${rows}</div></div>`;
}

// Refresh `draw(state)` 4 times a second.
function live(draw) {
  const tick = async () => {
    try { draw(await fetchState()); } catch (e) { /* app or game not ready yet */ }
  };
  tick();
  setInterval(tick, 250);
}

// Lanes landing, prototype. The scroll story drives a replica of the Lanes
// window from one number: how far through the story section you are.
// Everything else on the page works without this file.

const $ = (s, el = document) => el.querySelector(s);
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, t) => a + (b - a) * clamp(t);
const range = (v, a, b) => clamp((v - a) / (b - a));
const smooth = (t) => t * t * (3 - 2 * t);

// The app's profile swatches (Shared.swift, dark appearance).
const COLORS = {
  orange: "#D97857", red: "#DB5752", yellow: "#CCA140", green: "#5CB06B",
  teal: "#45A69E", blue: "#548FD4", purple: "#9E78D4", pink: "#D46B9E",
};

// Minutes are counted from 09:00 on the simulated day. Each 5-hour window
// starts at `start` and resets at start + 300.
const PROFILES = [
  { num: "01", name: "Default", color: "orange", running: false, note: "main install", start: 5,
    h5: () => 52, wk: () => 71, wkPace: 0.58, wkReset: "Sat 12:54" },
  { num: "02", name: "Work", color: "blue", running: true, start: 0,
    h5: (c) => (c >= 300 ? 0 : 9 + 79 * smooth(range(c, 20, 225)) + Math.max(0, c - 225) * 0.02),
    wk: (c) => (c >= 300 ? 63 : 55 + 8 * range(c, 20, 240)), wkPace: 0.6, wkReset: "Fri 16:54" },
  { num: "03", name: "Studio", color: "green", running: true, start: 10,
    h5: (c) => 31 + 7 * range(c, 20, 240), wk: () => 12, wkPace: 0.14, wkReset: "Tue 09:54" },
  { num: "04", name: "Personal", color: "purple", running: false, signedOut: true },
];

const spark = '<svg aria-hidden="true"><use href="#spark"/></svg>';
const meter = (cls, label) => `
  <div class="m ${cls}">
    <div class="mh"><span>${label}</span><b>0%</b></div>
    <div class="bar"><i class="fill"></i><i class="pace"></i></div>
    <small></small>
  </div>`;

// ---------- build the window and the menu bar panel ----------
const rowsEl = $("#rows");
const pnList = $("#pnList");
for (const p of PROFILES) {
  const c = COLORS[p.color];
  const row = document.createElement("div");
  row.className = "row" + (p.running ? " running" : "");
  row.style.cssText = `--c:${c};--ci:${c}`;
  row.innerHTML = `
    <span class="num">${p.num}</span>
    <span class="ico">${spark}</span>
    <div class="who"><b>${p.name}</b><span class="badge">Most room</span>
      <small><i></i>${p.running ? "Running" : "Stopped"}${p.note ? `<span class="note"> · ${p.note}</span>` : ""}</small></div>
    ${p.signedOut
      ? '<div class="signin">⚠︎ Sign in to see usage</div>'
      : meter("m5", "5 hours") + meter("mw", "Week")}
    <button class="act" tabindex="-1">${p.running ? "Focus" : "Launch"}</button>`;
  rowsEl.append(row);
  p.row = row;

  if (!p.signedOut) {
    const pr = document.createElement("div");
    pr.className = "pn-row";
    pr.style.cssText = `--c:${c}`;
    pr.innerHTML = `<i></i><b>${p.name}</b>${meter("m5", "5 hours")}${meter("mw", "Week")}`;
    pnList.append(pr);
    p.pn = pr;
  }
}

const fmtClock = (c) => {
  const t = 9 * 60 + Math.round(c);
  return `Wed ${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
};
const fmtLeft = (m) => {
  m = Math.max(0, Math.round(m));
  return m < 60 ? `resets in ${m} min` : `resets in ${Math.floor(m / 60)}h ${m % 60}m`;
};
const level = (v) => (v >= 90 ? "crit" : v >= 75 ? "warn" : "");

function setMeter(el, value, pace, note) {
  if (!el) return;
  el.classList.toggle("warn", level(value) === "warn");
  el.classList.toggle("crit", level(value) === "crit");
  el.querySelector(".mh b").textContent = `${Math.round(value)}%`;
  const fill = el.querySelector(".fill");
  fill.style.width = value > 0 ? `max(7px, ${value}%)` : "0";
  const mark = el.querySelector(".pace");
  mark.style.opacity = pace == null ? 0 : 1;
  if (pace != null) mark.style.left = `${clamp(pace) * 100}%`;
  el.querySelector("small").textContent = note;
}

// ---------- the timeline ----------
// p runs 0..1 while the stage is pinned. Chapters:
//   0 the track · 1 the clock · 2 most room · 3 reset
const CHAPTERS = [0, 0.2, 0.55, 0.78, 1];
function clockAt(p) {
  if (p < 0.2) return 20;
  if (p < 0.5) return lerp(20, 225, smooth(range(p, 0.2, 0.5)));
  if (p < 0.8) return lerp(225, 240, range(p, 0.5, 0.8));
  return lerp(240, 302, smooth(range(p, 0.8, 0.9)));
}

const story = $("#story");
const desk = $(".desk");
const caps = [...document.querySelectorAll(".cap")];
const railFills = [...document.querySelectorAll(".rail i")];
const panel = $("#panel");
const mbLanes = $("#mbLanes");
const toast80 = $("#toast80");
const toastReset = $("#toastReset");
let lastKey = "";

function render() {
  const vh = innerHeight;
  const top = story.getBoundingClientRect().top;
  const pinned = story.offsetHeight - vh;
  const p = clamp(-top / pinned);
  const arrive = clamp((vh - top) / vh); // 0 → 1 while the stage rises into view

  // Entrance: the desk, then each lane slides onto the track and fills up.
  desk.classList.toggle("in", arrive > 0.25);
  PROFILES.forEach((pr, i) => pr.row.classList.toggle("on", arrive > 0.4 + i * 0.1));
  const fillIn = smooth(range(arrive, 0.55, 1));

  const c = clockAt(p);
  const chapter = CHAPTERS.findIndex((v, i) => p >= v && p < CHAPTERS[i + 1]);
  const ch = chapter < 0 ? 3 : chapter;

  caps.forEach((el, i) => el.classList.toggle("on", i === ch));
  railFills.forEach((el, i) => (el.style.width = `${range(p, CHAPTERS[i], CHAPTERS[i + 1]) * 100}%`));

  // Usage
  let best = null;
  let busiest = 0;
  for (const pr of PROFILES) {
    if (pr.signedOut) continue;
    const h5 = pr.h5(c) * fillIn;
    const wk = pr.wk(c) * fillIn;
    const reset = pr.start + 300;
    const fresh = c >= reset;
    const pace = fresh ? null : range(c, pr.start, reset);
    const note5 = fresh ? "fresh window" : fmtLeft(reset - c);
    setMeter(pr.row.querySelector(".m5"), h5, pace, note5);
    setMeter(pr.row.querySelector(".mw"), wk, pr.wkPace, `resets ${pr.wkReset}`);
    setMeter(pr.pn.querySelector(".m5"), h5, pace, "");
    setMeter(pr.pn.querySelector(".mw"), wk, pr.wkPace, "");
    pr.cur = h5;
    if (!best || h5 < best.cur) best = pr;
    busiest = Math.max(busiest, h5);
  }
  for (const pr of PROFILES) pr.row.classList.toggle("most", pr === best && fillIn > 0.9);

  // Header, footer, menu bar
  const left = Math.round(100 - best.cur);
  const key = `${best.name}|${left}|${Math.round(c)}`;
  if (key !== lastKey) {
    lastKey = key;
    $("#whSub").textContent = `4 profiles · 2 running · most room in ${best.name} (${left}% left)`;
    $("#mbClock").textContent = fmtClock(c);
    $("#winFoot").textContent = `${fmtClock(c).slice(4)} · usage updated just now`;
    $("#pnName").textContent = best.name;
    $("#pnLeft").textContent = `${left}% of 5h left`;
    $("#pnBest").style.setProperty("--c", COLORS[best.color]);
    $("#pnBest").style.setProperty("--ci", COLORS[best.color]);
  }
  const gauges = PROFILES.filter((x) => !x.signedOut);
  gauges.forEach((x, i) => mbLanes.style.setProperty(`--g${i + 1}`, (x.cur / 100).toFixed(3)));
  $("#mbPct").textContent = `${Math.round(busiest)}%`;
  mbLanes.classList.toggle("warn", level(busiest) === "warn");
  mbLanes.classList.toggle("crit", level(busiest) === "crit");

  // Chapter moments
  const work = PROFILES[1];
  toast80.classList.toggle("on", ch === 1 && work.cur >= 80);
  const panelOn = p > 0.57 && p < 0.79;
  panel.classList.toggle("on", panelOn);
  mbLanes.classList.toggle("open", panelOn);
  const press = p > 0.66 && p < 0.71;
  $("#pnKey").classList.toggle("down", press);
  for (const pr of PROFILES) pr.row.classList.toggle("pressed", press && pr === best);
  toastReset.classList.toggle("on", c >= 300 && p < 0.99);
}

let queued = false;
const schedule = () => {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => { queued = false; render(); });
};
addEventListener("scroll", schedule, { passive: true });
addEventListener("resize", schedule);
render();

// ---------- nav border ----------
const nav = $(".nav");
addEventListener("scroll", () => nav.classList.toggle("scrolled", scrollY > 10), { passive: true });

// ---------- new lane maker ----------
const swatches = $("#swatches");
const preview = $(".preview");
const nameIn = $("#nlName");
const dockNew = $("#dockNew");
const bigIco = $("#nlIco");
let color = "pink";

const titleCase = (s) => s.trim().replace(/\s+/g, " ").replace(/\b\p{L}/gu, (m) => m.toUpperCase());
function paint(bounce) {
  const hex = COLORS[color];
  preview.style.setProperty("--ci", hex);
  nameIn.style.setProperty("--sel", hex);
  for (const el of [bigIco, dockNew, $("#nlIcoSmall")]) el.style.setProperty("--ci", hex);
  const title = `Claude ${titleCase(nameIn.value) || "Client Acme"}`;
  $("#nlTitle").textContent = title;
  $("#spotQ").textContent = title;
  if (bounce) {
    for (const [el, cls] of [[bigIco, "pop"], [dockNew, "bounce"]]) {
      el.classList.remove(cls);
      void el.offsetWidth;
      el.classList.add(cls);
    }
  }
  for (const b of swatches.children) b.setAttribute("aria-checked", b.dataset.color === color);
}
for (const name of Object.keys(COLORS)) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "sw";
  b.dataset.color = name;
  b.setAttribute("role", "radio");
  b.setAttribute("aria-label", name);
  b.style.setProperty("--ci", COLORS[name]);
  b.addEventListener("click", () => { color = name; paint(true); });
  swatches.append(b);
}
nameIn.addEventListener("input", () => paint(false));
paint(false);

// ---------- lanes claude, in a terminal ----------
// What `lanes claude <lane>` prints, and the status line `lanes usage
// --statusline` draws for that lane. Same numbers as the widget tile.
const TERM_LANES = [
  { arg: "work", name: "Work", color: "blue", h5: 86, reset: "38m", wk: 63, out: "09:30" },
  { arg: "studio", name: "Studio", color: "green", h5: 7, reset: "4h 40m", wk: 12 },
  { arg: "default", name: "Default", color: "orange", h5: 23, reset: "3h 11m", wk: 71 },
  { arg: "--best", best: "studio" },
];
const lanePick = $("#lanePick");
const shell = $("#shell");
const termLevel = (v) => (v >= 90 ? "crit" : v >= 75 ? "warn" : "");
const pctSpan = (v) => (termLevel(v) ? `<span class="${termLevel(v)}">${v}%</span>` : `${v}%`);
function pickLane(arg) {
  const pick = TERM_LANES.find((l) => l.arg === arg);
  const l = pick.best ? TERM_LANES.find((x) => x.arg === pick.best) : pick;
  shell.style.setProperty("--ci", COLORS[l.color]);
  shell.setAttribute("aria-label", `A terminal running Claude Code on the ${l.name} lane`);
  $("#tArg").textContent = pick.arg;
  $("#tInfo").textContent = `ℹ Claude Code on ${l.name}${l.name === "Default" ? " (~/.claude)" : ""}`;
  $("#tStatus").innerHTML = `<b>${l.name}</b> · 5h ${pctSpan(l.h5)} <span class="d">resets in ${l.reset}</span>` +
    ` · week ${pctSpan(l.wk)}` + (l.out ? ` · <span class="warn">out ~${l.out}</span>` : "");
  for (const b of lanePick.children) b.setAttribute("aria-checked", b.dataset.arg === arg);
}
for (const l of TERM_LANES) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "lp";
  b.dataset.arg = l.arg;
  b.setAttribute("role", "radio");
  const c = COLORS[(l.best ? TERM_LANES.find((x) => x.arg === l.best) : l).color];
  b.style.setProperty("--ci", l.best ? "var(--coral)" : c);
  b.innerHTML = `<i></i>${l.arg}`;
  b.addEventListener("click", () => pickLane(l.arg));
  lanePick.append(b);
}
pickLane("work");

// ---------- reveal on scroll ----------
if ("IntersectionObserver" in window) {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }, { threshold: 0.2 });
  document.querySelectorAll(".band h2, .band .sub, .maker, .preview, .shell, .cmds, .tile, .extras li, .steps li").forEach((el) => {
    el.classList.add("reveal");
    io.observe(el);
  });
  io.observe($(".finale"));
} else {
  $(".finale").classList.add("in");
}


// ---------- copy the install command ----------
document.querySelectorAll(".copy").forEach((b) => {
  b.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy);
      b.textContent = "Copied";
    } catch {
      b.textContent = "Select & copy";
    }
    setTimeout(() => { b.textContent = "Copy"; }, 1800);
  });
});

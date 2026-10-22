//! Chaos Companion: reads Twitch chat votes and passes them to the sm64coopdx Chaos mod.
//! - chat.rs   anonymous Twitch IRC reader
//! - votes.rs  vote parsing + one-vote-per-chatter counting
//! - bridge.rs file bridge with the game (chaos.sav relay in, chaos.modfs votes out)
//! The OBS overlay (/overlay), dock (/dock) and live state (/state) are served on http://127.0.0.1:7480.

mod bridge;
mod chat;
mod votes;

use serde::{Deserialize, Serialize};
use tauri::Manager;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const PORT: u16 = 7480;

pub const THEMES: [&str; 4] = ["classic", "transparent", "minimal", "mario64"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    channel: String,
    /// how many vote options the game should show (1-9)
    options: u32,
    /// overlay style: classic, transparent, minimal or mario64
    theme: String,
    /// minimizing hides the window to the system tray (click the tray icon to bring it back)
    minimize_to_tray: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { channel: String::new(), options: 4, theme: "classic".into(), minimize_to_tray: false }
    }
}

fn settings_path() -> PathBuf {
    let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".into());
    PathBuf::from(appdata).join("ChaosCompanion").join("settings.json")
}

fn load_settings() -> Settings {
    std::fs::read_to_string(settings_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_settings_file(s: &Settings) {
    let p = settings_path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(p, serde_json::to_string_pretty(s).unwrap_or_default());
}

#[derive(Default)]
struct Inner {
    settings: Settings,
    chat_connected: bool,
    chat_status: String,
    game: bridge::GameState,
    game_age: u64,
    votes: votes::VoteBox,
    recent: VecDeque<(String, u8)>,
    server_status: String,
    /// co-host list set from the app's + / x buttons, with a revision so the game applies each change once
    cohost_rev: u64,
    cohost_list: Option<Vec<String>>,
}

type Shared = Arc<Mutex<Inner>>;

struct AppState {
    shared: Shared,
    generation: Arc<AtomicU64>,
}

impl Inner {
    /// the co-hosts the game currently has (lower-case in-game names)
    fn game_cohosts(&self) -> Vec<String> {
        self.game.people.iter().filter(|p| p.role == "cohost").map(|p| p.game_name.to_lowercase()).collect()
    }

    fn change_cohosts(&mut self, name: &str, add: bool) {
        let name = name.trim().to_lowercase();
        if name.is_empty() {
            return;
        }
        let mut list = self.cohost_list.clone().unwrap_or_else(|| self.game_cohosts());
        list.retain(|n| n != &name);
        if add {
            list.push(name);
        }
        // a new revision every change (time-based, so it never repeats after the app restarts)
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(1);
        self.cohost_rev = now.max(self.cohost_rev + 1);
        self.cohost_list = Some(list);
    }

    fn game_online(&self) -> bool {
        self.game.running && self.game_age < 6
    }

    fn snapshot(&self) -> Value {
        let online = self.game_online();
        let twitch_mode = online && self.game.source == 3;
        // what decides the vote: Twitch votes, plus lobby /vote if the host turned that on
        // Twitch votes: the game's combined count (host + co-hosts) when it has one, else this app's own count
        let combined = !self.game.twitch_counts.is_empty() && self.game.twitch_counts.iter().any(|c| *c > 0);
        let mut shown = [0u32; 9];
        for (i, c) in self.votes.counts.iter().enumerate() {
            if twitch_mode && combined {
                shown[i] += self.game.twitch_counts.get(i).copied().unwrap_or(0);
            } else if twitch_mode && self.votes.vote_id == self.game.vote_id {
                shown[i] += c;
            }
            if online && (self.game.source == 2 || (twitch_mode && self.game.plus_lobby)) {
                shown[i] += self.game.lobby_counts.get(i).copied().unwrap_or(0);
            }
        }
        json!({
            "settings": self.settings,
            "chat": { "connected": self.chat_connected, "status": self.chat_status },
            "game": self.game,
            "gameOnline": online,
            "twitchMode": twitch_mode,
            "votes": { "voteId": self.votes.vote_id, "twitch": self.votes.counts, "shown": shown,
                       "twitchTotal": self.votes.total() },
            "recent": self.recent.iter().map(|(u, n)| json!({ "user": u, "vote": n })).collect::<Vec<_>>(),
            "server": self.server_status,
            "urls": { "overlay": format!("http://127.0.0.1:{PORT}/overlay"), "dock": format!("http://127.0.0.1:{PORT}/dock") },
        })
    }
}

fn on_chat(shared: &Shared, msg: chat::ChatMessage) {
    let mut g = shared.lock().unwrap();
    // only count while the game has a Twitch vote open
    if !(g.game_online() && g.game.phase == 2 && g.game.source == 3) {
        return;
    }
    if g.votes.vote_id != g.game.vote_id {
        return;
    }
    let max = (g.game.options.len() as u8).clamp(1, 9);
    if let Some(n) = votes::parse_vote(&msg.text, max) {
        if g.votes.add(&msg.user, n) {
            g.recent.push_front((msg.user, n));
            g.recent.truncate(12);
        }
    }
}

fn start_chat(shared: &Shared, generation: &Arc<AtomicU64>) {
    let my = generation.fetch_add(1, Ordering::SeqCst) + 1;
    let channel = shared.lock().unwrap().settings.channel.clone();
    let (s1, s2, gen) = (shared.clone(), shared.clone(), generation.clone());
    std::thread::spawn(move || {
        chat::run(
            channel,
            my,
            gen,
            move |ok, status| {
                let mut g = s1.lock().unwrap();
                g.chat_connected = ok;
                g.chat_status = status;
            },
            move |m| on_chat(&s2, m),
        )
    });
}

/// Every 250 ms: read the game's state; every 500 ms: send the vote counts (also a heartbeat).
fn start_game_loop(shared: Shared) {
    std::thread::spawn(move || {
        let mut seq: u64 = 0;
        let mut last_write = Instant::now() - Duration::from_secs(1);
        loop {
            let read = bridge::read_game();
            let (vote_id, options, counts, channel, cohosts) = {
                let mut g = shared.lock().unwrap();
                match read {
                    Some((state, age)) => {
                        g.game = state;
                        g.game_age = age;
                    }
                    None => {
                        g.game.running = false;
                        g.game_age = u64::MAX;
                    }
                }
                // a new vote opened: start a fresh ballot (everyone may vote again)
                if g.game.phase == 2 && g.game.vote_id != g.votes.vote_id {
                    let id = g.game.vote_id;
                    g.votes.reset(id);
                    g.recent.clear();
                }
                let cohosts = (g.cohost_rev, g.cohost_list.clone().unwrap_or_default());
                (g.votes.vote_id, g.settings.options, g.votes.counts, g.settings.channel.clone(), cohosts)
            };
            if last_write.elapsed() >= Duration::from_millis(500) {
                seq += 1;
                let _ = bridge::write_votes(seq, vote_id, options, &counts, &channel, &cohosts);
                last_write = Instant::now();
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    });
}

/// Local web server for OBS: /overlay (browser source), /dock (custom dock), /state (live JSON).
fn start_server(shared: Shared) {
    std::thread::spawn(move || {
        let server = match tiny_http::Server::http(("127.0.0.1", PORT)) {
            Ok(s) => s,
            Err(e) => {
                shared.lock().unwrap().server_status = format!("OBS pages unavailable: port {PORT} is busy ({e})");
                return;
            }
        };
        shared.lock().unwrap().server_status = format!("OBS pages on port {PORT}");
        for req in server.incoming_requests() {
            let path = req.url().split('?').next().unwrap_or("/").to_string();
            let (body, kind): (String, &str) = match path.as_str() {
                "/state" => (shared.lock().unwrap().snapshot().to_string(), "application/json"),
                "/overlay" => (include_str!("../../ui/overlay.html").into(), "text/html; charset=utf-8"),
                "/dock" => (include_str!("../../ui/dock.html").into(), "text/html; charset=utf-8"),
                "/shared.js" => (include_str!("../../ui/shared.js").into(), "text/javascript; charset=utf-8"),
                "/style.css" => (include_str!("../../ui/style.css").into(), "text/css; charset=utf-8"),
                _ => {
                    let _ = req.respond(tiny_http::Response::from_string("not found").with_status_code(404));
                    continue;
                }
            };
            let resp = tiny_http::Response::from_string(body)
                .with_header(tiny_http::Header::from_bytes("Content-Type", kind).unwrap())
                .with_header(tiny_http::Header::from_bytes("Cache-Control", "no-store").unwrap())
                .with_header(tiny_http::Header::from_bytes("Access-Control-Allow-Origin", "*").unwrap());
            let _ = req.respond(resp);
        }
    });
}

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> Value {
    state.shared.lock().unwrap().snapshot()
}

#[tauri::command]
fn save_settings(
    state: tauri::State<AppState>,
    channel: String,
    options: u32,
    theme: String,
    minimize_to_tray: bool,
) -> Value {
    let channel_changed;
    {
        let mut g = state.shared.lock().unwrap();
        let channel = channel.trim().trim_start_matches('#').to_ascii_lowercase();
        channel_changed = channel != g.settings.channel;
        g.settings.channel = channel;
        g.settings.options = options.clamp(1, 9);
        if THEMES.contains(&theme.as_str()) {
            g.settings.theme = theme;
        }
        g.settings.minimize_to_tray = minimize_to_tray;
        save_settings_file(&g.settings);
    }
    if channel_changed {
        start_chat(&state.shared, &state.generation);
    }
    state.shared.lock().unwrap().snapshot()
}

/// Picking an overlay style applies (and saves) it straight away; OBS picks it up within a second.
#[tauri::command]
fn set_theme(state: tauri::State<AppState>, theme: String) -> Value {
    let mut g = state.shared.lock().unwrap();
    if THEMES.contains(&theme.as_str()) {
        g.settings.theme = theme;
        save_settings_file(&g.settings);
    }
    g.snapshot()
}

/// The "+ Add co-host" / "x" buttons. Only the host's game acts on it.
#[tauri::command]
fn set_cohost(state: tauri::State<AppState>, name: String, add: bool) -> Value {
    let mut g = state.shared.lock().unwrap();
    g.change_cohosts(&name, add);
    g.snapshot()
}

#[tauri::command]
fn reconnect(state: tauri::State<AppState>) {
    start_chat(&state.shared, &state.generation);
}

fn show_main_window(app: &tauri::AppHandle) {
    use tauri::Manager;
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let shared: Shared = Arc::new(Mutex::new(Inner {
        settings: load_settings(),
        chat_status: "Not connected".into(),
        ..Default::default()
    }));
    let generation = Arc::new(AtomicU64::new(0));
    start_game_loop(shared.clone());
    start_server(shared.clone());
    start_chat(&shared, &generation);
    tauri::Builder::default()
        .manage(AppState { shared, generation })
        .setup(|app| {
            // system tray icon: left click shows the window, right click for Show / Quit
            use tauri::menu::{Menu, MenuItem};
            use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
            let show = MenuItem::with_id(app, "show", "Show Chaos Companion", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            let mut tray = TrayIconBuilder::with_id("main")
                .tooltip("Chaos Companion")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_main_window(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // "Minimize to system tray": hide the window instead of leaving it on the taskbar
            if let tauri::WindowEvent::Resized(_) = event {
                if window.is_minimized().unwrap_or(false) {
                    let to_tray = window.state::<AppState>().shared.lock().unwrap().settings.minimize_to_tray;
                    if to_tray {
                        let _ = window.hide();
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![get_state, save_settings, reconnect, set_cohost, set_theme])
        .run(tauri::generate_context!())
        .expect("error while running Chaos Companion");
}

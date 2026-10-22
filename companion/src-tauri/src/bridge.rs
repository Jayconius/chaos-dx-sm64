//! The file bridge with the Chaos mod (both directions verified against the real game).
//!
//! Game -> app: the mod writes the `relay` key into %APPDATA%\sm64coopdx\sav\chaos.sav:
//!   "2|voteId|phase|secs|total|source|options|plusLobby|paused|meter|streak|bestStreak|fired|lobbyCounts|opts|active|last
//!    |twitchCounts|role|people"
//!   opts = id~name~kind, active = name~kind~secs, people = role~display~gameName~connected~votes (all joined by ^).
//!   Every player's game writes this (not only the host's), so a co-host's app mirrors the host's vote.
//! App -> game: we write %APPDATA%\sm64coopdx\sav\chaos.modfs, a zip holding votes.txt:
//!   "seq|voteId|options|c1,c2,...,c9|channel". The mod re-reads it every 10 frames.

use serde::Serialize;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::time::SystemTime;

pub fn save_dir() -> PathBuf {
    let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".into());
    PathBuf::from(appdata).join("sm64coopdx").join("sav")
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct VoteOption {
    pub id: String,
    pub name: String,
    pub kind: String,
}

/// The host or a co-host, as listed by the game.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Person {
    /// "host" or "cohost"
    pub role: String,
    /// Twitch channel when their app is running, otherwise their in-game name
    pub display: String,
    pub game_name: String,
    /// 1 = app connected, 0 = in game without the app, -1 = not in the game
    pub connected: i32,
    pub votes: u32,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ActiveEffect {
    pub name: String,
    pub kind: String,
    pub secs: u32,
}

/// What the game last told us.
#[derive(Debug, Clone, Default, Serialize)]
pub struct GameState {
    pub running: bool,
    pub vote_id: u32,
    /// 0 off, 1 cooldown, 2 vote open
    pub phase: u32,
    pub secs: u32,
    pub total: u32,
    /// 0 off, 1 RNG, 2 lobby votes, 3 Twitch votes
    pub source: u32,
    pub num_options: u32,
    pub plus_lobby: bool,
    pub paused: bool,
    pub meter: i32,
    pub streak: u32,
    pub best_streak: u32,
    pub fired: u32,
    pub lobby_counts: Vec<u32>,
    pub options: Vec<VoteOption>,
    pub active: Vec<ActiveEffect>,
    pub last_effect: String,
    /// all Twitch votes combined for the current vote (host + co-hosts), as decided by the host's game
    pub twitch_counts: Vec<u32>,
    /// "host", "cohost" or "player": who this PC is in the game
    pub role: String,
    pub people: Vec<Person>,
    /// everyone in the game (for the "Add co-host" list)
    pub players: Vec<String>,
}

fn num<T: std::str::FromStr + Default>(s: Option<&&str>) -> T {
    s.and_then(|v| v.trim().parse().ok()).unwrap_or_default()
}

pub fn parse_relay(relay: &str) -> Option<GameState> {
    let f: Vec<&str> = relay.split('|').collect();
    if f.len() < 17 || f[0] != "2" {
        return None;
    }
    let options = f[14]
        .split('^')
        .filter(|s| !s.is_empty())
        .map(|o| {
            let p: Vec<&str> = o.split('~').collect();
            VoteOption {
                id: p.first().unwrap_or(&"").to_string(),
                name: p.get(1).unwrap_or(&"").to_string(),
                kind: p.get(2).unwrap_or(&"").to_string(),
            }
        })
        .collect();
    let active = f[15]
        .split('^')
        .filter(|s| !s.is_empty())
        .map(|a| {
            let p: Vec<&str> = a.split('~').collect();
            ActiveEffect {
                name: p.first().unwrap_or(&"").to_string(),
                kind: p.get(1).unwrap_or(&"").to_string(),
                secs: num(p.get(2)),
            }
        })
        .collect();
    Some(GameState {
        running: true,
        vote_id: num(f.get(1)),
        phase: num(f.get(2)),
        secs: num(f.get(3)),
        total: num(f.get(4)),
        source: num(f.get(5)),
        num_options: num(f.get(6)),
        plus_lobby: f[7] == "1",
        paused: f[8] == "1",
        meter: num(f.get(9)),
        streak: num(f.get(10)),
        best_streak: num(f.get(11)),
        fired: num(f.get(12)),
        lobby_counts: f[13].split(',').map(|c| c.trim().parse().unwrap_or(0)).collect(),
        options,
        active,
        last_effect: f[16].to_string(),
        twitch_counts: f
            .get(17)
            .map(|t| t.split(',').filter(|c| !c.is_empty()).map(|c| c.trim().parse().unwrap_or(0)).collect())
            .unwrap_or_default(),
        role: f.get(18).unwrap_or(&"host").to_string(),
        people: f
            .get(19)
            .map(|p| {
                p.split('^')
                    .filter(|e| !e.is_empty())
                    .map(|e| {
                        let q: Vec<&str> = e.split('~').collect();
                        Person {
                            role: q.first().unwrap_or(&"").to_string(),
                            display: q.get(1).unwrap_or(&"").to_string(),
                            game_name: q.get(2).unwrap_or(&"").to_string(),
                            connected: num(q.get(3)),
                            votes: num(q.get(4)),
                        }
                    })
                    .collect()
            })
            .unwrap_or_default(),
        players: f
            .get(20)
            .map(|p| p.split(',').map(|n| n.trim().to_string()).filter(|n| !n.is_empty()).collect())
            .unwrap_or_default(),
    })
}

/// Reads the relay line from chaos.sav. Returns (state, seconds since the file last changed).
pub fn read_game() -> Option<(GameState, u64)> {
    let path = save_dir().join("chaos.sav");
    let age = fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .map(|d| d.as_secs())
        .unwrap_or(u64::MAX);
    let text = fs::read_to_string(&path).ok()?;
    let line = text.lines().find_map(|l| l.strip_prefix("relay="))?;
    parse_relay(line).map(|s| (s, age))
}

// ------------------------------------------------------------------------------------- tiny zip writer
// The game's ModFS reads a normal zip; one uncompressed ("stored") file is all we need, so no zip crate.

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xEDB8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

fn zip_one_file(name: &str, data: &[u8]) -> Vec<u8> {
    let crc = crc32(data);
    let n = name.as_bytes();
    let mut z = Vec::with_capacity(data.len() + 128);
    // local file header
    z.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
    z.extend_from_slice(&20u16.to_le_bytes()); // version needed
    z.extend_from_slice(&0u16.to_le_bytes()); // flags
    z.extend_from_slice(&0u16.to_le_bytes()); // method: stored
    z.extend_from_slice(&0u16.to_le_bytes()); // time
    z.extend_from_slice(&0x21u16.to_le_bytes()); // date (1980-01-01)
    z.extend_from_slice(&crc.to_le_bytes());
    z.extend_from_slice(&(data.len() as u32).to_le_bytes());
    z.extend_from_slice(&(data.len() as u32).to_le_bytes());
    z.extend_from_slice(&(n.len() as u16).to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes()); // extra length
    z.extend_from_slice(n);
    z.extend_from_slice(data);
    // central directory
    let cd_offset = z.len() as u32;
    z.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
    z.extend_from_slice(&20u16.to_le_bytes()); // version made by
    z.extend_from_slice(&20u16.to_le_bytes()); // version needed
    z.extend_from_slice(&0u16.to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes());
    z.extend_from_slice(&0x21u16.to_le_bytes());
    z.extend_from_slice(&crc.to_le_bytes());
    z.extend_from_slice(&(data.len() as u32).to_le_bytes());
    z.extend_from_slice(&(data.len() as u32).to_le_bytes());
    z.extend_from_slice(&(n.len() as u16).to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes()); // extra
    z.extend_from_slice(&0u16.to_le_bytes()); // comment
    z.extend_from_slice(&0u16.to_le_bytes()); // disk
    z.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
    z.extend_from_slice(&0u32.to_le_bytes()); // external attrs
    z.extend_from_slice(&0u32.to_le_bytes()); // local header offset
    z.extend_from_slice(n);
    let cd_size = z.len() as u32 - cd_offset;
    // end of central directory
    z.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes());
    z.extend_from_slice(&1u16.to_le_bytes());
    z.extend_from_slice(&1u16.to_le_bytes());
    z.extend_from_slice(&cd_size.to_le_bytes());
    z.extend_from_slice(&cd_offset.to_le_bytes());
    z.extend_from_slice(&0u16.to_le_bytes());
    z
}

/// Writes the votes for the game. Atomic (temp file + rename) so the game never reads half a file.
/// `cohosts` = (revision, names): the host's game applies the list whenever the revision changes (0 = no list).
pub fn write_votes(
    seq: u64,
    vote_id: u32,
    options: u32,
    counts: &[u32; 9],
    channel: &str,
    cohosts: &(u64, Vec<String>),
) -> std::io::Result<()> {
    let dir = save_dir();
    fs::create_dir_all(&dir)?;
    let list: Vec<String> = counts.iter().map(|c| c.to_string()).collect();
    // the channel lets the game show co-hosts by their Twitch name (letters, digits and _ only)
    let channel: String = channel.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
    let names: Vec<String> = cohosts.1.iter().map(|n| n.replace([',', '|', '\n', '\r'], " ")).collect();
    let text = format!("{}|{}|{}|{}|{}|{}:{}\n", seq, vote_id, options, list.join(","), channel, cohosts.0, names.join(","));
    let zip = zip_one_file("votes.txt", text.as_bytes());
    let tmp = dir.join("chaos.modfs.tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(&zip)?;
    }
    fs::rename(&tmp, dir.join("chaos.modfs"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_matches_known_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn parses_the_relay_line_the_mod_writes() {
        // a real line captured from the game during the bridge test
        let line = "2|5|2|4|5|3|6|0|0|-6|0|2|5|0,1,0,0,0,0,0,0,0|freeze~Brain Freeze~hinder^bounce_house~Bounce House~help||2026-10-22 11:46:27 HELP Bounce House (Twitch vote 2 (5 votes), everyone, 20s)";
        let s = parse_relay(line).expect("parses");
        assert_eq!(s.vote_id, 5);
        assert_eq!(s.phase, 2);
        assert_eq!(s.source, 3);
        assert_eq!(s.num_options, 6);
        assert_eq!(s.meter, -6);
        assert_eq!(s.best_streak, 2);
        assert_eq!(s.lobby_counts[1], 1);
        assert_eq!(s.options.len(), 2);
        assert_eq!(s.options[1].name, "Bounce House");
        assert_eq!(s.options[1].kind, "help");
        assert!(s.active.is_empty());
        assert!(s.last_effect.contains("Bounce House"));
    }

    #[test]
    fn parses_co_host_fields() {
        let line = "2|9|2|10|20|3|4|0|0|0|1|3|12|0,0,0,0,0,0,0,0,0|a~A~help^b~B~hinder||last|5,7,0,0,0,0,0,0,0|cohost|host~hostchannel~Host~1~4^cohost~mychannel~Guest~1~8^cohost~away~away~-1~0";
        let s = parse_relay(line).expect("parses");
        assert_eq!(s.twitch_counts, vec![5, 7, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(s.role, "cohost");
        assert_eq!(s.people.len(), 3);
        assert_eq!(s.people[0].role, "host");
        assert_eq!(s.people[0].display, "hostchannel");
        assert_eq!(s.people[1].votes, 8);
        assert_eq!(s.people[2].connected, -1);
        assert!(s.players.is_empty());
        let with_players = format!("{line}|Host,Guest Two");
        assert_eq!(parse_relay(&with_players).unwrap().players, vec!["Host", "Guest Two"]);
    }

    #[test]
    fn rejects_unknown_lines() {
        assert!(parse_relay("1|2|3").is_none());
        assert!(parse_relay("").is_none());
    }
}

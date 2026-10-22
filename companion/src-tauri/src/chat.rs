//! Reads Twitch chat anonymously over IRC (no login, no OAuth): connects as a "justinfan" guest,
//! which Twitch allows for read-only chat. Plain TCP on port 6667, so no TLS library is needed.

use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// One chat message.
pub struct ChatMessage {
    pub user: String,
    pub text: String,
}

/// Parses an IRC line like ":nick!nick@nick.tmi.twitch.tv PRIVMSG #chan :hello"
pub fn parse_privmsg(line: &str) -> Option<ChatMessage> {
    let rest = line.strip_prefix(':')?;
    let (prefix, rest) = rest.split_once(' ')?;
    let rest = rest.strip_prefix("PRIVMSG ")?;
    let (_channel, text) = rest.split_once(" :")?;
    let user = prefix.split('!').next()?.to_string();
    Some(ChatMessage { user, text: text.to_string() })
}

/// Runs the chat connection until `generation` changes (channel changed or app closing).
/// Calls `on_status(connected, detail)` and `on_message(msg)`. Reconnects on its own.
pub fn run(
    channel: String,
    my_generation: u64,
    generation: Arc<AtomicU64>,
    on_status: impl Fn(bool, String),
    on_message: impl Fn(ChatMessage),
) {
    let channel = channel.trim().trim_start_matches('#').to_ascii_lowercase();
    if channel.is_empty() {
        on_status(false, "No channel set".into());
        return;
    }
    let mut wait = 2u64;
    while generation.load(Ordering::SeqCst) == my_generation {
        on_status(false, format!("Connecting to #{channel}..."));
        match connect_and_read(&channel, my_generation, &generation, &on_status, &on_message) {
            Ok(()) => wait = 2,
            Err(e) => on_status(false, format!("Disconnected: {e}. Retrying in {wait}s")),
        }
        for _ in 0..wait * 10 {
            if generation.load(Ordering::SeqCst) != my_generation {
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        wait = (wait * 2).min(30);
    }
}

fn connect_and_read(
    channel: &str,
    my_generation: u64,
    generation: &Arc<AtomicU64>,
    on_status: &impl Fn(bool, String),
    on_message: &impl Fn(ChatMessage),
) -> std::io::Result<()> {
    // CHAOS_IRC_ADDR lets tests point the app at a local fake chat server instead of Twitch
    let addr = std::env::var("CHAOS_IRC_ADDR").unwrap_or_else(|_| "irc.chat.twitch.tv:6667".into());
    let mut stream = TcpStream::connect(addr)?;
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    let guest = format!("justinfan{}", 10000 + (std::process::id() % 80000));
    write!(stream, "NICK {guest}\r\nJOIN #{channel}\r\n")?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    let mut joined = false;
    loop {
        if generation.load(Ordering::SeqCst) != my_generation {
            return Ok(());
        }
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return Err(std::io::Error::other("connection closed")),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(e) => return Err(e),
        }
        let l = line.trim_end();
        if let Some(rest) = l.strip_prefix("PING") {
            write!(stream, "PONG{rest}\r\n")?;
        } else if !joined && (l.contains(" JOIN #") || l.contains(" 366 ")) {
            joined = true;
            on_status(true, format!("Reading #{channel}"));
        } else if let Some(msg) = parse_privmsg(l) {
            on_message(msg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_chat_lines() {
        let m = parse_privmsg(":some_viewer!some_viewer@some_viewer.tmi.twitch.tv PRIVMSG #streamer :1! please").unwrap();
        assert_eq!(m.user, "some_viewer");
        assert_eq!(m.text, "1! please");
        assert!(parse_privmsg("PING :tmi.twitch.tv").is_none());
        assert!(parse_privmsg(":tmi.twitch.tv 001 justinfan1 :Welcome").is_none());
    }
}

"""A fake Twitch IRC server for testing Chaos Companion without real chatters.
Run: python -I tests/fake_twitch.py <seconds>   then start the app with CHAOS_IRC_ADDR=127.0.0.1:16667
Every second it replays the same chat; per round the app should count option 1 = 2 votes, option 2 = 3 votes.
"""
import socket, sys, threading, time

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 60
CHAT = [
    ("viewer_a", "1"),
    ("viewer_b", "111"),
    ("viewer_c", "2! please"),
    ("viewer_d", "12"),          # two different digits: ignored
    ("viewer_e", "#2"),
    ("viewer_a", "3"),           # second vote from viewer_a: ignored
    ("viewer_f", "2"),
    ("viewer_g", "I pick 1"),    # number not at the start: ignored
]

def serve(conn):
    conn.settimeout(0.2)
    channel = "#test"
    buf = b""
    end = time.time() + SECONDS
    last = 0
    try:
        while time.time() < end:
            try:
                data = conn.recv(4096)
                if not data:
                    return
                buf += data
                for line in buf.split(b"\r\n")[:-1]:
                    text = line.decode(errors="replace")
                    if text.startswith("JOIN "):
                        channel = text[5:].strip()
                        conn.sendall((":justinfan!justinfan@justinfan.tmi.twitch.tv JOIN %s\r\n" % channel).encode())
                buf = buf.split(b"\r\n")[-1]
            except socket.timeout:
                pass
            if time.time() - last >= 1.0:
                last = time.time()
                for user, msg in CHAT:
                    conn.sendall((":%s!%s@%s.tmi.twitch.tv PRIVMSG %s :%s\r\n" % (user, user, user, channel, msg)).encode())
    finally:
        conn.close()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 16667))
srv.listen(4)
srv.settimeout(SECONDS)
print("fake twitch listening")
try:
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn,), daemon=True).start()
except socket.timeout:
    pass

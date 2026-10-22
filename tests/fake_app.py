"""Stand-in for the Chaos Companion app, used to test the mod's bridge without Twitch.

Reads the game's state from %APPDATA%/sm64coopdx/sav/chaos.sav (key "relay") and writes votes to
%APPDATA%/sm64coopdx/sav/chaos.modfs (zip with votes.txt: "seq|voteId|options|c1,...,c9").
Usage: python -I tests/fake_app.py <seconds> <options> <winning option> <votes>
"""
import os, sys, time, zipfile

SAV = os.path.join(os.environ['APPDATA'], 'sm64coopdx', 'sav')
seconds, options, pick, votes = (int(a) for a in sys.argv[1:5])

def read_relay():
    try:
        with open(os.path.join(SAV, 'chaos.sav'), encoding='utf-8', errors='replace') as f:
            for line in f:
                if line.startswith('relay='):
                    return line[len('relay='):].rstrip('\n').split('|')
    except OSError:
        pass
    return None

def write_votes(seq, vote_id):
    counts = [0] * 9
    counts[pick - 1] = votes
    text = '%d|%d|%d|%s\n' % (seq, vote_id, options, ','.join(map(str, counts)))
    path = os.path.join(SAV, 'chaos.modfs')
    with zipfile.ZipFile(path + '.tmp', 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('votes.txt', text)
    os.replace(path + '.tmp', path)

seq, seen = 0, set()
end = time.time() + seconds
while time.time() < end:
    relay = read_relay()
    vote_id = int(relay[1]) if relay and len(relay) > 1 and relay[1].isdigit() else 0
    if relay and len(relay) > 14 and relay[2] == '2' and vote_id not in seen:
        seen.add(vote_id)
        print('vote %d open with %d options: %s' % (vote_id, len(relay[14].split('^')), relay[14][:120]))
    seq += 1
    write_votes(seq, vote_id)
    time.sleep(0.5)
print('last relay:', '|'.join(read_relay() or [])[:300])

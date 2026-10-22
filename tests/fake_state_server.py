"""Serves the companion's overlay/dock pages with a made-up vote, for screenshots and styling work.
No game or Twitch needed, and it doesn't touch any real files.
Run: python tests/fake_state_server.py   then open http://127.0.0.1:7481/overlay?theme=mario64 or /dock
"""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer

UI = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'companion', 'ui')
PAGES = {'/overlay': 'overlay.html', '/dock': 'dock.html', '/shared.js': 'shared.js', '/style.css': 'style.css'}
TYPES = {'.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css'}

STATE = {
    'settings': {'channel': 'yourchannel', 'options': 4, 'theme': 'classic', 'minimize_to_tray': False},
    'chat': {'connected': True, 'status': 'Reading #yourchannel'},
    'gameOnline': True, 'twitchMode': True, 'server': 'OBS pages on port 7481',
    'game': {
        'running': True, 'vote_id': 12, 'phase': 2, 'secs': 12, 'total': 20, 'source': 3, 'num_options': 4,
        'plus_lobby': False, 'paused': False, 'meter': -30, 'streak': 3, 'best_streak': 5, 'fired': 27,
        'lobby_counts': [0] * 9, 'role': 'host', 'players': ['Host', 'Luigi Fan'],
        'options': [
            {'id': 'moon_gravity', 'name': 'Moon Gravity', 'kind': 'help'},
            {'id': 'meteor_shower', 'name': 'Meteor Shower', 'kind': 'hinder'},
            {'id': 'speed_boost', 'name': 'Speed Boost', 'kind': 'help'},
            {'id': 'drunk', 'name': 'Drunk', 'kind': 'hinder'},
        ],
        'active': [{'name': 'Blizzard', 'kind': 'hinder', 'secs': 14}, {'name': 'Hover Boots', 'kind': 'help', 'secs': 6}],
        'last_effect': '21:04:12 HINDER Blizzard (Twitch vote 2 (31 votes), everyone, 20s)',
        'twitch_counts': [18, 31, 6, 12, 0, 0, 0, 0, 0],
        'people': [
            {'role': 'host', 'display': 'yourchannel', 'game_name': 'Host', 'connected': 1, 'votes': 41},
            {'role': 'cohost', 'display': 'friendchannel', 'game_name': 'Luigi Fan', 'connected': 1, 'votes': 26},
        ],
    },
    'votes': {'voteId': 12, 'twitch': [11, 19, 4, 7, 0, 0, 0, 0, 0], 'shown': [18, 31, 6, 12, 0, 0, 0, 0, 0], 'twitchTotal': 41},
    'recent': [{'user': 'speedy_viewer', 'vote': 2}, {'user': 'coin_collector', 'vote': 1}, {'user': 'bobomb_buddy', 'vote': 2},
               {'user': 'star_hunter', 'vote': 4}],
    'urls': {'overlay': 'http://127.0.0.1:7480/overlay', 'dock': 'http://127.0.0.1:7480/dock'},
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/state':
            body, kind = json.dumps(STATE).encode(), 'application/json'
        elif path in PAGES:
            name = PAGES[path]
            with open(os.path.join(UI, name), 'rb') as f:
                body = f.read()
            kind = TYPES[os.path.splitext(name)[1]]
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', kind + '; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 7481), Handler).serve_forever()

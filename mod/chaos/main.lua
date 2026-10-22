-- name: Chaos DX
-- description: Timed chaos effects, picked by RNG or by a lobby vote, synced from the host to everyone.\n\nHelp and Hinder effects, a greed meter that punishes a lobby that keeps voting Help, and an API (_G.ChaosMod) so other mods can add effects.\n\nChat: /vote 1-9, host: /chaos auto|vote|twitch|off|now|clear|log|list|enable|disable. Twitch voting needs the Chaos Companion app.
-- (loaded last: a_core.lua and b_effects.lua come first alphabetically)

local C = Chaos
local FPS = 30

--------------------------------------------------------------------------------------------- sync state
-- Set unconditionally at init so the host's values are what the lobby gets.
gGlobalSyncTable.chaosSource = 1        -- 0 off, 1 auto (RNG), 2 lobby votes, 3 Twitch votes (companion app)
gGlobalSyncTable.chaosVoteSecs = tonumber(mod_storage_load("voteSecs") or "") or 20
gGlobalSyncTable.chaosCoolSecs = tonumber(mod_storage_load("coolSecs") or "") or 30
gGlobalSyncTable.chaosGreed = 2         -- 0 off, 1 mild, 2 harsh
gGlobalSyncTable.chaosShowMeter = true
-- keep votes/effects coming while a boss is out? (saved for next time)
gGlobalSyncTable.chaosDuringBoss = (mod_storage_load("duringBoss") ~= "false")
gGlobalSyncTable.chaosPaused = false
gGlobalSyncTable.chaosPhase = 0         -- 0 off, 1 cooldown, 2 vote
gGlobalSyncTable.chaosSecs = 0
gGlobalSyncTable.chaosTotal = 1
gGlobalSyncTable.chaosMeter = 0
gGlobalSyncTable.chaosVoteId = 0
gGlobalSyncTable.chaosOpt1 = ""
gGlobalSyncTable.chaosOpt2 = ""
gGlobalSyncTable.chaosOpt3 = ""
gGlobalSyncTable.chaosOpt4 = ""
gGlobalSyncTable.chaosOpt5 = ""
gGlobalSyncTable.chaosOpt6 = ""
gGlobalSyncTable.chaosOpt7 = ""
gGlobalSyncTable.chaosOpt8 = ""
gGlobalSyncTable.chaosOpt9 = ""
local MAX_OPTIONS = 9
-- how many options a vote shows (1-9). The companion app sets this while it's connected; otherwise the menu.
gGlobalSyncTable.chaosNumOptions = tonumber(mod_storage_load("numOptions") or "") or 4
-- Twitch votes from the companion app: "voteId:c1,c2,...,c9" (synced so everyone's HUD shows them)
gGlobalSyncTable.chaosTwitchCounts = ""
gGlobalSyncTable.chaosAppConnected = false
-- in Twitch mode, do lobby /vote votes count too? (optional, saved)
gGlobalSyncTable.chaosTwitchPlusLobby = (mod_storage_load("twitchPlusLobby") == "true")
-- co-hosts: players (by lower-case name, comma separated) whose companion-app votes count. Saved by the host.
gGlobalSyncTable.chaosCohosts = mod_storage_load("cohosts") or ""
-- host-only numbers shared so every player's companion app can show them
gGlobalSyncTable.chaosStreak = 0
gGlobalSyncTable.chaosBestStreak = 0
gGlobalSyncTable.chaosFired = 0
gGlobalSyncTable.chaosLastEffect = ""
-- One atomic field per effect: "serial|id|durationSeconds|targetGlobalIndex|seed"
gGlobalSyncTable.chaosEvent = ""

for i = 0, MAX_PLAYERS - 1 do
    gPlayerSyncTable[i].chaosVote = 0
    gPlayerSyncTable[i].chaosVoteId = -1
    -- from this player's companion app (if running): "voteId:c1,...,c9:seq" and their Twitch channel
    gPlayerSyncTable[i].chaosAppVotes = ""
    gPlayerSyncTable[i].chaosAppChannel = ""
end

local function set_sync(key, value)
    if gGlobalSyncTable[key] ~= value then gGlobalSyncTable[key] = value end
end

--------------------------------------------------------------------------------- client: running effects
local active = {}       -- entries: { id, def, frames, target, seed, done = {} }

local function applies_to(entry, m)
    if not gNetworkPlayers[m.playerIndex].connected then return false end
    local target = tonumber(entry.target) or -1   -- an effect overwriting entry.target must not break every frame
    if target >= 0 and gNetworkPlayers[m.playerIndex].globalIndex ~= target then return false end
    if C.filter ~= nil and not C.filter(m) then return false end
    return true
end

-- Effect code runs protected so one bad effect can't stop the others; the first error per effect is shown in chat.
local function safe(entry, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and not entry.errShown then
        entry.errShown = true
        djui_chat_message_create("\\#ff4040\\Chaos error in " .. tostring(entry.id) .. ": " .. tostring(err))
    end
end

local function end_entry(entry)
    local def = entry.def
    if def ~= nil and def.onEnd ~= nil then
        safe(entry, def.onEnd, entry)
    end
end

local function clear_all()
    for _, entry in ipairs(active) do end_entry(entry) end
    active = {}
end

local function start_effect(id, durationSecs, target, seed, bonus)
    if id == "__clear" then
        clear_all()
        return
    end
    local def = C.effects[id]
    if def == nil then return end
    -- The same effect firing again just restarts its timer (no double-stacking).
    -- Another effect from the same group (e.g. Tiny vs Giant, two weather effects) replaces the old one.
    for i = #active, 1, -1 do
        local old = active[i]
        if old.id == id and old.target == target and not old.instant then
            old.frames = math.max(old.frames, durationSecs * FPS)
            local color = (def.kind == "help") and "\\#80ff80\\" or "\\#ff8080\\"
            djui_chat_message_create(color .. "CHAOS: " .. def.name .. " again!\\#ffffff\\ (timer reset)")
            return
        elseif def.group ~= nil and old.def.group == def.group and not old.instant and durationSecs > 0 then
            end_entry(old)
            table.remove(active, i)
        end
    end
    local entry = {
        id = id, def = def, target = target, seed = seed,
        frames = math.max(durationSecs * FPS, 2), instant = (durationSecs <= 0), done = {},
    }
    if def.onStart ~= nil then safe(entry, def.onStart, entry) end
    table.insert(active, entry)
    print(string.format("[chaos] effect %s dur=%ds target=%d seed=%d", id, durationSecs, target, seed))

    local who = "everyone"
    if target >= 0 then
        who = "a player"
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and gNetworkPlayers[i].globalIndex == target then
                who = network_get_player_text_color_string(i) .. gNetworkPlayers[i].name .. "\\#ffffff\\"
            end
        end
    end
    local color = (def.kind == "help") and "\\#80ff80\\" or "\\#ff8080\\"
    djui_chat_message_create(color .. "CHAOS: " .. def.name .. "\\#ffffff\\ (" .. who .. ")")
    if bonus then
        djui_chat_message_create("\\#ffe040\\STREAK BONUS! The lobby took the pain, so this one lasts longer.")
    end
    play_sound(SOUND_MENU_STAR_SOUND, gGlobalSoundSource)
end

local lastSerial = 0
local framesLoaded = 0
local function on_event_changed(tag, oldVal, newVal)
    if newVal == nil or newVal == "" then return end
    local serial, id, dur, target, seed, bonus = string.match(newVal, "^(%d+)|([%w_]+)|(%d+)|(-?%d+)|(%d+)|?(%d*)$")
    if id == nil then return end
    serial = tonumber(serial)
    -- the host calls this directly and the sync hook may fire too: run each serial once
    if serial <= lastSerial then return end
    lastSerial = serial
    -- a joining client is handed the host's last event; don't replay it
    if framesLoaded < 60 and not network_is_server() then return end
    start_effect(id, tonumber(dur), tonumber(target), tonumber(seed), bonus == "1")
end
hook_on_sync_table_change(gGlobalSyncTable, "chaosEvent", 0, on_event_changed)

-- Weather: the newest active effect with an `envfx` decides it; with none, the level's own weather returns.
local currentEnvfx = nil
local function apply_envfx()
    local want = ENVFX_MODE_NO_OVERRIDE
    for _, entry in ipairs(active) do
        if entry.def.envfx ~= nil then want = entry.def.envfx end
    end
    if want ~= currentEnvfx then
        currentEnvfx = want
        set_override_envfx(want)
    end
end

local function client_update()
    framesLoaded = framesLoaded + 1
    apply_envfx()
    for i = #active, 1, -1 do
        local entry = active[i]
        entry.frames = entry.frames - 1
        if entry.frames <= 0 then
            end_entry(entry)
            table.remove(active, i)
        end
    end
end

local function mario_update(m)
    for _, entry in ipairs(active) do
        local def = entry.def
        if def.onMario ~= nil and applies_to(entry, m) then
            if entry.instant then
                if not entry.done[m.playerIndex] then
                    entry.done[m.playerIndex] = true
                    safe(entry, def.onMario, m, entry)
                end
            else
                safe(entry, def.onMario, m, entry)
            end
        end
    end
end
hook_event(HOOK_MARIO_UPDATE, mario_update)

-- Control changes (stick, buttons) must happen BEFORE Mario reads his inputs this frame.
-- HOOK_MARIO_UPDATE runs after Mario has already moved, so those effects use onBeforeMario.
local function before_mario(m)
    for _, entry in ipairs(active) do
        local def = entry.def
        if def.onBeforeMario ~= nil and applies_to(entry, m) then
            safe(entry, def.onBeforeMario, m, entry)
        end
    end
end
hook_event(HOOK_BEFORE_MARIO_UPDATE, before_mario)

-- Speed changes need to land after the action sets this frame's speed, so they use the physics-step hook.
local function before_phys(m, stepType)
    for _, entry in ipairs(active) do
        local def = entry.def
        if def.onBeforePhys ~= nil and applies_to(entry, m) then
            safe(entry, def.onBeforePhys, m, entry)
        end
    end
end
hook_event(HOOK_BEFORE_PHYS_STEP, before_phys)

----------------------------------------------------------------------------------------- host: scheduler
local serial = 0
local state = nil
local lastSource = -1

local function active_players()
    local list = {}
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then
            local m = gMarioStates[i]
            if C.filter == nil or C.filter(m) then
                table.insert(list, i)
            end
        end
    end
    return list
end

-- Effect log (host): what fired, when, how and on whom. Kept in memory for /chaos log and saved to this mod's
-- storage file (%APPDATA%\sm64coopdx\sav\chaos.sav, keys log0001...) so it can be checked after a stream.
local effectLog = {}
local LOG_MAX = 200
local logCount = tonumber(mod_storage_load("logCount") or "") or 0

local function log_effect(def, how, target, dur, bonus)
    local t = get_date_and_time()
    local who = "everyone"
    if target >= 0 then
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and gNetworkPlayers[i].globalIndex == target then
                who = gNetworkPlayers[i].name
            end
        end
    end
    local line = string.format("%04d-%02d-%02d %02d:%02d:%02d %s %s (%s, %s, %ss%s)",
        t.year + 1900, t.month + 1, t.day, t.hour, t.minute, t.second,   -- the game gives years since 1900, months from 0
        def.kind == "help" and "HELP" or "HINDER", def.name, how, who, dur, bonus and ", streak bonus" or "")
    table.insert(effectLog, line)
    while #effectLog > LOG_MAX do table.remove(effectLog, 1) end
    -- a fixed ring of keys so the save file never grows past LOG_MAX entries
    logCount = logCount + 1
    mod_storage_save(string.format("log%03d", (logCount - 1) % LOG_MAX), line)
    mod_storage_save("logCount", tostring(logCount))
end

-- Host settings (saved): do "one random player" effects hit everyone instead?
-- Default: Hinders (Boo Mode, Bird Attack, Brain Freeze, Surprise Shove) hit everyone; Helps stay one lucky player.
targetedHindersAll = (mod_storage_load("hindersAll") ~= "false")
targetedHelpsAll = (mod_storage_load("helpsAll") == "true")

local function fire_effect(id, how)
    local def = C.effects[id]
    if def == nil then return end
    local target = -1
    -- "one random player" effects can be set (per kind) to hit everyone instead
    local everyone = (def.kind == "hinder" and targetedHindersAll) or (def.kind == "help" and targetedHelpsAll)
    if def.target == "random" and not everyone then
        local players = active_players()
        if #players > 0 then
            local pick = players[math.random(#players)]
            target = gNetworkPlayers[pick].globalIndex
        end
    end
    -- streak bonus from the core (only for timed Help effects)
    local dur = def.duration
    if def.durationRange ~= nil then dur = math.random(def.durationRange[1], def.durationRange[2]) end
    local bonus = false
    if dur > 0 and def.kind == "help" and (C.lastMult or 1) > 1 then
        dur = math.floor(dur * C.lastMult)
        bonus = true
    end
    C.lastMult = 1
    serial = serial + 1
    local payload = string.format("%d|%s|%d|%d|%d|%d", serial, id, dur, target, math.random(0, 1000000), bonus and 1 or 0)
    gGlobalSyncTable.chaosEvent = payload
    log_effect(def, how or "host", target, dur, bonus)
    if C.on_fired then C.on_fired() end
    -- the host does not rely on its own sync-change hook firing
    on_event_changed(0, "", payload)
end

local function lobby_counts()
    local counts = {}
    local voteId = gGlobalSyncTable.chaosVoteId
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then
            local v = gPlayerSyncTable[i].chaosVote
            if gPlayerSyncTable[i].chaosVoteId == voteId and v ~= nil and v >= 1 and v <= MAX_OPTIONS then
                counts[v] = (counts[v] or 0) + 1
            end
        end
    end
    return counts
end

local function twitch_counts()
    local counts = {}
    local id, list = string.match(gGlobalSyncTable.chaosTwitchCounts, "^(%d+):(.*)$")
    if id == nil or tonumber(id) ~= gGlobalSyncTable.chaosVoteId then return counts end
    local k = 0
    for c in string.gmatch(list, "(%d+)") do
        k = k + 1
        if k > MAX_OPTIONS then break end
        local n = tonumber(c)
        if n > 0 then counts[k] = n end
    end
    return counts
end

-- the votes that decide the result, for the current source
local function counts_now()
    local src = gGlobalSyncTable.chaosSource
    if src == 3 then
        local counts = twitch_counts()
        if gGlobalSyncTable.chaosTwitchPlusLobby then
            for k, n in pairs(lobby_counts()) do counts[k] = (counts[k] or 0) + n end
        end
        return counts
    end
    return lobby_counts()
end

local function lobby_voting_allowed()
    local src = gGlobalSyncTable.chaosSource
    return src == 2 or (src == 3 and gGlobalSyncTable.chaosTwitchPlusLobby)
end

local io = {
    counts = counts_now,
    open_vote = function(options)
        gGlobalSyncTable.chaosVoteId = gGlobalSyncTable.chaosVoteId + 1
        for k = 1, MAX_OPTIONS do
            gGlobalSyncTable["chaosOpt" .. k] = options[k] or ""
        end
    end,
    fire = function(id, idx)
        local how = "RNG"
        if idx ~= nil then
            local counts = counts_now()
            how = ((gGlobalSyncTable.chaosSource == 3) and "Twitch vote " or "vote ") .. idx .. " (" .. (counts[idx] or 0) .. " votes)"
        end
        for k = 1, MAX_OPTIONS do gGlobalSyncTable["chaosOpt" .. k] = "" end
        fire_effect(id, how)
    end,
}

--------------------------------------------------------------------------- bridge with the companion app
-- App -> game: each player's app writes %APPDATA%\sm64coopdx\sav\chaos.modfs (a zip) holding votes.txt:
--     "seq|voteId|options|c1,c2,...,c9|channel|rev:cohost1,cohost2"   (seq changes every 500 ms while the app runs;
--      the host's game applies the co-host list whenever rev changes - that's the app's "Add co-host" button)
--   Every player's game re-reads its own file with mod_fs_reload() every 10 frames (verified with the real game).
--   Each player with the app publishes "voteId:counts:seq" + channel in gPlayerSyncTable (chaosAppVotes/Channel).
--   The HOST adds its own app's votes + the votes of every listed co-host (/chaos cohost <name>) into
--   chaosTwitchCounts. Only the host's app decides the number of options.
-- Game -> app: every player's game writes the "relay" key in its own chaos.sav from synced state, so a co-host's
--   overlay and dock mirror the host's vote:
--     "2|voteId|phase|secs|total|source|options|plusLobby|paused|meter|streak|bestStreak|fired|lobbyCounts|opts|
--      active|last|twitchCounts|role|people|players"   (players = everyone in the game, comma separated)
--   opts = id~name~kind, active = name~kind~secs, people = role~display~gameName~connected~votes (all ^-joined);
--   role = host | cohost | player; twitchCounts = all Twitch votes combined for the current vote.
mod_fs_hide_errors(true)
local bridgeFrame = 0
local appLastSeq, appSeenFrame = nil, -1000
local lastCohostRev = ""
local myApp = { voteId = -1, counts = "", channel = "" }
local seen = {}          -- [local index] = { value = last chaosAppVotes, frame = when it last changed }
local lastRelay = ""
local bestStreak = 0
local firedCount = 0
C.on_fired = function() firedCount = firedCount + 1 end

local function clean(text) return (string.gsub(tostring(text), "[|~%^\r\n]", " ")) end

local function parse_counts(list)
    local counts, k = {}, 0
    for c in string.gmatch(list or "", "(%d+)") do
        k = k + 1
        if k > MAX_OPTIONS then break end
        counts[k] = tonumber(c)
    end
    return counts
end

local function cohost_names()
    local names = {}
    for n in string.gmatch(gGlobalSyncTable.chaosCohosts or "", "[^,]+") do names[n] = true end
    return names
end

local function app_connected() return bridgeFrame - appSeenFrame < 90 end

local function bridge_read()
    local fs = mod_fs_reload()
    if fs == nil then return end
    local f = mod_fs_get_file(fs, "votes.txt")
    if f == nil then return end
    mod_fs_file_set_text_mode(f, true)
    mod_fs_file_rewind(f)
    local line = mod_fs_file_read_line(f)
    if line == nil then return end
    -- optional 6th field from the host's app: "rev:name1,name2" = the co-host list set with the app's + button
    local seq, voteId, opts, list, channel, rev, names =
        string.match(line, "^(%d+)|(%d+)|(%d+)|([%d,]*)|?([%w_]*)|?(%d*):?([^|]*)")
    if seq == nil then return end
    if network_is_server() and rev ~= nil and rev ~= "" and rev ~= "0" and rev ~= lastCohostRev then
        lastCohostRev = rev
        local clean_names = {}
        for n in string.gmatch(names or "", "[^,]+") do
            local n2 = string.lower((string.gsub(n, "^%s+", ""):gsub("%s+$", "")))
            if n2 ~= "" then table.insert(clean_names, n2) end
        end
        local value = table.concat(clean_names, ",")
        if value ~= gGlobalSyncTable.chaosCohosts then
            gGlobalSyncTable.chaosCohosts = value
            mod_storage_save("cohosts", value)
        end
    end
    if seq ~= appLastSeq then
        appLastSeq = seq
        appSeenFrame = bridgeFrame
    end
    myApp.voteId, myApp.counts, myApp.channel = tonumber(voteId), list, channel or ""
    if network_is_server() then
        opts = tonumber(opts)
        if opts >= 1 and opts <= MAX_OPTIONS then set_sync("chaosNumOptions", opts) end
    end
end

-- tell everyone what my app is doing (the host uses it if I'm a co-host; everyone shows it in the co-host list)
local function publish_my_app()
    local s = gPlayerSyncTable[0]
    local votes = app_connected() and (myApp.voteId .. ":" .. myApp.counts .. ":" .. (appLastSeq or "0")) or ""
    local channel = app_connected() and myApp.channel or ""
    if s.chaosAppVotes ~= votes then s.chaosAppVotes = votes end
    if s.chaosAppChannel ~= channel then s.chaosAppChannel = channel end
end

-- remember when each player's app last sent something (it changes every 500 ms while their app runs)
local function track_apps()
    for i = 0, MAX_PLAYERS - 1 do
        local v = gNetworkPlayers[i].connected and (gPlayerSyncTable[i].chaosAppVotes or "") or ""
        local e = seen[i]
        if e == nil or e.value ~= v then
            seen[i] = { value = v, frame = bridgeFrame }
        end
    end
end

local function app_live(i)
    local e = seen[i]
    return e ~= nil and e.value ~= "" and bridgeFrame - e.frame < 90
end

-- a player's app votes for the current vote (empty if their app is quiet or on an old vote)
local function app_counts(i)
    if not app_live(i) then return {} end
    local id, list = string.match(gPlayerSyncTable[i].chaosAppVotes or "", "^(%d+):([%d,]*)")
    if id == nil or tonumber(id) ~= gGlobalSyncTable.chaosVoteId then return {} end
    return parse_counts(list)
end

-- host: my app's votes + every listed co-host's app votes
local function host_combine()
    local total = {}
    if app_connected() and myApp.voteId == gGlobalSyncTable.chaosVoteId then
        for k, n in pairs(parse_counts(myApp.counts)) do total[k] = (total[k] or 0) + n end
    end
    local names = cohost_names()
    for i = 1, MAX_PLAYERS - 1 do
        local np = gNetworkPlayers[i]
        if np.connected and names[string.lower(np.name)] then
            for k, n in pairs(app_counts(i)) do total[k] = (total[k] or 0) + n end
        end
    end
    local out = {}
    for k = 1, MAX_OPTIONS do out[k] = tostring(total[k] or 0) end
    set_sync("chaosTwitchCounts", gGlobalSyncTable.chaosVoteId .. ":" .. table.concat(out, ","))
end

local function my_role()
    if network_is_server() then return "host" end
    if cohost_names()[string.lower(gNetworkPlayers[0].name)] then return "cohost" end
    return "player"
end

-- the host and every listed co-host, shown by Twitch channel when their app is running
local function people_list()
    local names = cohost_names()
    local out = {}
    for i = 0, MAX_PLAYERS - 1 do
        local np = gNetworkPlayers[i]
        if np.connected then
            local isHost = (np.globalIndex == 0)
            if isHost or names[string.lower(np.name)] then
                local live = app_live(i)
                local channel = gPlayerSyncTable[i].chaosAppChannel or ""
                local display = (live and channel ~= "") and channel or np.name
                local votes = 0
                for _, n in pairs(app_counts(i)) do votes = votes + n end
                table.insert(out, (isHost and "host" or "cohost") .. "~" .. clean(display) .. "~" .. clean(np.name)
                    .. "~" .. (live and 1 or 0) .. "~" .. votes)
            end
        end
    end
    -- listed co-hosts who aren't in the game right now
    for n in pairs(names) do
        local here = false
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and string.lower(gNetworkPlayers[i].name) == n then here = true end
        end
        if not here then table.insert(out, "cohost~" .. clean(n) .. "~" .. clean(n) .. "~-1~0") end
    end
    return table.concat(out, "^")
end

-- everyone in the game (for the app's "Add co-host" list)
local function player_names()
    local out = {}
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then table.insert(out, (string.gsub(clean(gNetworkPlayers[i].name), ",", " "))) end
    end
    return table.concat(out, ",")
end

local function bridge_write()
    local opts = {}
    for k = 1, MAX_OPTIONS do
        local id = gGlobalSyncTable["chaosOpt" .. k]
        local def = C.effects[id]
        if def ~= nil then table.insert(opts, id .. "~" .. clean(def.name) .. "~" .. def.kind) end
    end
    local act = {}
    for _, entry in ipairs(active) do
        if not entry.instant and #act < 8 then
            table.insert(act, clean(entry.def.name) .. "~" .. entry.def.kind .. "~" .. math.ceil(entry.frames / FPS))
        end
    end
    local lobby = lobby_counts()
    local lc = {}
    for k = 1, MAX_OPTIONS do lc[k] = tostring(lobby[k] or 0) end
    local twitch = ""
    local id, list = string.match(gGlobalSyncTable.chaosTwitchCounts, "^(%d+):(.*)$")
    if id ~= nil and tonumber(id) == gGlobalSyncTable.chaosVoteId then twitch = list end
    local relay = table.concat({
        "2", gGlobalSyncTable.chaosVoteId, gGlobalSyncTable.chaosPhase, gGlobalSyncTable.chaosSecs,
        gGlobalSyncTable.chaosTotal, gGlobalSyncTable.chaosSource, gGlobalSyncTable.chaosNumOptions,
        gGlobalSyncTable.chaosTwitchPlusLobby and 1 or 0, gGlobalSyncTable.chaosPaused and 1 or 0,
        gGlobalSyncTable.chaosMeter, gGlobalSyncTable.chaosStreak, gGlobalSyncTable.chaosBestStreak,
        gGlobalSyncTable.chaosFired, table.concat(lc, ","), table.concat(opts, "^"), table.concat(act, "^"),
        clean(gGlobalSyncTable.chaosLastEffect), twitch, my_role(), people_list(), player_names(),
    }, "|")
    if #relay > 1020 then relay = string.sub(relay, 1, 1020) end
    if relay ~= lastRelay then
        lastRelay = relay
        mod_storage_save("relay", relay)
    end
end

-- every player runs this (host and co-hosts alike), every 10 frames
local function bridge_update()
    bridgeFrame = bridgeFrame + 1
    if bridgeFrame % 10 ~= 0 then return end
    bridge_read()
    publish_my_app()
    track_apps()
    if network_is_server() then
        set_sync("chaosAppConnected", app_connected())
        host_combine()
        if C.streak > bestStreak then bestStreak = C.streak end
        set_sync("chaosStreak", C.streak)
        set_sync("chaosBestStreak", bestStreak)
        set_sync("chaosFired", firedCount)
        set_sync("chaosLastEffect", clean(effectLog[#effectLog] or ""))
    end
    bridge_write()
end

local function host_update()
    local src = gGlobalSyncTable.chaosSource
    C.settings.greed = gGlobalSyncTable.chaosGreed
    C.playerCount = network_player_connected_count()
    C.settings.numOptions = math.max(1, math.min(MAX_OPTIONS, gGlobalSyncTable.chaosNumOptions))
    local cfg = {
        source = (src == 1) and "auto" or "vote",
        cooldownFrames = gGlobalSyncTable.chaosCoolSecs * FPS,
        voteFrames = gGlobalSyncTable.chaosVoteSecs * FPS,
        rng = math.random,
    }
    if src ~= lastSource then
        lastSource = src
        for k = 1, MAX_OPTIONS do set_sync("chaosOpt" .. k, "") end
        if src == 0 then
            state = nil
            set_sync("chaosPhase", 0)
        else
            state = C.new_state(cfg)
        end
    end
    if state == nil then return end
    -- while a boss is out: never pick another boss, and pause entirely if the host turned that on
    local bossOut = false
    for _, entry in ipairs(active) do
        if entry.def.group == "boss" then bossOut = true end
    end
    C.blocked = bossOut and { boss = true } or {}
    local paused = bossOut and not gGlobalSyncTable.chaosDuringBoss
    set_sync("chaosPaused", paused)
    if paused then return end
    C.step(state, cfg, io)
    set_sync("chaosPhase", (state.phase == "vote") and 2 or 1)
    set_sync("chaosSecs", math.ceil(state.frames / FPS))
    set_sync("chaosTotal", (state.phase == "vote") and gGlobalSyncTable.chaosVoteSecs or gGlobalSyncTable.chaosCoolSecs)
    set_sync("chaosMeter", C.meter)
end

local function update()
    client_update()
    bridge_update()
    if network_is_server() then host_update() end
end
hook_event(HOOK_UPDATE, update)

------------------------------------------------------------------------------------------------ HUD
local function meter_label(meter)
    if meter >= 60 then return "Cursed", 255, 80, 80 end
    if meter >= 25 then return "Greedy", 255, 170, 80 end
    if meter <= -60 then return "Blessed", 80, 255, 120 end
    if meter <= -25 then return "Lucky", 140, 255, 160 end
    return "Fair", 220, 220, 220
end

local function print_centered(text, y, scale, r, g, b, a)
    local w = djui_hud_measure_text(text) * scale
    djui_hud_set_color(r, g, b, a or 255)
    djui_hud_print_text(text, (djui_hud_get_screen_width() - w) / 2, y, scale)
end

local function hud_render()
    if gGlobalSyncTable.chaosSource == 0 and #active == 0 then return end
    djui_hud_set_resolution(RESOLUTION_DJUI)
    djui_hud_set_font(FONT_NORMAL)
    local sw, sh = djui_hud_get_screen_width(), djui_hud_get_screen_height()

    -- Screen overlays from effects (drawn first so the text stays readable on top)
    for _, entry in ipairs(active) do
        if entry.def.hud ~= nil then
            local ok = pcall(entry.def.hud, entry, sw, sh)
            if not ok and not entry.hudErr then
                entry.hudErr = true
                djui_chat_message_create("\\#ff4040\\Chaos error drawing " .. entry.id)
            end
        end
    end

    -- Active effects (top centre)
    local y = 24
    for _, entry in ipairs(active) do
        if not entry.instant then
            local secs = math.ceil(entry.frames / FPS)
            local r, g, b = 255, 120, 120
            if entry.def.kind == "help" then r, g, b = 120, 255, 140 end
            local extra = ""
            if entry.def.label ~= nil then
                local ok, text = pcall(entry.def.label, entry)
                if ok and text ~= nil then extra = "  (" .. text .. ")" end
            end
            print_centered(entry.def.name .. extra .. "  " .. secs .. "s", y, 1.2, r, g, b)
            y = y + 40
        end
    end

    if gGlobalSyncTable.chaosSource == 0 then return end

    -- Panel (bottom centre)
    local panelW, barH = 560, 14
    local px = (sw - panelW) / 2
    local py = sh - 190
    local phase = gGlobalSyncTable.chaosPhase

    if phase == 2 then
        local n = math.max(1, math.min(MAX_OPTIONS, gGlobalSyncTable.chaosNumOptions))
        local top = sh - 70 - n * 30
        djui_hud_set_color(0, 0, 0, 170)
        djui_hud_render_rect(px - 12, top - 40, panelW + 24, n * 30 + 60)
        local how = "type /vote 1-" .. n
        if gGlobalSyncTable.chaosSource == 3 then
            how = "Twitch chat: type 1-" .. n .. (gGlobalSyncTable.chaosTwitchPlusLobby and "  (or /vote)" or "")
            if not gGlobalSyncTable.chaosAppConnected then how = how .. "  [app not connected]" end
        end
        print_centered("VOTE!  " .. how .. "   (" .. gGlobalSyncTable.chaosSecs .. "s)", top - 34, 1.1, 255, 255, 255)
        py = top
        local counts = counts_now()
        local mine = gPlayerSyncTable[0].chaosVote
        if gPlayerSyncTable[0].chaosVoteId ~= gGlobalSyncTable.chaosVoteId then mine = 0 end
        for k = 1, n do
            local id = gGlobalSyncTable["chaosOpt" .. k]
            local def = C.effects[id]
            if def ~= nil then
                local r, g, b = 255, 120, 120
                if def.kind == "help" then r, g, b = 120, 255, 140 end
                local label = k .. ".  " .. def.name .. "   [" .. (counts[k] or 0) .. "]"
                if mine == k then label = "> " .. label end
                djui_hud_set_color(r, g, b, 255)
                djui_hud_print_text(label, px, py + (k - 1) * 30, 1)
            end
        end
    else
        djui_hud_set_color(0, 0, 0, 150)
        djui_hud_render_rect(px - 12, py + 70, panelW + 24, 66)
        local total = math.max(gGlobalSyncTable.chaosTotal, 1)
        local frac = 1 - (gGlobalSyncTable.chaosSecs / total)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        if gGlobalSyncTable.chaosPaused then
            print_centered("Chaos paused: boss fight!", py + 76, 1, 255, 120, 120)
        else
            print_centered("Next chaos in " .. gGlobalSyncTable.chaosSecs .. "s", py + 76, 1, 255, 255, 255)
        end
        djui_hud_set_color(80, 80, 80, 255)
        djui_hud_render_rect(px, py + 112, panelW, barH)
        djui_hud_set_color(255, 200, 60, 255)
        djui_hud_render_rect(px, py + 112, panelW * frac, barH)
    end

    -- Greed meter
    if gGlobalSyncTable.chaosShowMeter and gGlobalSyncTable.chaosGreed > 0 then
        local label, r, g, b = meter_label(gGlobalSyncTable.chaosMeter)
        local text = "Lobby luck: " .. label
        djui_hud_set_color(r, g, b, 255)
        djui_hud_print_text(text, sw - djui_hud_measure_text(text) - 24, sh - 60, 1)
    end
end
hook_event(HOOK_ON_HUD_RENDER, hud_render)

------------------------------------------------------------------------------------------- commands
local function on_vote(msg)
    local n = tonumber(msg)
    if gGlobalSyncTable.chaosPhase ~= 2 then
        djui_chat_message_create("\\#ffb0ff\\There's no vote open right now.")
        return true
    end
    if not lobby_voting_allowed() then
        djui_chat_message_create("\\#ffb0ff\\This vote is happening in Twitch chat.")
        return true
    end
    local most = math.max(1, math.min(MAX_OPTIONS, gGlobalSyncTable.chaosNumOptions))
    if n == nil or n < 1 or n > most or gGlobalSyncTable["chaosOpt" .. math.floor(n)] == "" then
        djui_chat_message_create("\\#ffb0ff\\Vote with /vote 1-" .. most .. ".")
        return true
    end
    gPlayerSyncTable[0].chaosVote = math.floor(n)
    gPlayerSyncTable[0].chaosVoteId = gGlobalSyncTable.chaosVoteId
    djui_chat_message_create("\\#80ff80\\You voted for option " .. math.floor(n) .. ".")
    return true
end
hook_chat_command("vote", "1-9 - Vote for a chaos effect", on_vote)

local function clear_everyone()
    serial = serial + 1
    local payload = string.format("%d|__clear|0|-1|0", serial)
    gGlobalSyncTable.chaosEvent = payload
    on_event_changed(0, "", payload)
end

-- Per-effect on/off for /chaos enable|disable: off = rarity 0, on = back to its default rarity (d_rarity.lua)
local function set_effect_enabled(id, on)
    local def = C.effects[id]
    if def == nil then return false end
    if on then
        if (def.rarity or 0) == 0 then C.set_rarity(id, C.default_rarity(id)) end
    else
        C.set_rarity(id, 0)
    end
    return true
end

local function on_chaos(msg)
    if not network_is_server() then
        djui_chat_message_create("\\#ffb0ff\\Only the host can control Chaos.")
        return true
    end
    local cmd, arg = string.match(msg or "", "^(%S*)%s*(.-)$")
    cmd = string.lower(cmd or "")
    if cmd == "auto" then
        gGlobalSyncTable.chaosSource = 1
        djui_chat_message_create("Chaos: Auto (RNG)")
    elseif cmd == "vote" then
        gGlobalSyncTable.chaosSource = 2
        djui_chat_message_create("Chaos: Lobby votes")
    elseif cmd == "twitch" then
        gGlobalSyncTable.chaosSource = 3
        djui_chat_message_create("Chaos: Twitch votes" .. (gGlobalSyncTable.chaosAppConnected and " (app connected)"
            or " - start the Chaos Companion app"))
    elseif cmd == "off" then
        gGlobalSyncTable.chaosSource = 0
        clear_everyone()
        djui_chat_message_create("Chaos: Off")
    elseif cmd == "now" then
        local id = (arg ~= "" and C.effects[arg] ~= nil) and arg or C.roll(math.random)
        if id ~= nil then C.note_fired(id); fire_effect(id) end
    elseif cmd == "clear" then
        clear_everyone()
    elseif cmd == "log" then
        if #effectLog == 0 then djui_chat_message_create("Chaos log is empty.") end
        for i = math.max(1, #effectLog - 9), #effectLog do
            djui_chat_message_create(effectLog[i])
        end
    elseif cmd == "list" then
        for _, id in ipairs(C.order) do
            local def = C.effects[id]
            djui_chat_message_create(def.kind .. ": " .. id .. " - " .. def.name .. (def.enabled and (" (rarity " .. (def.rarity or 5) .. ")") or " (OFF)"))
        end
    elseif cmd == "cohost" or cmd == "uncohost" then
        -- find the player by (part of) their name
        local want, found = string.lower(arg), nil
        for i = 1, MAX_PLAYERS - 1 do
            local n = string.lower(gNetworkPlayers[i].name)
            if gNetworkPlayers[i].connected and want ~= "" and (n == want or (found == nil and string.find(n, want, 1, true))) then
                found = n
                if n == want then break end
            end
        end
        if found == nil and cmd == "uncohost" then found = want end
        if found == nil or found == "" then
            djui_chat_message_create("No player called '" .. arg .. "' is here.")
        else
            local names = cohost_names()
            names[found] = (cmd == "cohost") or nil
            local list = {}
            for n in pairs(names) do table.insert(list, n) end
            gGlobalSyncTable.chaosCohosts = table.concat(list, ",")
            mod_storage_save("cohosts", gGlobalSyncTable.chaosCohosts)
            djui_chat_message_create("Chaos: " .. found .. (cmd == "cohost" and " is now a co-host. Their Chaos Companion votes count." or " is no longer a co-host."))
        end
    elseif cmd == "cohosts" then
        local list = gGlobalSyncTable.chaosCohosts
        djui_chat_message_create("Chaos co-hosts: " .. ((list ~= "") and list or "none") .. ". /chaos cohost <name> to add, /chaos uncohost <name> to remove")
    elseif cmd == "effects" or cmd == "rarity" then
        C.open_rarity_menu()
    elseif cmd == "enable" or cmd == "disable" then
        local on = (cmd == "enable")
        if arg == "all" then
            for _, id in ipairs(C.order) do set_effect_enabled(id, on) end
            djui_chat_message_create("Chaos: all effects " .. (on and "on" or "off"))
        elseif set_effect_enabled(arg, on) then
            djui_chat_message_create("Chaos: " .. C.effects[arg].name .. " " .. (on and "on" or "off"))
        else
            djui_chat_message_create("No effect called '" .. arg .. "'. /chaos list shows them.")
        end
    else
        local names = { [0] = "Off", "Auto (RNG)", "Lobby votes", "Twitch votes" }
        djui_chat_message_create("Chaos: " .. names[gGlobalSyncTable.chaosSource] ..
            ", meter " .. C.meter .. ". /chaos auto|vote|twitch|off|now [id]|clear|log|list|enable|disable|effects|cohost <name>|uncohost <name>|cohosts")
    end
    return true
end
hook_chat_command("chaos", "auto|vote|twitch|off|now|clear|log|list|effects|enable|disable|cohost|uncohost|cohosts - control Chaos (host)", on_chaos)

--------------------------------------------------------------------------------------------- mod menu
local function host_only(fn)
    return function(index, value)
        if network_is_server() then fn(value) end
    end
end

hook_mod_menu_text("Chaos settings (host only)")

-- Named choices are buttons that show the current choice and step to the next one when clicked.
-- Numbers are typed into boxes. (Sliders were hard to set to an exact number.)
local SOURCE_NAMES = { [0] = "Off", "Auto (RNG)", "Lobby votes", "Twitch votes" }
local GREED_NAMES = { [0] = "Off", "Mild", "Harsh" }
local BOSS_NAMES = { [0] = "One per level", "Near the host", "Biggest group" }
local menuIds = {}

local function choice_labels()
    return {
        source = "Source: " .. (SOURCE_NAMES[gGlobalSyncTable.chaosSource] or "?") .. "   (click to change)",
        greed = "Greed: " .. (GREED_NAMES[gGlobalSyncTable.chaosGreed] or "?") .. "   (click to change)",
        boss = "Boss spawns: " .. (BOSS_NAMES[gGlobalSyncTable.chaosBossSpawn or 0] or "?") .. "   (click to change)",
    }
end

local function refresh_choice_labels()
    local labels = choice_labels()
    for key, index in pairs(menuIds) do
        if labels[key] ~= nil then update_mod_menu_element_name(index, labels[key]) end
    end
end

-- The game's slider moves one number EVERY FRAME while the stick is held (djui_slider.c, on_focus), so it races.
-- This keeps it to one step (of `step`) at a time, at most every 8 frames (~0.25 s) while held.
-- Mouse clicks/drags (jumps of more than one number) still go straight to the spot, snapped to the step.
local function stepped_slider(label, key, low, high, step, current, apply)
    local accepted, lastFrame, index = current, -100, nil
    index = hook_mod_menu_slider(label, current, low, high, function(_, value)
        if not network_is_server() then return end
        value = math.floor(tonumber(value) or accepted)
        if value == accepted then return end
        local now = get_global_timer()
        local new
        if math.abs(value - accepted) == 1 then
            if now - lastFrame < 8 then
                update_mod_menu_element_slider(index, accepted)   -- too soon: hold it where it was
                return
            end
            new = accepted + ((value > accepted) and step or -step)
        else
            new = low + math.floor((value - low) / step + 0.5) * step
        end
        new = math.max(low, math.min(high, new))
        lastFrame, accepted = now, new
        if new ~= value then update_mod_menu_element_slider(index, new) end
        apply(new)
        if key ~= nil then mod_storage_save(key, tostring(new)) end
    end)
    -- returns a setter so changes made elsewhere (chat commands) move the slider too
    return function(v)
        if v == accepted then return end
        accepted = v
        update_mod_menu_element_slider(index, v)
    end, index
end

local labels = choice_labels()
menuIds.rarity = hook_mod_menu_button("Effect rarity  (opens when you close this menu)", host_only(function()
    C.open_rarity_menu()
    djui_chat_message_create("\\#ffd060\\Close the pause menu to see Effect Rarity. (Tip: /chaos effects opens it straight away.)")
end))
menuIds.greed = hook_mod_menu_button(labels.greed, host_only(function()
    gGlobalSyncTable.chaosGreed = (gGlobalSyncTable.chaosGreed + 1) % 3
    refresh_choice_labels()
end))
menuIds.boss = hook_mod_menu_button(labels.boss, host_only(function()
    local v = ((gGlobalSyncTable.chaosBossSpawn or 0) + 1) % 3
    gGlobalSyncTable.chaosBossSpawn = v
    mod_storage_save("bossSpawn", tostring(v))
    refresh_choice_labels()
end))
-- Click-to-change buttons stay together: the controller cursor skips a button sitting between two checkboxes
-- (it jumps to the nearest item, and the checkbox straight below is nearer than the button's middle).
-- the label shows the chosen source by name ("Source: Twitch vote"), since the bar itself can only show a number
local function source_label() return "Source: " .. (SOURCE_NAMES[gGlobalSyncTable.chaosSource] or "?") end
local sourceSliderIndex
local set_source_slider
set_source_slider, sourceSliderIndex = stepped_slider(source_label(), nil, 0, 3, 1,
    gGlobalSyncTable.chaosSource, function(n)
        gGlobalSyncTable.chaosSource = n
        if n == 0 then clear_everyone() end
        update_mod_menu_element_name(sourceSliderIndex, source_label())
    end)
stepped_slider("Vote options", "numOptions", 1, 9, 1, gGlobalSyncTable.chaosNumOptions,
    function(n) gGlobalSyncTable.chaosNumOptions = n end)
stepped_slider("Vote length (sec)", "voteSecs", 5, 60, 5, gGlobalSyncTable.chaosVoteSecs,
    function(n) gGlobalSyncTable.chaosVoteSecs = n end)
stepped_slider("Between effects (sec)", "coolSecs", 5, 120, 5, gGlobalSyncTable.chaosCoolSecs,
    function(n) gGlobalSyncTable.chaosCoolSecs = n end)
hook_mod_menu_checkbox("Twitch: lobby /vote counts too", gGlobalSyncTable.chaosTwitchPlusLobby, host_only(function(v)
    gGlobalSyncTable.chaosTwitchPlusLobby = v
    mod_storage_save("twitchPlusLobby", tostring(v))
end))
hook_mod_menu_checkbox("Show lobby luck meter", true, host_only(function(v) gGlobalSyncTable.chaosShowMeter = v end))
hook_mod_menu_checkbox("Chaos during boss fights", gGlobalSyncTable.chaosDuringBoss, host_only(function(v)
    gGlobalSyncTable.chaosDuringBoss = v
    mod_storage_save("duringBoss", tostring(v))
end))
hook_mod_menu_checkbox("Hinders on one player hit everyone", targetedHindersAll, host_only(function(v)
    targetedHindersAll = v
    mod_storage_save("hindersAll", tostring(v))
end))
hook_mod_menu_checkbox("Helps on one player hit everyone", targetedHelpsAll, host_only(function(v)
    targetedHelpsAll = v
    mod_storage_save("helpsAll", tostring(v))
end))
hook_mod_menu_button("Trigger an effect now", host_only(function()
    local id = C.roll(math.random)
    if id ~= nil then C.note_fired(id); fire_effect(id) end
end))
hook_mod_menu_button("Clear all effects", host_only(clear_everyone))
hook_mod_menu_button("Show last 10 effects in chat", host_only(function() on_chaos("log") end))

-- keep the button labels right when settings change from chat commands (/chaos auto, /chaos twitch...)
local lastLabels = ""
hook_event(HOOK_UPDATE, function()
    if get_global_timer() % 30 ~= 0 then return end
    set_source_slider(gGlobalSyncTable.chaosSource)
    update_mod_menu_element_name(sourceSliderIndex, source_label())
    local l = choice_labels()
    local key = l.source .. l.greed .. l.boss
    if key ~= lastLabels then
        lastLabels = key
        refresh_choice_labels()
    end
end)

-- the Effect Rarity screen (d_rarity.lua) draws on top of everything else
hook_event(HOOK_ON_HUD_RENDER, function() if C.draw_rarity_menu then C.draw_rarity_menu() end end)

---------------------------------------------------------------------------------------------- API
-- Other mods: _G.ChaosMod.register({ id=..., name=..., kind="help"|"hinder", duration=seconds, onMario=function(m, entry) end })
--             _G.ChaosMod.set_filter(function(m) return not eliminated(m) end)   -- who effects may touch
_G.ChaosMod = {
    version = 1,
    register = C.register,
    set_filter = function(fn) C.filter = fn end,
    fire = function(id) if network_is_server() and C.effects[id] ~= nil then C.note_fired(id); fire_effect(id) end end,
    clear = function() if network_is_server() then clear_everyone() end end,
    is_running = function() return gGlobalSyncTable.chaosSource ~= 0 end,
}

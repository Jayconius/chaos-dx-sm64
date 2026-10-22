-- Chaos core: effect registry, greed meter, option picking and the vote/RNG state machine.
-- Pure Lua: no game API calls in here, so tests/core_test.lua can run it with a plain `lua`.
-- Files load alphabetically (a_core, b_effects, main), all sharing this mod's globals.

Chaos = Chaos or {}
local C = Chaos

C.effects = {}      -- id -> definition
C.order = {}        -- ids in registration order
C.meter = 0         -- greed meter, -100 (evil lobby, Help rewarded) .. +100 (greedy lobby, Help punished)
C.recent = {}       -- last fired ids, to avoid repeats
C.blocked = {}      -- groups that can't be picked right now (e.g. { boss = true } while a boss is out)
C.playerCount = 1   -- players in the lobby (the host updates it); effects with minPlayers need at least that many
C.RECENT_MAX = 3
C.METER_MAX = 100

C.settings = {
    greed = 2,              -- 0 off, 1 mild, 2 harsh
    numOptions = 4,         -- options shown per vote (2..9)
    allowZeroHelp = false,  -- may a maxed-out meter remove every Help option?
}

local GREED_STEP = { [0] = 0, [1] = 8, [2] = 15 }

-- Effect definition fields:
--   id (string, unique), name, kind ("help" | "hinder"), scope ("player" | "world"),
--   duration (seconds, 0 = instant), target ("all" | "random"), weight (default 1), enabled (default true),
--   minPlayers (optional: only offered/rolled when at least this many players are in the lobby),
--   onStart(entry), onMario(m, entry), onEnd(entry)  -- all optional
function C.register(def)
    assert(type(def) == "table", "chaos: effect must be a table")
    assert(type(def.id) == "string" and def.id ~= "", "chaos: effect needs an id")
    assert(def.kind == "help" or def.kind == "hinder", "chaos: kind must be help or hinder")
    def.name = def.name or def.id
    def.scope = def.scope or "player"
    def.target = def.target or "all"
    def.duration = def.duration or 20
    def.weight = def.weight or 1
    if def.enabled == nil then def.enabled = true end
    if C.effects[def.id] == nil then
        table.insert(C.order, def.id)
    end
    C.effects[def.id] = def
    return def
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Share of options that should be Help (0..1) for the current meter.
function C.help_share()
    if C.settings.greed == 0 then return 0.5 end
    return clamp(0.5 - C.meter / (2 * C.METER_MAX), 0, 1)
end

local function candidates(kind, taken)
    local list, total = {}, 0
    for _, id in ipairs(C.order) do
        local def = C.effects[id]
        if def.enabled and def.kind == kind and not taken[id] and not (def.group and C.blocked[def.group])
            and (def.minPlayers == nil or C.playerCount >= def.minPlayers) then
            local w = def.weight
            -- avoid immediate repeats
            for _, r in ipairs(C.recent) do
                if r == id then w = w * 0.15 end
            end
            if w > 0 then
                table.insert(list, { id = id, w = w })
                total = total + w
            end
        end
    end
    return list, total
end

local function weighted_take(kind, taken, rng)
    local list, total = candidates(kind, taken)
    if #list == 0 then return nil end
    local roll = rng() * total
    for _, c in ipairs(list) do
        roll = roll - c.w
        if roll <= 0 then return c.id end
    end
    return list[#list].id
end

-- Pick `n` distinct effects, mixing Help/Hinder according to the greed meter.
-- Always keeps at least one of each kind (unless allowZeroHelp and the meter is maxed).
function C.pick_options(n, rng)
    n = n or C.settings.numOptions
    rng = rng or math.random
    local lo = 1
    if C.settings.allowZeroHelp and C.settings.greed > 0 and C.meter >= C.METER_MAX then lo = 0 end
    local nHelp = clamp(math.floor(n * C.help_share() + 0.5), lo, n - 1)
    local taken, out = {}, {}
    local plan = {}
    for _ = 1, nHelp do table.insert(plan, "help") end
    for _ = 1, n - nHelp do table.insert(plan, "hinder") end
    for _, kind in ipairs(plan) do
        local id = weighted_take(kind, taken, rng)
        if id == nil then
            -- not enough effects of this kind: fall back to the other kind
            id = weighted_take(kind == "help" and "hinder" or "help", taken, rng)
        end
        if id ~= nil then
            taken[id] = true
            table.insert(out, id)
        end
    end
    -- shuffle so Help/Hinder positions are not predictable
    for i = #out, 2, -1 do
        local j = math.floor(rng() * i) + 1
        out[i], out[j] = out[j], out[i]
    end
    return out
end

-- RNG source: one effect, Help/Hinder odds follow the meter.
function C.roll(rng)
    rng = rng or math.random
    -- never fully one-sided in RNG mode: luck can swing, it can't be rigged
    local share = clamp(C.help_share(), 0.1, 0.9)
    local kind = (rng() < share) and "help" or "hinder"
    local id = weighted_take(kind, {}, rng)
    if id == nil then id = weighted_take(kind == "help" and "hinder" or "help", {}, rng) end
    return id
end

-- counts: array index -> number of votes. Returns the winning option index.
-- Ties are broken randomly; no votes at all picks a random option.
function C.resolve_vote(options, counts, rng)
    rng = rng or math.random
    local best, tied = -1, {}
    for i = 1, #options do
        local c = counts[i] or 0
        if c > best then
            best, tied = c, { i }
        elseif c == best then
            table.insert(tied, i)
        end
    end
    if #tied == 0 then return nil end
    return tied[math.floor(rng() * #tied) + 1]
end

-- Called whenever an effect fires; moves the meter and remembers recents.
C.streak = 0        -- Hinder effects in a row
C.lastMult = 1      -- duration multiplier earned by the effect that just fired (streak bonus)

function C.note_fired(id)
    local def = C.effects[id]
    if def == nil then return end
    -- Streak bonus: after 3+ Hinders in a row, the next Help lasts longer (x1.5, or x2 after 5).
    C.lastMult = 1
    if def.kind == "help" then
        if C.streak >= 3 and C.settings.greed > 0 then
            C.lastMult = (C.streak >= 5) and 2 or 1.5
        end
        C.streak = 0
    else
        C.streak = C.streak + 1
    end
    local step = GREED_STEP[C.settings.greed] or 0
    if step > 0 then
        -- gentle pull back toward neutral, then push by this effect's kind
        C.meter = C.meter - math.floor(C.meter * 0.1)
        if def.kind == "help" then
            C.meter = C.meter + step
        else
            C.meter = C.meter - step
        end
        C.meter = clamp(C.meter, -C.METER_MAX, C.METER_MAX)
    else
        C.meter = 0
    end
    table.insert(C.recent, id)
    while #C.recent > C.RECENT_MAX do table.remove(C.recent, 1) end
end

-- Scheduler (host only). state = { phase = "off"|"cooldown"|"vote", frames = n, options = {...} }
-- cfg = { source = "auto"|"vote", cooldownFrames, voteFrames, rng }
-- io  = { counts() -> table, open_vote(options), fire(id), tick(state) (optional) }
function C.new_state(cfg)
    return { phase = "cooldown", frames = cfg.cooldownFrames, options = {} }
end

function C.step(state, cfg, io)
    if state.phase == "off" then return end
    state.frames = state.frames - 1
    if state.frames > 0 then return end

    if state.phase == "cooldown" then
        if cfg.source == "auto" then
            local id = C.roll(cfg.rng)
            if id ~= nil then
                C.note_fired(id)
                io.fire(id)
            end
            state.frames = cfg.cooldownFrames
        else
            state.options = C.pick_options(C.settings.numOptions, cfg.rng)
            if #state.options == 0 then
                state.frames = cfg.cooldownFrames
                return
            end
            io.open_vote(state.options)
            state.phase = "vote"
            state.frames = cfg.voteFrames
        end
    elseif state.phase == "vote" then
        local idx = C.resolve_vote(state.options, io.counts(), cfg.rng)
        if idx ~= nil then
            local id = state.options[idx]
            C.note_fired(id)
            io.fire(id, idx)
        end
        state.options = {}
        state.phase = "cooldown"
        state.frames = cfg.cooldownFrames
    end
end

return C

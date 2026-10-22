-- Run: lua tests/core_test.lua   (from the repository root, with Lua 5.4)
dofile("mod/chaos/a_core.lua")
local C = Chaos

local failed = 0
local function check(cond, msg)
    if not cond then failed = failed + 1; print("FAIL: " .. msg) else print("ok:   " .. msg) end
end

-- deterministic rng
local seed = 12345
local function rng()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
end

for i = 1, 6 do C.register({ id = "h" .. i, kind = "help", duration = 10 }) end
for i = 1, 6 do C.register({ id = "x" .. i, kind = "hinder", duration = 10 }) end

local function counts_of(opts)
    local h, x = 0, 0
    for _, id in ipairs(opts) do
        if C.effects[id].kind == "help" then h = h + 1 else x = x + 1 end
    end
    return h, x
end

-- 1. neutral meter: even mix, distinct, right count
C.meter = 0
local o = C.pick_options(4, rng)
local h, x = counts_of(o)
check(#o == 4 and h == 2 and x == 2, "neutral meter gives 2 help + 2 hinder")
local seen, dup = {}, false
for _, id in ipairs(o) do if seen[id] then dup = true end seen[id] = true end
check(not dup, "options are distinct")

-- 2. greedy lobby: fewer help, but at least one of each
C.meter = 100
h, x = counts_of(C.pick_options(4, rng))
check(h == 1 and x == 3, "meter +100 gives 1 help + 3 hinder (always one of each)")

-- 3. evil lobby: more help
C.meter = -100
h, x = counts_of(C.pick_options(4, rng))
check(h == 3 and x == 1, "meter -100 gives 3 help + 1 hinder")

-- 4. allowZeroHelp removes all help at the cursed end
C.settings.allowZeroHelp = true
C.meter = 100
h, x = counts_of(C.pick_options(4, rng))
check(h == 0 and x == 4, "allowZeroHelp: 0 help at meter +100")
C.settings.allowZeroHelp = false

-- 5. greed off keeps meter at 0 and an even mix
C.settings.greed = 0
C.meter = 50
C.note_fired("h1")
check(C.meter == 0, "greed off resets meter to 0")
h, x = counts_of(C.pick_options(4, rng))
check(h == 2 and x == 2, "greed off gives an even mix")
C.settings.greed = 2

-- 6. note_fired moves meter the right way and is clamped
C.meter = 0
C.note_fired("h2")
check(C.meter > 0, "help winner pushes meter toward greedy")
C.note_fired("x2")
C.note_fired("x3")
check(C.meter < 0, "hinder winners push meter toward evil")
C.meter = 99
for _ = 1, 10 do C.note_fired("h3") end
check(C.meter <= 100 and C.meter >= -100, "meter stays clamped")

-- 7. vote resolution
local opts = { "a", "b", "c", "d" }
check(C.resolve_vote(opts, { 0, 5, 1, 0 }, rng) == 2, "most votes wins")
local tie = C.resolve_vote(opts, { 3, 0, 3, 0 }, rng)
check(tie == 1 or tie == 3, "tie resolves to one of the tied options")
local none = C.resolve_vote(opts, {}, rng)
check(none ~= nil and none >= 1 and none <= 4, "no votes picks a random option")

-- 8. RNG roll follows the meter
C.meter = 100
local helpRolls = 0
for _ = 1, 400 do
    local id = C.roll(rng)
    if C.effects[id].kind == "help" then helpRolls = helpRolls + 1 end
end
check(helpRolls < 120, "greedy meter makes help rolls rare (" .. helpRolls .. "/400)")
C.meter = -100
helpRolls = 0
for _ = 1, 400 do
    local id = C.roll(rng)
    if C.effects[id].kind == "help" then helpRolls = helpRolls + 1 end
end
check(helpRolls > 280, "evil meter makes help rolls common (" .. helpRolls .. "/400)")

-- 9. scheduler: vote cycle
C.meter = 0
C.recent = {}
local fired, opened = {}, nil
local state = C.new_state({ cooldownFrames = 3 })
local cfg = { source = "vote", cooldownFrames = 3, voteFrames = 4, rng = rng }
local io = {
    counts = function() return { 0, 2, 0, 0 } end,
    open_vote = function(options) opened = options end,
    fire = function(id) table.insert(fired, id) end,
}
for _ = 1, 3 do C.step(state, cfg, io) end
check(state.phase == "vote" and opened ~= nil and #opened == 4, "cooldown ends and opens a vote")
for _ = 1, 4 do C.step(state, cfg, io) end
check(#fired == 1 and fired[1] == opened[2], "vote end fires the winning option")
check(state.phase == "cooldown", "back to cooldown after a vote")

-- 10. scheduler: auto source fires without votes
fired, opened = {}, nil
state = C.new_state({ cooldownFrames = 2 })
cfg = { source = "auto", cooldownFrames = 2, voteFrames = 4, rng = rng }
for _ = 1, 6 do C.step(state, cfg, io) end
check(#fired == 3 and opened == nil, "auto source fires every cooldown, never opens a vote")

-- 10b. streak bonus: 3+ hinders in a row makes the next help last longer, once
C.settings.greed = 2
C.streak = 0
C.note_fired("x1"); C.note_fired("x2"); C.note_fired("x3")
check(C.streak == 3, "three hinders build a streak of 3")
C.note_fired("h1")
check(C.lastMult == 1.5, "help after a streak of 3 gets x1.5")
check(C.streak == 0, "streak resets after the help")
C.note_fired("h2")
check(C.lastMult == 1, "next help gets no bonus")
for _ = 1, 5 do C.note_fired("x4") end
C.note_fired("h3")
check(C.lastMult == 2, "help after a streak of 5 gets x2")
C.note_fired("x5"); C.note_fired("x6"); C.note_fired("x1")
C.settings.greed = 0
C.note_fired("h4")
check(C.lastMult == 1, "no streak bonus when greed is off")
C.settings.greed = 2

-- 10c. blocked groups are never picked
C.register({ id = "bossA", kind = "hinder", group = "boss" })
C.register({ id = "bossB", kind = "hinder", group = "boss" })
C.blocked = { boss = true }
local sawBoss = false
for _ = 1, 300 do
    local id = C.roll(rng)
    if C.effects[id].group == "boss" then sawBoss = true end
    for _, o in ipairs(C.pick_options(4, rng)) do
        if C.effects[o].group == "boss" then sawBoss = true end
    end
end
check(not sawBoss, "blocked group is never rolled or offered")
C.blocked = {}

-- 11. register validation
local ok = pcall(C.register, { id = "bad", kind = "nope" })
check(not ok, "bad kind is rejected")

if failed > 0 then
    print(failed .. " test(s) FAILED")
    os.exit(1)
end
print("all tests passed")

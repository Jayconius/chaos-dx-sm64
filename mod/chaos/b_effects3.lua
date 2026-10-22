-- Chaos effects, batch 3: Lightning Storm, Hot Potato, Tailwind, Hover Boots, Rainbow Star, Lava Rising,
-- Low-Res Mode, Spotlight, Boo Mode, Bird Attack and the Mega Goomba boss.
-- Hook order reminder: onBeforeMario (controls) -> Mario moves (onBeforePhys before each step) -> onMario.

local C = Chaos

local function is_local(m) return m.playerIndex == 0 end
local function in_air(m) return (m.action & ACT_FLAG_AIR) ~= 0 end
local function swimming(m) return (m.action & ACT_FLAG_SWIMMING) ~= 0 end
local function grounded(m) return not in_air(m) and not swimming(m) end

local function my_global() return gNetworkPlayers[0].globalIndex end

local function name_of_global(g)
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected and gNetworkPlayers[i].globalIndex == g then
            return network_get_player_text_color_string(i) .. gNetworkPlayers[i].name .. "\\#ffffff\\"
        end
    end
    return "someone"
end

-- connected players' local indexes, sorted by global index (the same order on every client)
local function sorted_players()
    local ids = {}
    for i = 0, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected then table.insert(ids, i) end
    end
    table.sort(ids, function(a, b) return gNetworkPlayers[a].globalIndex < gNetworkPlayers[b].globalIndex end)
    return ids
end

-- Is player i in the same level, area and act as me? (a spawned object only exists in the spawner's level/area)
local function same_place(i)
    local a, b = gNetworkPlayers[0], gNetworkPlayers[i]
    return b.currLevelNum == a.currLevelNum and b.currAreaIndex == a.currAreaIndex and b.currActNum == a.currActNum
end

-- One "leader" per level/area: the player there with the lowest global index. Leaders spawn bosses, so every
-- occupied level gets exactly one, however many players are in it.
local function i_am_area_leader()
    local me = gNetworkPlayers[0].globalIndex
    for i = 1, MAX_PLAYERS - 1 do
        if gNetworkPlayers[i].connected and same_place(i) and gNetworkPlayers[i].globalIndex < me then return false end
    end
    return true
end
C.i_am_area_leader = i_am_area_leader

-- Where should a boss appear? Host setting gGlobalSyncTable.chaosBossSpawn:
--   0 = one per level (each level's leader spawns next to themselves)
--   1 = near the host (only the host spawns, in the host's level)
--   2 = biggest group (only the level with the most players; next to the player with the most others nearby)
-- Returns x, floorY, z when THIS player should spawn the boss, or nil when someone else does.
gGlobalSyncTable.chaosBossSpawn = tonumber(mod_storage_load("bossSpawn") or "") or 0

local function place_key(i)
    local n = gNetworkPlayers[i]
    return n.currLevelNum * 100000 + n.currAreaIndex * 1000 + n.currActNum
end

function C.boss_spawn_point(distance)
    local mode = gGlobalSyncTable.chaosBossSpawn
    local anchor = 0
    if mode == 1 then
        if not network_is_server() then return nil end
    elseif mode == 2 then
        -- the busiest level/area (ties: the lower level number)
        local counts, bestKey, bestCount = {}, nil, -1
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected then
                local k = place_key(i)
                counts[k] = (counts[k] or 0) + 1
            end
        end
        for k, c in pairs(counts) do
            if c > bestCount or (c == bestCount and k < bestKey) then bestKey, bestCount = k, c end
        end
        if place_key(0) ~= bestKey or not i_am_area_leader() then return nil end
        -- inside it, the player with the most other players within 1500 units
        local bestN = -1
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and same_place(i) then
                local p, n = gMarioStates[i].pos, 0
                for j = 0, MAX_PLAYERS - 1 do
                    if j ~= i and gNetworkPlayers[j].connected and same_place(j) then
                        local q = gMarioStates[j].pos
                        local dx, dz = p.x - q.x, p.z - q.z
                        if dx * dx + dz * dz < 1500 * 1500 then n = n + 1 end
                    end
                end
                if n > bestN then anchor, bestN = i, n end
            end
        end
    else
        if not i_am_area_leader() then return nil end
    end
    local m = gMarioStates[anchor]
    local a = math.random(0, 65535)
    local x, z = m.pos.x + sins(a) * distance, m.pos.z + coss(a) * distance
    local floor = find_floor_height(x, m.pos.y + 400, z)
    if floor < -10000 then x, z, floor = m.pos.x, m.pos.z, m.pos.y end
    return x, floor, z
end

local function hsv(h)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local q, t = math.floor(255 * (1 - f)), math.floor(255 * f)
    if i == 0 then return 255, t, 0 elseif i == 1 then return q, 255, 0 elseif i == 2 then return 0, 255, t
    elseif i == 3 then return 0, q, 255 elseif i == 4 then return t, 0, 255 end
    return 255, 0, q
end

local CHARACTER_MODEL = {
    [CT_MARIO] = E_MODEL_MARIO, [CT_LUIGI] = E_MODEL_LUIGI, [CT_TOAD] = E_MODEL_TOAD_PLAYER,
    [CT_WALUIGI] = E_MODEL_WALUIGI, [CT_WARIO] = E_MODEL_WARIO,
}
local function restore_model(i)
    local np = gNetworkPlayers[i]
    obj_set_model_extended(gMarioStates[i].marioObj, CHARACTER_MODEL[np.overrideModelIndex] or E_MODEL_MARIO)
end

------------------------------------------------------------------------------------------------ HELP

C.register({
    id = "tailwind", name = "Tailwind", kind = "help", duration = 15, group = "wind",
    label = function() return "the wind follows you" end,
    -- the wind always blows the way you're running
    onBeforePhys = function(m)
        if not is_local(m) or swimming(m) then return end
        if grounded(m) and m.forwardVel > 2 then
            m.vel.x = m.vel.x + sins(m.faceAngle.y) * 9
            m.vel.z = m.vel.z + coss(m.faceAngle.y) * 9
        elseif in_air(m) then
            m.vel.x = m.vel.x + sins(m.faceAngle.y) * 4
            m.vel.z = m.vel.z + coss(m.faceAngle.y) * 4
        end
    end,
})

C.register({
    id = "hover_boots", name = "Hover Boots", kind = "help", duration = 20, group = "gravity",
    label = function() return "hold A while falling" end,
    onStart = function(entry) entry.hover = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if not in_air(m) then entry.hover = 0 end
        if (entry.hovering or false) then set_mario_particle_flags(m, PARTICLE_SPARKLES, 0) end
    end,
    -- up to ~2.5 seconds of hovering per jump
    onBeforePhys = function(m, entry)
        entry.hovering = false
        if not is_local(m) or not in_air(m) or swimming(m) then return end
        if (m.controller.buttonDown & A_BUTTON) ~= 0 and m.vel.y < 0 and entry.hover < 75 then
            m.vel.y = -1
            entry.hover = entry.hover + 1
            entry.hovering = true
        end
    end,
})

C.register({
    id = "rainbow_star", name = "Rainbow Star", kind = "help", duration = 10, target = "random", group = "size",
    onStart = function(entry) entry.tick = 0 end,
    onBeforePhys = function(m)
        if is_local(m) and grounded(m) then
            m.vel.x = m.vel.x * 1.35
            m.vel.z = m.vel.z * 1.35
        end
    end,
    onMario = function(m, entry)
        set_mario_particle_flags(m, PARTICLE_SPARKLES, 0)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if m.invincTimer < 3 then m.invincTimer = 3 end
        if entry.tick % 3 == 0 then
            local r, g, b = hsv((entry.tick / 45) % 1)
            local c = { r = r, g = g, b = b }
            for part = 0, 7 do network_player_set_override_palette_color(gNetworkPlayers[0], part, c) end
            entry.colored = true
        end
    end,
    onEnd = function(entry)
        if entry.colored then network_player_reset_override_palette(gNetworkPlayers[0]) end
    end,
})

---------------------------------------------------------------------------------------------- HINDER

-- Lightning Storm: dark sky, warning rings, then a strike with a white flash
C.register({
    id = "lightning_storm", name = "Lightning Storm", kind = "hinder", scope = "world", duration = 15, group = "light",
    onStart = function(entry)
        entry.tick = 0
        entry.pending = {}
        entry.flash = 0
        le_set_mode(LE_MODE_AFFECT_ALL_SHADED_AND_COLORED)
        le_set_ambient_color(70, 70, 105)
    end,
    onEnd = function(entry)
        le_set_ambient_color(255, 255, 255)
        le_set_mode(LE_MODE_AFFECT_ONLY_GEOMETRY_MODE)
    end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if entry.flash > 0 then entry.flash = entry.flash - 1 end
        if entry.tick % 26 == 0 then
            -- strikes land ~1.2 s after their ring appears; about half aimed at you
            local x, z = C.aim_drop(m, 900, 1500, 40)
            local ground = find_floor_height(x, m.pos.y + 400, z)
            if ground > -10000 then
                C.add_warning(x, ground, z, 200, 36)
                table.insert(entry.pending, { x = x, y = ground, z = z, at = entry.tick + 36 })
            end
        end
        for i = #entry.pending, 1, -1 do
            local p = entry.pending[i]
            if entry.tick >= p.at then
                C.blast(nil, p.x, p.y, p.z, 1.8, 200, 2)
                entry.flash = 5
                table.remove(entry.pending, i)
            end
        end
    end,
    hud = function(entry, sw, sh)
        if (entry.flash or 0) > 0 then
            djui_hud_set_color(255, 255, 255, 40 * entry.flash)
            djui_hud_render_rect(0, 0, sw, sh)
        end
    end,
})

-- Hot Potato: one player holds it; touching another player passes it; whoever holds it at the end explodes.
-- The host decides the holder (gGlobalSyncTable.chaosPotato = global index); everyone reads it.
gGlobalSyncTable.chaosPotato = -1

C.register({
    id = "hot_potato", name = "Hot Potato", kind = "hinder", duration = 20, group = "potato",
    onStart = function(entry)
        entry.tick = 0
        entry.lastSeen = -2
        entry.lastPass = 0
        if network_is_server() then
            local ids = sorted_players()
            if #ids > 0 then
                gGlobalSyncTable.chaosPotato = gNetworkPlayers[ids[(entry.seed % #ids) + 1]].globalIndex
            end
        end
    end,
    label = function(entry)
        local h = gGlobalSyncTable.chaosPotato
        if h == my_global() then return "YOU have it! touch someone!" end
        return "don't let it touch you"
    end,
    onMario = function(m, entry)
        local holder = gGlobalSyncTable.chaosPotato
        if holder >= 0 and gNetworkPlayers[m.playerIndex].globalIndex == holder then
            set_mario_particle_flags(m, PARTICLE_FIRE, 0)   -- everyone can see who has it
        end
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if holder ~= entry.lastSeen then
            entry.lastSeen = holder
            if holder >= 0 then
                djui_chat_message_create("\\#ff8040\\HOT POTATO: " .. name_of_global(holder) .. "\\#ff8040\\ has it!")
            end
        end
        -- host: pass it on when the holder touches someone (1 second between passes)
        if network_is_server() and holder >= 0 and entry.tick - entry.lastPass > 30 then
            local hi = network_local_index_from_global(holder)
            if hi ~= nil and hi >= 0 and gNetworkPlayers[hi].connected then
                local hm = gMarioStates[hi]
                for _, j in ipairs(sorted_players()) do
                    if j ~= hi then
                        local o = gMarioStates[j]
                        local dx, dy, dz = o.pos.x - hm.pos.x, o.pos.y - hm.pos.y, o.pos.z - hm.pos.z
                        if dx * dx + dz * dz < 140 * 140 and math.abs(dy) < 160 then
                            gGlobalSyncTable.chaosPotato = gNetworkPlayers[j].globalIndex
                            entry.lastPass = entry.tick
                            break
                        end
                    end
                end
            end
        end
    end,
    hud = function(entry, sw, sh)
        if gGlobalSyncTable.chaosPotato == my_global() then
            local a = 60 + 50 * math.sin((entry.tick or 0) / 4)
            djui_hud_set_color(255, 60, 0, a)
            djui_hud_render_rect(0, 0, sw, 24)
            djui_hud_render_rect(0, sh - 24, sw, 24)
            djui_hud_render_rect(0, 0, 24, sh)
            djui_hud_render_rect(sw - 24, 0, 24, sh)
        end
    end,
    onEnd = function(entry)
        -- only a natural ending explodes (clearing or replacing the effect doesn't)
        if entry.frames <= 0 and gGlobalSyncTable.chaosPotato == my_global() then
            local m = gMarioStates[0]
            C.blast(nil, m.pos.x, m.pos.y, m.pos.z, 3.0, 300, 3)
            djui_chat_message_create("\\#ff4020\\BOOM! The hot potato went off!")
        end
        if network_is_server() then gGlobalSyncTable.chaosPotato = -1 end
    end,
})

-- Lava Rising: the water rises and burns. Levels with no water get The Floor Is Lava instead.
C.register({
    id = "lava_rising", name = "Lava Rising", kind = "hinder", scope = "world", duration = 15, group = "water",
    envfx = ENVFX_LAVA_BUBBLES,
    onStart = function(entry)
        entry.base = get_water_level(0)
        entry.noWater = (entry.base == nil or entry.base < -10000)
        entry.h = 0
        entry.ground = 0
        entry.burn = 0
        if entry.noWater then
            djui_chat_message_create("\\#ff8040\\No water here... so the floor is lava instead!")
        end
    end,
    label = function(entry) return entry.noWater and "stay off the ground!" or "get out of the water!" end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if entry.noWater then
            C.effects.lava_floor.onMario(m, entry)
            return
        end
        if entry.h < 900 then entry.h = entry.h + 6 end
        set_water_level(0, entry.base + entry.h, false)
        if swimming(m) or m.pos.y < entry.base + entry.h - 20 then
            entry.burn = entry.burn + 1
            set_mario_particle_flags(m, PARTICLE_FIRE, 0)
            if entry.burn % 20 == 0 and m.health > 0x100 then
                m.health = m.health - 0x60
                m.hurtCounter = 0
            end
        else
            entry.burn = 0
        end
    end,
    onEnd = function(entry)
        if not entry.noWater and entry.base ~= nil then set_water_level(0, entry.base, false) end
    end,
    hud = function(entry, sw, sh)
        if (entry.burn or 0) > 0 then
            djui_hud_set_color(255, 90, 0, 60)
            djui_hud_render_rect(0, 0, sw, sh)
        end
    end,
})

-- Low-Res Mode: a chunky grid and scanlines over the screen (no real pixelation is possible from Lua)
C.register({
    id = "low_res", name = "Low-Res Mode", kind = "hinder", duration = 15, group = "screen",
    hud = function(entry, sw, sh)
        local cell = 14
        djui_hud_set_color(0, 0, 0, 95)
        for x = 0, sw, cell do djui_hud_render_rect(x, 0, 3, sh) end
        for y = 0, sh, cell do djui_hud_render_rect(0, y, sw, 3) end
        djui_hud_set_color(40, 255, 40, 18)
        djui_hud_render_rect(0, 0, sw, sh)
    end,
})

-- Spotlight: everything is black except a circle around your own Mario
local spotPos, spotOut = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
C.register({
    id = "spotlight", name = "Spotlight", kind = "hinder", duration = 15, group = "screen",
    hud = function(entry, sw, sh)
        local m = gMarioStates[0]
        spotPos.x, spotPos.y, spotPos.z = m.pos.x, m.pos.y + 70, m.pos.z
        djui_hud_set_color(0, 0, 0, 248)
        if not djui_hud_world_pos_to_screen_pos(spotPos, spotOut) then
            djui_hud_render_rect(0, 0, sw, sh)
            return
        end
        local cx, cy, r, band = spotOut.x, spotOut.y, sh * 0.24, 4
        for y = 0, sh, band do
            local dy = y + band / 2 - cy
            if math.abs(dy) >= r then
                djui_hud_render_rect(0, y, sw, band)
            else
                local half = math.sqrt(r * r - dy * dy)
                djui_hud_render_rect(0, y, math.max(cx - half, 0), band)
                djui_hud_render_rect(cx + half, y, math.max(sw - (cx + half), 0), band)
            end
        end
    end,
})

-- Boo Mode: a random player becomes a Boo that drifts where it likes; little control, can float off edges
C.register({
    id = "boo_mode", name = "Boo Mode", kind = "hinder", duration = 15, target = "random", group = "ghost",
    onStart = function(entry)
        entry.tick = 0
        entry.drift = (entry.seed * 977) % 65536
    end,
    label = function(entry)
        if entry.target == my_global() then return "you're a Boo! you barely steer" end
        return name_of_global(entry.target) .. " is a Boo"
    end,
    onBeforeMario = function(m)
        if is_local(m) then
            m.controller.stickX = m.controller.stickX * 0.25
            m.controller.stickY = m.controller.stickY * 0.25
        end
    end,
    onBeforePhys = function(m, entry)
        if not is_local(m) or swimming(m) or not in_air(m) then return end
        m.vel.x = m.vel.x + sins(entry.drift) * 7
        m.vel.z = m.vel.z + coss(entry.drift) * 7
        -- float about 90 units above the floor; over a pit you slowly sink
        local floor = find_floor_height(m.pos.x, m.pos.y + 50, m.pos.z)
        local bob = math.sin(entry.tick / 12) * 1.2
        if m.pos.y - floor < 90 then m.vel.y = 2.5 + bob else m.vel.y = -1.6 + bob end
    end,
    onMario = function(m, entry)
        obj_set_model_extended(m.marioObj, E_MODEL_BOO)
        -- the Boo model fades with the object's opacity, which is 0 on Mario (that made it invisible)
        m.marioObj.oOpacity = 190
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        -- the Boo wanders: its drift direction turns slowly back and forth
        entry.drift = (entry.drift + math.floor(math.sin(entry.tick / 40) * 0x280)) % 65536
        -- the Boo shows Mario's facing, so turn him (smoothly) toward the way he's actually drifting
        local speed = math.sqrt(m.vel.x * m.vel.x + m.vel.z * m.vel.z)
        if speed > 2 then
            m.faceAngle.y = approach_s16_symmetric(m.faceAngle.y, atan2s(m.vel.z, m.vel.x), 0x500)
        end
        if grounded(m) and m.health > 0x100 then
            set_mario_action(m, ACT_FREEFALL, 0)
            m.vel.y = 12
        end
    end,
    onEnd = function(entry)
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and (entry.target < 0 or gNetworkPlayers[i].globalIndex == entry.target) then
                restore_model(i)
                gMarioStates[i].marioObj.oOpacity = 255
            end
        end
    end,
})

-- Bird Attack: a big bird (Klepto's model) swoops at the chosen player, carries them up and drops them.
-- The victim's own game runs the bird, so it's local; everyone else sees the victim fly.
-- Klepto's animations: 6 = dive, 0 = flapping (a custom object has no animation unless given one, which made
-- the bird look frozen/dead)
local KLEPTO_DIVE, KLEPTO_FLAP = 6, 0

local function bird_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    cur_obj_scale(1.4)
    o.oAnimations = gObjectAnimations.klepto_seg5_anims_05008CFC
    obj_init_animation(o, KLEPTO_DIVE)
    o.oAction = 0
end

local function bird_loop(o)
    local m = gMarioStates[0]
    if o.oAction == 0 then
        -- swoop toward Mario
        local tx, ty, tz = m.pos.x, m.pos.y + 140, m.pos.z
        local dx, dy, dz = tx - o.oPosX, ty - o.oPosY, tz - o.oPosZ
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        local speed = 38
        o.oPosX = o.oPosX + dx / dist * speed
        o.oPosY = o.oPosY + dy / dist * speed
        o.oPosZ = o.oPosZ + dz / dist * speed
        o.oFaceAngleYaw = atan2s(dz, dx)
        o.oMoveAngleYaw = o.oFaceAngleYaw
        if o.oTimer % 25 == 0 then cur_obj_play_sound_2(SOUND_OBJ_KLEPTO1) end
        if dist < 130 and m.health > 0x100 and not swimming(m) then
            o.oAction = 1
            -- how long it carries you: random, about 1.3 to 5 seconds
            o.oBehParams2ndByte = math.random(40, 150)
            obj_init_animation(o, KLEPTO_FLAP)
            set_mario_action(m, ACT_FREEFALL, 0)
            cur_obj_play_sound_2(SOUND_OBJ_KLEPTO2)
        elseif o.oTimer > 330 then
            o.oAction = 2   -- missed: give up
            obj_init_animation(o, KLEPTO_FLAP)
        end
    elseif o.oAction == 1 then
        -- carry Mario up and away for a random time (set when it grabbed you)
        o.oPosY = o.oPosY + 13
        o.oPosX = o.oPosX + sins(o.oMoveAngleYaw) * 9
        o.oPosZ = o.oPosZ + coss(o.oMoveAngleYaw) * 9
        m.pos.x, m.pos.y, m.pos.z = o.oPosX, o.oPosY - 140, o.oPosZ
        m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
        m.forwardVel = 0
        m.freeze = 3
        if o.oTimer > o.oBehParams2ndByte then
            o.oAction = 2   -- drop!
            m.freeze = 0
        end
    else
        -- fly off and vanish
        o.oPosY = o.oPosY + 20
        o.oPosX = o.oPosX + sins(o.oMoveAngleYaw) * 30
        o.oPosZ = o.oPosZ + coss(o.oMoveAngleYaw) * 30
        if o.oTimer > 75 then obj_mark_for_deletion(o) end
    end
end

local bhvChaosBird = hook_behavior(nil, OBJ_LIST_DEFAULT, true, bird_init, bird_loop)

C.register({
    id = "bird_attack", name = "Bird Attack", kind = "hinder", duration = 14, target = "random", group = "bird",
    weight = 0.7,
    onStart = function(entry)
        if entry.target ~= my_global() then return end
        local m = gMarioStates[0]
        local a = math.random(0, 65535)
        spawn_non_sync_object(bhvChaosBird, E_MODEL_KLEPTO,
            m.pos.x + sins(a) * 1600, m.pos.y + 900, m.pos.z + coss(a) * 1600, nil)
        djui_chat_message_create("\\#ffd060\\SKREEEE! Something is coming for you...")
    end,
    onEnd = function(entry)
        -- never leave a bird behind
        local o = obj_get_first_with_behavior_id(bhvChaosBird)
        while o ~= nil do
            obj_mark_for_deletion(o)
            o = obj_get_next_with_same_behavior_id(o)
        end
        gMarioStates[0].freeze = 0
    end,
})

-- BOSS: Mega Goomba. A rare hinder. Spawned by the host as a synced object so everyone fights the same one.
-- Stomp it 3 times to win (works anywhere, no special arena, no star). It despawns when the effect ends.
-- oHealth: 3..1 alive, 0 defeated (coins), -1 despawned (time ran out).
local bossHitCooldown = 0
local BOSS_SCALE = 4

local function boss_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    cur_obj_scale(BOSS_SCALE)
    o.oHealth = 3
    o.oAction = 0
    o.oGravity = 2.5
    o.oBounciness = 0
    o.oDragStrength = 0
    o.oFriction = 0.8
    o.oBuoyancy = 1.5
    o.oWallHitboxRadius = 160
    network_init_object(o, true, { "oHealth", "oAction", "oBehParams2ndByte" })
end

local function boss_finish(o, defeated)
    spawn_non_sync_object(id_bhvExplosion, E_MODEL_EXPLOSION, o.oPosX, o.oPosY + 100, o.oPosZ, function(e) obj_scale(e, 3) end)
    if defeated then
        for _ = 1, 10 do
            spawn_non_sync_object(id_bhvMovingYellowCoin, E_MODEL_YELLOW_COIN, o.oPosX, o.oPosY + 200, o.oPosZ, nil)
        end
        djui_chat_message_create("\\#80ff80\\The Mega Goomba is defeated!")
        play_sound(SOUND_GENERAL_BIG_POUND, gGlobalSoundSource)
    else
        djui_chat_message_create("\\#ffb0ff\\The Mega Goomba wandered off...")
    end
    obj_mark_for_deletion(o)
end

-- the boss is driven by the player who spawned it (its level's leader), not by the host
local function boss_owner_is_me(o)
    local owner = o.oBehParams2ndByte - 1
    if owner < 0 then return network_is_server() end
    if owner == gNetworkPlayers[0].globalIndex then return true end
    -- if the owner has left, the area leader takes over
    local li = network_local_index_from_global(owner)
    if li == nil or li < 0 or not gNetworkPlayers[li].connected then return i_am_area_leader() end
    return false
end

local function boss_loop(o)
    if o.oHealth <= 0 then
        boss_finish(o, o.oHealth == 0)
        return
    end
    local scaleY = BOSS_SCALE
    if boss_owner_is_me(o) then
        local target = nearest_mario_state_to_object(o)
        if o.oAction == 1 then
            -- squashed for a moment after a stomp
            o.oForwardVel = 0
            if o.oTimer > 35 then o.oAction = 0 end
        elseif target ~= nil then
            o.oMoveAngleYaw = approach_s16_symmetric(o.oMoveAngleYaw, obj_angle_to_object(o, target.marioObj), 0x300)
            o.oFaceAngleYaw = o.oMoveAngleYaw
            o.oForwardVel = 13 + (3 - o.oHealth) * 4   -- angrier as it gets hurt
            if o.oTimer % 90 == 0 then
                o.oVelY = 45
                cur_obj_play_sound_2(SOUND_OBJ_GOOMBA_ALERT)
            end
        end
        object_step_without_floor_orient()
    end
    if o.oAction == 1 then scaleY = BOSS_SCALE * 0.55 end
    obj_scale_xyz(o, BOSS_SCALE, scaleY, BOSS_SCALE)

    -- every player's game checks its own Mario against the boss
    local m = gMarioStates[0]
    if bossHitCooldown > 0 then bossHitCooldown = bossHitCooldown - 1 end
    local dx, dz = m.pos.x - o.oPosX, m.pos.z - o.oPosZ
    local dist = math.sqrt(dx * dx + dz * dz)
    local dy = m.pos.y - o.oPosY
    if dist < 250 and dy > 130 and dy < 420 and m.vel.y < 0 and in_air(m) then
        -- stomp! bounce off and tell the boss's owner
        set_mario_action(m, ACT_JUMP, 0)
        m.vel.y = 60
        play_sound(SOUND_GENERAL_BOING1, gGlobalSoundSource)
        if bossHitCooldown == 0 and o.oAction == 0 then
            bossHitCooldown = 30
            if boss_owner_is_me(o) then
                C.boss_hit(o)
            else
                network_send(true, { chaos = "boss_hit", owner = o.oBehParams2ndByte - 1 })
            end
        end
    elseif dist < 210 and dy > -60 and dy <= 130 and o.oAction == 0 and m.invincTimer <= 0 and m.health > 0x100 then
        o.oDamageOrCoinValue = 2
        take_damage_and_knock_back(m, o)
    end
end

local bhvChaosBoss = hook_behavior(nil, OBJ_LIST_GENACTOR, true, boss_init, boss_loop, "bhvChaosMegaGoomba")

function C.boss_hit(o)
    o = o or obj_get_first_with_behavior_id(bhvChaosBoss)
    if o == nil or o.oAction ~= 0 or o.oHealth <= 0 then return end
    o.oHealth = o.oHealth - 1
    o.oAction = 1
    network_send_object(o, true)
    if o.oHealth > 0 then
        local msg = "\\#ffd060\\Mega Goomba hit! " .. o.oHealth .. " to go!"
        network_send(true, { chaos = "msg", text = msg })
        djui_chat_message_create(msg)
    end
end

hook_event(HOOK_ON_PACKET_RECEIVE, function(data)
    if data.chaos == "boss_hit" then
        -- only the boss's owner applies the hit (to the boss in its own level)
        local o = obj_get_first_with_behavior_id(bhvChaosBoss)
        -- the hit must be for this exact boss (bosses in other levels have other owners)
        if o ~= nil and boss_owner_is_me(o) and (data.owner == nil or data.owner == o.oBehParams2ndByte - 1) then
            C.boss_hit(o)
        end
    elseif data.chaos == "msg" and data.text ~= nil then
        djui_chat_message_create(data.text)
    end
end)

C.register({
    id = "boss_goomba", name = "BOSS: Mega Goomba", kind = "hinder", scope = "world", group = "boss",
    duration = 120, durationRange = { 60, 180 },   -- stays 1-3 minutes
    weight = 0.25,   -- rare
    label = function()
        local o = obj_get_first_with_behavior_id(bhvChaosBoss)
        if o == nil then return "defeated!" end
        return "stomp it! hits left: " .. math.max(o.oHealth, 0)
    end,
    onStart = function(entry)
        -- one boss per occupied level: each level's leader spawns it next to themselves
        local x, floor, z = C.boss_spawn_point(700)
        if x == nil then return end
        local owner = gNetworkPlayers[0].globalIndex + 1
        spawn_sync_object(bhvChaosBoss, E_MODEL_GOOMBA, x, floor + 400, z, function(o) o.oBehParams2ndByte = owner end)
    end,
    onEnd = function(entry)
        local o = obj_get_first_with_behavior_id(bhvChaosBoss)
        while o ~= nil do
            if o.oHealth > 0 and boss_owner_is_me(o) then
                o.oHealth = -1
                network_send_object(o, true)
            end
            o = obj_get_next_with_same_behavior_id(o)
        end
    end,
})

-- BOSS (classic): a real game boss that can be beaten anywhere: Wiggler (jump on its head), King Whomp
-- (ground pound its back) or Big Boo (hit it from behind). Rare. They normally drop a star built for their own
-- level, so while one is out (and for 10 s after) any spawned star is deleted on every player's game.
-- Big Boo uses the balcony version, which wakes up whenever a player is within 5000 units.
local CLASSIC_BOSSES = {
    { id = "boss_wiggler", name = "Wiggler", bhv = id_bhvWigglerHead, model = E_MODEL_WIGGLER_HEAD, lift = 0 },
    { id = "boss_king_whomp", name = "King Whomp", bhv = id_bhvWhompKingBoss, model = E_MODEL_WHOMP, lift = 0,
      setup = function(o) o.oBehParams2ndByte = 1 end },
    { id = "boss_big_boo", name = "Big Boo", bhv = id_bhvBalconyBigBoo, model = E_MODEL_BOO, lift = 150,
      setup = function(o) o.oBigBooNumMinionBoosKilled = 10 end },
}
local STAR_BEHAVIORS = { id_bhvStarSpawnCoordinates, id_bhvSpawnedStar, id_bhvSpawnedStarNoLevelExit }
local suppressStarsUntil = -1


-- remove any star that appears while a classic boss is out
hook_event(HOOK_UPDATE, function()
    if suppressStarsUntil < 0 then return end
    if suppressStarsUntil ~= math.huge and get_global_timer() > suppressStarsUntil then
        suppressStarsUntil = -1
        return
    end
    for _, b in ipairs(STAR_BEHAVIORS) do
        local o = obj_get_first_with_behavior_id(b)
        while o ~= nil do
            local nxt = obj_get_next_with_same_behavior_id(o)
            obj_mark_for_deletion(o)
            o = nxt
        end
    end
end)

local function remove_boss(b)
    for _, bhv in ipairs({ b.bhv, id_bhvWigglerBody }) do
        local o = obj_get_first_with_behavior_id(bhv)
        while o ~= nil do
            local nxt = obj_get_next_with_same_behavior_id(o)
            -- Wiggler's body and Big Boo ignore deletion (tested), so also make every part invisible,
            -- harmless and move it far below the level, where it can't bother anyone
            obj_set_model_extended(o, E_MODEL_NONE)
            o.oIntangibleTimer = -1
            o.oPosY = -20000
            o.oHomeY = -20000
            obj_mark_for_deletion(o)
            o = nxt
        end
    end
end

-- one effect per boss, so each can be tested with /chaos now <id> or switched off on its own
for _, b in ipairs(CLASSIC_BOSSES) do
    C.register({
        id = b.id, name = "BOSS: " .. b.name, kind = "hinder", scope = "world", group = "boss",
        duration = 120, durationRange = { 60, 180 },   -- stays 1-3 minutes
        weight = 0.08,   -- rare
        label = function(entry)
            if obj_get_first_with_behavior_id(b.bhv) == nil then return b.name .. " is gone!" end
            return "beat it! (no star)"
        end,
        onStart = function(entry)
            suppressStarsUntil = math.huge
            djui_chat_message_create("\\#ff4040\\A wild " .. b.name .. " appears!")
            -- one boss per occupied level: each level's leader spawns it next to themselves
            local x, floor, z = C.boss_spawn_point(800)
            if x == nil then return end
            spawn_sync_object(b.bhv, b.model, x, floor + b.lift, z, b.setup)
        end,
        onEnd = function(entry)
            -- keep removing stars for 10 more seconds, then clear the boss away if it's still around
            suppressStarsUntil = get_global_timer() + 300
            remove_boss(b)
        end,
    })
end

-- Built-in Chaos effects. Each effect runs on every client from the same synced data.
--   onStart(entry)      once, when the effect begins (entry.id, entry.target, entry.seed, entry.frames)
--   onMario(m, entry)   every frame for each Mario the effect applies to (m.playerIndex == 0 is the local player)
--   onEnd(entry)        once, when it ends or is cleared
-- Physics changes only touch the local player (their game owns their movement). Visual changes may touch anyone.

local C = Chaos

local function is_local(m) return m.playerIndex == 0 end
local function in_air(m) return (m.action & ACT_FLAG_AIR) ~= 0 end
local function swimming(m) return (m.action & ACT_FLAG_SWIMMING) ~= 0 end

-- interaction types that mark an object as an enemy (used by Gravity Well)
local ENEMY_INTERACT = INTERACT_BOUNCE_TOP | INTERACT_BOUNCE_TOP2 | INTERACT_HIT_FROM_BELOW | INTERACT_KOOPA
    | INTERACT_DAMAGE | INTERACT_SHOCK | INTERACT_FLAME | INTERACT_SNUFIT_BULLET

-- A standing Mario skips the physics step completely (the game only steps him on windy or sandy floors), so a
-- velocity push never reaches him. For standing players we run one collision-safe ground step ourselves.
-- entry.manualStep tells the effect's own onBeforePhys not to push a second time during that step.
function C.push_standing(m, entry, vx, vz)
    if (m.action & ACT_FLAG_STATIONARY) == 0 or in_air(m) or swimming(m) then return end
    if vx * vx + vz * vz < 0.01 then return end
    entry.manualStep = true
    m.vel.x, m.vel.z = vx, vz
    local result = perform_ground_step(m)
    entry.manualStep = false
    m.vel.x, m.vel.z = 0, 0
    if result == GROUND_STEP_LEFT_GROUND then set_mario_action(m, ACT_FREEFALL, 0) end
end

-- Where will this player be when something dropped now lands? (falls start at -v0 per frame, gravity 1.8)
-- About half of all drops are aimed there, so standing still is no longer the safe choice.
function C.aim_drop(m, spread, height, v0)
    if math.random() < 0.5 then
        local t = (-v0 + math.sqrt(v0 * v0 + 3.6 * height)) / 1.8
        local lead = in_air(m) and 0.6 or 0.85
        return m.pos.x + m.vel.x * t * lead + (math.random() - 0.5) * 240,
               m.pos.z + m.vel.z * t * lead + (math.random() - 0.5) * 240, true
    end
    return m.pos.x + (math.random() - 0.5) * 2 * spread, m.pos.z + (math.random() - 0.5) * 2 * spread, false
end

-- An impact: the game's explosion for looks and sound, plus our own damage check sized to match the blast
-- (the explosion's built-in damage area is always 150 units however big it looks). Only the local Mario is
-- checked, because every client spawns and judges its own impacts.
function C.blast(o, x, y, z, scale, radius, damage)
    local e = spawn_non_sync_object(id_bhvExplosion, E_MODEL_EXPLOSION, x, y + 20, z, function(e) obj_scale(e, scale) end)
    o = o or e   -- with no falling object (e.g. Hot Potato), the explosion itself is the damage source
    if o == nil then return end
    local m = gMarioStates[0]
    local dx, dy, dz = m.pos.x - x, m.pos.y - y, m.pos.z - z
    if dx * dx + dz * dz < radius * radius and dy > -100 and dy < radius
        and m.invincTimer <= 0 and m.health > 0x100 and (m.flags & MARIO_METAL_CAP) == 0 then
        o.oDamageOrCoinValue = damage
        o.oPosX, o.oPosY, o.oPosZ = x, y, z   -- knockback points away from the impact
        take_damage_and_knock_back(m, o)
    end
end

-- Landing warnings: a red ring on the ground, the size of the blast, until the impact lands.
-- Drawn on the HUD from world positions (djui_hud_world_pos_to_screen_pos), so it lies flat on the floor in
-- perspective and always shows, whatever models the level has loaded.
C.warnings = {}

function C.add_warning(x, y, z, radius, frames)
    table.insert(C.warnings, { x = x, y = y, z = z, r = radius, born = get_global_timer(), life = frames })
end

-- frames for something dropped from `height` with starting speed v0 to land (gravity 1.8 per frame)
function C.fall_frames(height, v0)
    return math.floor((-v0 + math.sqrt(v0 * v0 + 3.6 * height)) / 1.8)
end

local RING_POINTS = 20
local ringPos, ringOut = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }

local function draw_warnings()
    if #C.warnings == 0 then return end
    local now = get_global_timer()
    djui_hud_set_resolution(RESOLUTION_N64)
    for i = #C.warnings, 1, -1 do
        local w = C.warnings[i]
        local age = now - w.born
        if age > w.life then
            table.remove(C.warnings, i)
        else
            -- pulse gets faster and the ring gets more solid as impact gets closer
            local urgency = age / math.max(w.life, 1)
            local pulse = 0.5 + 0.5 * math.sin(age * (0.3 + urgency * 0.9))
            djui_hud_set_color(255, 40 + 60 * (1 - urgency), 20, 110 + 120 * urgency * pulse)
            for k = 0, RING_POINTS - 1 do
                local a = k / RING_POINTS * math.pi * 2
                ringPos.x = w.x + math.cos(a) * w.r
                ringPos.y = w.y + 8
                ringPos.z = w.z + math.sin(a) * w.r
                if djui_hud_world_pos_to_screen_pos(ringPos, ringOut) then
                    djui_hud_render_rect(ringOut.x - 1.5, ringOut.y - 1.5, 3, 3)
                end
            end
            -- centre mark
            ringPos.x, ringPos.y, ringPos.z = w.x, w.y + 8, w.z
            if djui_hud_world_pos_to_screen_pos(ringPos, ringOut) then
                djui_hud_render_rect(ringOut.x - 2.5, ringOut.y - 0.5, 5, 1)
                djui_hud_render_rect(ringOut.x - 0.5, ringOut.y - 2.5, 1, 5)
            end
        end
    end
end
hook_event(HOOK_ON_HUD_RENDER, draw_warnings)

local function set_scale(m, s)
    vec3f_set(m.marioObj.header.gfx.scale, s, s, s)
end

------------------------------------------------------------------------------------------------ HELP

C.register({
    id = "speed_boost", name = "Speed Boost", kind = "help", duration = 20,
    group = "speed",
    -- runs right before the physics step, after the action has set this frame's speed
    onBeforePhys = function(m)
        if is_local(m) and not in_air(m) and not swimming(m) then
            m.vel.x = m.vel.x * 1.45
            m.vel.z = m.vel.z * 1.45
        end
    end,
})

C.register({
    id = "moon_gravity", name = "Moon Gravity", kind = "help", scope = "world", duration = 20,
    group = "gravity",
    onMario = function(m)
        if is_local(m) and in_air(m) and not swimming(m) and m.vel.y < 0 then
            m.vel.y = m.vel.y + 1.4
        end
    end,
})

C.register({
    id = "super_jump", name = "Super Jump", kind = "help", duration = 20,
    onStart = function(entry) entry.lastAction = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        local a = m.action
        if a ~= entry.lastAction then
            if a == ACT_JUMP or a == ACT_DOUBLE_JUMP or a == ACT_TRIPLE_JUMP or a == ACT_SIDE_FLIP
                or a == ACT_BACKFLIP or a == ACT_LONG_JUMP then
                m.vel.y = m.vel.y * 1.45
            end
            entry.lastAction = a
        end
    end,
})

C.register({
    id = "tiny_mario", name = "Tiny Mario", kind = "help", duration = 20,
    group = "size",
    onMario = function(m) set_scale(m, 0.5) end,
    onEnd = function(entry)
        for i = 0, MAX_PLAYERS - 1 do set_scale(gMarioStates[i], 1) end
    end,
})

C.register({
    id = "heal", name = "Full Heal", kind = "help", duration = 0, target = "random",
    onMario = function(m)
        if is_local(m) then m.health = 0x880 end
    end,
})

C.register({
    id = "wing_cap", name = "Wing Cap", kind = "help", duration = 0, target = "random",
    onMario = function(m)
        if is_local(m) then
            m.flags = m.flags | MARIO_WING_CAP | MARIO_CAP_ON_HEAD
            m.capTimer = 20 * 30
        end
    end,
})

C.register({
    id = "metal_cap", name = "Metal Cap", kind = "help", duration = 0, target = "random",
    onMario = function(m)
        if is_local(m) then
            m.flags = m.flags | MARIO_METAL_CAP | MARIO_CAP_ON_HEAD
            m.capTimer = 20 * 30
        end
    end,
})

---------------------------------------------------------------------------------------------- HINDER

C.register({
    id = "heavy_gravity", name = "Heavy Gravity", kind = "hinder", scope = "world", duration = 20,
    group = "gravity",
    onMario = function(m)
        if is_local(m) and in_air(m) and not swimming(m) then
            m.vel.y = m.vel.y - 2.2
        end
    end,
})

C.register({
    id = "slow_walk", name = "Slow Motion Legs", kind = "hinder", duration = 15,
    group = "speed",
    onBeforePhys = function(m)
        if is_local(m) and not in_air(m) and not swimming(m) then
            m.vel.x = m.vel.x * 0.45
            m.vel.z = m.vel.z * 0.45
        end
    end,
})

C.register({
    id = "giant_mario", name = "Giant Mario", kind = "hinder", duration = 20,
    group = "size",
    onMario = function(m) set_scale(m, 2.0) end,
    onEnd = function(entry)
        for i = 0, MAX_PLAYERS - 1 do set_scale(gMarioStates[i], 1) end
    end,
})

C.register({
    id = "freeze", name = "Brain Freeze", kind = "hinder", duration = 3, target = "random",
    onMario = function(m)
        if is_local(m) then
            m.freeze = 3
            m.forwardVel = 0
            m.vel.x = 0
            m.vel.z = 0
        end
    end,
})

C.register({
    id = "knockback", name = "Surprise Shove", kind = "hinder", duration = 0, target = "random",
    onMario = function(m)
        if is_local(m) then
            set_mario_action(m, ACT_THROWN_FORWARD, 0)
            m.forwardVel = 32
            m.vel.y = 30
        end
    end,
})

------------------------------------------------------------------------------------------ WORLD EVENTS
-- These run identically on every client from the synced seed, so they need no spawned objects.

C.register({
    id = "earthquake", name = "Earthquake", kind = "hinder", scope = "world", duration = 12,
    onStart = function(entry)
        entry.nextTrip = 45 + (entry.seed % 30)
        entry.tick = 0
    end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        -- constant rumble every frame, harder shakes right before a trip
        set_environmental_camera_shake(SHAKE_ENV_FALLING_BITS_PLAT)
        if entry.tick >= entry.nextTrip then
            entry.nextTrip = entry.tick + 75 + ((entry.seed + entry.tick) % 60)
            -- only trip a player who is standing on the ground
            if not in_air(m) and not swimming(m) and m.health > 0x100 then
                set_mario_action(m, ACT_FORWARD_GROUND_KB, 0)
                m.forwardVel = 12
            end
        end
    end,
})

C.register({
    id = "blizzard", name = "Blizzard", kind = "hinder", scope = "world", duration = 20,
    group = "wind", envfx = ENVFX_SNOW_BLIZZARD,   -- the game's own blizzard weather
    -- A howling wind from one direction (same for everyone, from the shared seed), like Snowman's Land:
    -- walking into it slows you a lot, walking with it speeds you up, and it shoves you along. It gusts in waves.
    -- Stand still for ~4 seconds and you freeze solid (icy blue, can't move) for 3 seconds, then thaw.
    onStart = function(entry)
        entry.tick = 0
        entry.still = 0
        entry.frozenUntil = 0
        entry.windAngle = entry.seed % 65536
    end,
    onEnd = function(entry)
        if entry.iced then network_player_reset_override_palette(gNetworkPlayers[0]) end
    end,
    label = function(entry)
        if entry.frozenUntil > entry.tick then return "frozen solid!" end
        if entry.still > 60 then return "keep moving!" end
        local m = gMarioStates[0]
        local rel = (entry.windAngle - m.faceAngle.y) & 0xFFFF
        if rel < 0x2000 or rel > 0xE000 then return "wind at your back" end
        if rel > 0x6000 and rel < 0xA000 then return "headwind!" end
        return "crosswind"
    end,
    onBeforePhys = function(m, entry)
        if not is_local(m) or swimming(m) then return end
        if entry.manualStep or entry.frozenUntil > entry.tick then return end
        local gust = 0.65 + 0.35 * math.sin(entry.tick / 22)
        local wx, wz = sins(entry.windAngle), coss(entry.windAngle)
        local along = m.vel.x * wx + m.vel.z * wz
        local scale
        if along < 0 then scale = 1 - 0.75 * gust else scale = 1 + 0.3 * gust end
        local delta = along * (scale - 1)
        m.vel.x = m.vel.x + wx * delta
        m.vel.z = m.vel.z + wz * delta
        -- a real shove: about 7 units a frame at full gust, enough to push a standing Mario along
        local push = (in_air(m) and 5 or 7.5) * gust
        m.vel.x = m.vel.x + wx * push
        m.vel.z = m.vel.z + wz * push
    end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        local np = gNetworkPlayers[0]
        local gust = 0.65 + 0.35 * math.sin(entry.tick / 22)
        local wx, wz = sins(entry.windAngle), coss(entry.windAngle)
        if entry.frozenUntil > entry.tick then
            -- frozen: no control, you look like ice, and the wind slides you easily, keeping your momentum
            m.freeze = 3
            m.forwardVel = 0
            entry.ivx = (entry.ivx or 0) * 0.98 + wx * 2.2 * gust
            entry.ivz = (entry.ivz or 0) * 0.98 + wz * 2.2 * gust
            local speed = math.sqrt(entry.ivx * entry.ivx + entry.ivz * entry.ivz)
            if speed > 45 then
                entry.ivx = entry.ivx / speed * 45
                entry.ivz = entry.ivz / speed * 45
            end
            C.push_standing(m, entry, entry.ivx, entry.ivz)
            return
        end
        if entry.frozenUntil > 0 then
            -- just thawed
            entry.frozenUntil = 0
            entry.still = -90   -- a few seconds of grace before the cold can catch you again
            entry.iced = false
            network_player_reset_override_palette(np)
            djui_chat_message_create("\\#80d0ff\\You thawed out! Keep moving!")
        end
        if in_air(m) or swimming(m) or math.abs(m.forwardVel) >= 4 then
            entry.still = (entry.still < 0) and entry.still + 1 or 0
        else
            entry.still = entry.still + 1
            if entry.still == 60 then
                djui_chat_message_create("\\#80d0ff\\You're getting cold... keep moving!")
            elseif entry.still >= 120 and m.health > 0x100 then
                entry.frozenUntil = entry.tick + 90
                entry.ivx, entry.ivz = 0, 0
                local ice = { r = 170, g = 225, b = 255 }
                for part = 0, 7 do network_player_set_override_palette_color(np, part, ice) end
                entry.iced = true
                djui_chat_message_create("\\#80d0ff\\You froze solid!")
            end
        end
        -- standing players get shoved too
        C.push_standing(m, entry, wx * 7.5 * gust, wz * 7.5 * gust)
    end,
})

C.register({
    id = "gravity_well", name = "Gravity Well", kind = "hinder", scope = "world", duration = 12,
    group = "pull",
    -- Everyone is dragged toward one player chosen from the shared seed. That player (or anyone playing alone)
    -- is tugged back toward the spot they were standing when it began.
    onStart = function(entry) entry.anchor = nil end,
    onBeforePhys = function(m, entry)
        if not is_local(m) or swimming(m) or entry.manualStep then return end
        local vx, vz = C.gravity_well_pull(m, entry)
        m.vel.x = m.vel.x + vx
        m.vel.z = m.vel.z + vz
    end,
    pullVector = function(m, entry)
        local ids = {}
        for i = 0, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected then table.insert(ids, i) end
        end
        if #ids == 0 then return end
        table.sort(ids, function(a, b) return gNetworkPlayers[a].globalIndex < gNetworkPlayers[b].globalIndex end)
        local focus = ids[(entry.seed % #ids) + 1]
        local fx, fz
        if focus ~= 0 then
            fx, fz = gMarioStates[focus].pos.x, gMarioStates[focus].pos.z
        else
            if entry.anchor == nil then entry.anchor = { x = m.pos.x, z = m.pos.z } end
            fx, fz = entry.anchor.x, entry.anchor.z
        end
        local dx, dz = fx - m.pos.x, fz - m.pos.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= 150 then return 0, 0 end
        -- added to this frame's movement, so walls and floors still stop you
        local pull = in_air(m) and 9 or 14
        return dx / dist * pull, dz / dist * pull
    end,
    -- enemies within range slide toward you (each player's game pulls the enemies near them)
    onMario = function(m, entry)
        if not is_local(m) then return end
        -- a standing player is dragged too
        local vx, vz = C.gravity_well_pull(m, entry)
        C.push_standing(m, entry, vx, vz)
        for _, list in ipairs({ OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR }) do
            local o = obj_get_first(list)
            while o ~= nil do
                if (o.oInteractType & ENEMY_INTERACT) ~= 0 then
                    local dx, dz = m.pos.x - o.oPosX, m.pos.z - o.oPosZ
                    local dist = math.sqrt(dx * dx + dz * dz)
                    if dist > 180 and dist < 2500 then
                        local pull = 8
                        o.oPosX = o.oPosX + dx / dist * pull
                        o.oPosZ = o.oPosZ + dz / dist * pull
                    end
                end
                o = obj_get_next(o)
            end
        end
    end,
})


-- Falling fire: a custom object (flame model, because rock models only exist inside certain levels).
-- Each client spawns its own around its own Mario, so nothing is synced and nothing can desync.
-- oBehParams2ndByte = 1 makes a small fireball (Fire Storm); 0 is a big meteor (Meteor Shower).
local function flame_trail_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    cur_obj_scale(2.2)
end

local function flame_trail_loop(o)
    if o.oTimer > 10 then
        obj_mark_for_deletion(o)
        return
    end
    cur_obj_scale(2.2 * (1 - o.oTimer / 11))
end

local bhvChaosFlameTrail = hook_behavior(nil, OBJ_LIST_DEFAULT, true, flame_trail_init, flame_trail_loop)

local function faller_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    cur_obj_scale((o.oBehParams2ndByte == 1) and 2.0 or 5.0)
end

local function faller_loop(o)
    local small = (o.oBehParams2ndByte == 1)
    o.oVelY = o.oVelY - 1.8
    obj_move_xyz_using_fvel_and_yaw(o)
    if o.oTimer % (small and 4 or 2) == 0 then
        spawn_non_sync_object(bhvChaosFlameTrail, E_MODEL_RED_FLAME, o.oPosX, o.oPosY, o.oPosZ, nil)
    end
    local floor = find_floor_height(o.oPosX, o.oPosY + 120, o.oPosZ)
    if o.oPosY <= floor + 60 or o.oTimer > 240 then
        if floor > -10000 then
            if small then
                C.blast(o, o.oPosX, floor, o.oPosZ, 1.3, 135, 1)   -- Fire Storm: small blast, 1 damage (was 190, nerfed)
            else
                C.blast(o, o.oPosX, floor, o.oPosZ, 3.0, 330, 2)   -- Meteor: big blast, 2 damage
            end
        end
        obj_mark_for_deletion(o)
    end
end

local bhvChaosFaller = hook_behavior(nil, OBJ_LIST_DEFAULT, true, faller_init, faller_loop)


local function drop_fire(m, spread, height, small)
    local v0 = small and 26 or 22
    local x, z, aimed = C.aim_drop(m, spread, height, v0)
    local ground = find_floor_height(x, m.pos.y + 400, z)
    if ground < -10000 then return end   -- over a pit: skip this one
    -- warning ring the size of the blast, for as long as it takes to land
    C.add_warning(x, ground, z, small and 135 or 330, C.fall_frames(height, v0))
    spawn_non_sync_object(bhvChaosFaller, E_MODEL_RED_FLAME_SHADOW, x, ground + height, z, function(o)
        o.oBehParams2ndByte = small and 1 or 0
        o.oVelY = -v0
        o.oForwardVel = 0   -- falls straight down onto its warning ring
        o.oMoveAngleYaw = math.random(0, 65535)
    end)
end

C.register({
    id = "fire_storm", name = "Fire Storm", kind = "hinder", scope = "world", duration = 15,
    group = "sky", envfx = ENVFX_LAVA_BUBBLES,
    onStart = function(entry) entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if entry.tick % 12 == 0 then drop_fire(m, 1100, 1300, true) end
    end,
})

C.register({
    id = "meteor_shower", name = "Meteor Shower", kind = "hinder", scope = "world", duration = 12,
    group = "sky",
    onStart = function(entry) entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if entry.tick % 40 == 0 then drop_fire(m, 700, 2000, false) end
    end,
})

-- Gravity Well pull, used by both its physics hook and its standing-player step
function C.gravity_well_pull(m, entry) return C.effects.gravity_well.pullVector(m, entry) end

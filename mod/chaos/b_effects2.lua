-- Chaos effects, batch 2: more Help, more Hinder, controls (Reverse/Spaghetti/Drunk/Dizzy) and world/weather.
-- Same rules as b_effects.lua: physics only touches the local player, visuals may touch anyone.
-- Optional extra hooks: label(entry) -> short HUD text, hud(entry, screenW, screenH) -> draw on screen every frame,
-- onBeforeMario(m, entry) -> runs before Mario reads his controls (needed for anything that changes the stick).

local C = Chaos

local function is_local(m) return m.playerIndex == 0 end
local function in_air(m) return (m.action & ACT_FLAG_AIR) ~= 0 end
local function swimming(m) return (m.action & ACT_FLAG_SWIMMING) ~= 0 end
local function grounded(m) return not in_air(m) and not swimming(m) end

local function is_jump(a)
    return a == ACT_JUMP or a == ACT_DOUBLE_JUMP or a == ACT_TRIPLE_JUMP or a == ACT_SIDE_FLIP
        or a == ACT_BACKFLIP or a == ACT_LONG_JUMP
end

-- true on the single frame a jump action begins (needs entry.lastAction)
local function jump_started(m, entry)
    local a = m.action
    local started = (a ~= entry.lastAction) and is_jump(a)
    entry.lastAction = a
    return started
end

-- true on the single frame the player lands (needs entry.wasAir)
local function just_landed(m, entry)
    local air = in_air(m)
    local landed = entry.wasAir and not air and grounded(m)
    entry.wasAir = air
    return landed
end

-- rotate the control stick by `angle` radians (used by sway effects)
local function rotate_stick(m, angle)
    local sx, sy = m.controller.stickX, m.controller.stickY
    local c, s = math.cos(angle), math.sin(angle)
    m.controller.stickX = sx * c - sy * s
    m.controller.stickY = sx * s + sy * c
end

-- keep part of last frame's ground velocity so Mario slides (k small = slippery)
local function inertia(m, entry, k)
    if not is_local(m) then return end
    if grounded(m) and entry.pvx ~= nil then
        m.vel.x = entry.pvx + (m.vel.x - entry.pvx) * k
        m.vel.z = entry.pvz + (m.vel.z - entry.pvz) * k
    end
    entry.pvx, entry.pvz = m.vel.x, m.vel.z
end

local function tick_up(m, entry)
    if is_local(m) then entry.tick = (entry.tick or 0) + 1 end
    return entry.tick or 0
end

------------------------------------------------------------------------------------------------ HELP

C.register({
    id = "coin_shower", name = "Coin Shower", kind = "help", scope = "world", duration = 15,
    group = "coins",
    onStart = function(entry) entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if entry.tick % 6 == 0 then
            local x = m.pos.x + (math.random() - 0.5) * 1400
            local z = m.pos.z + (math.random() - 0.5) * 1400
            spawn_non_sync_object(id_bhvMovingYellowCoin, E_MODEL_YELLOW_COIN, x, m.pos.y + 900, z, nil)
        end
    end,
})

C.register({
    id = "bounce_house", name = "Bounce House", kind = "help", duration = 20,
    group = "landing",
    onStart = function(entry) entry.wasAir = false end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if just_landed(m, entry) and m.health > 0x100 then
            set_mario_action(m, ACT_JUMP, 0)
            m.vel.y = 62
        end
    end,
})

C.register({
    id = "featherweight", name = "Featherweight", kind = "help", duration = 20,
    group = "gravity",
    onMario = function(m)
        if is_local(m) and in_air(m) and not swimming(m) then
            if m.vel.y < -8 then m.vel.y = -8 end
            if m.vel.y > 0 then m.vel.y = m.vel.y + 0.5 end
        end
    end,
})

C.register({
    id = "second_wind", name = "Second Wind", kind = "help", duration = 25,
    label = function() return "press A in the air" end,
    onStart = function(entry) entry.used = false; entry.airFrames = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if not in_air(m) then
            entry.used = false
            entry.airFrames = 0
        else
            entry.airFrames = entry.airFrames + 1
            if not entry.used and entry.airFrames > 8 and not swimming(m)
                and (m.controller.buttonPressed & A_BUTTON) ~= 0
                and m.action ~= ACT_FLYING and m.action ~= ACT_GROUND_POUND then
                entry.used = true
                set_mario_action(m, ACT_DOUBLE_JUMP, 0)
                m.vel.y = 50
            end
        end
    end,
})

C.register({
    id = "magnet", name = "Coin Magnet", kind = "help", duration = 20,
    group = "coins",
    onMario = function(m)
        if not is_local(m) then return end
        for _, bhv in ipairs({ id_bhvYellowCoin, id_bhvMovingYellowCoin }) do
            local coin = obj_get_first_with_behavior_id(bhv)
            while coin ~= nil do
                local dx, dy, dz = m.pos.x - coin.oPosX, m.pos.y + 60 - coin.oPosY, m.pos.z - coin.oPosZ
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist < 2200 and dist > 40 then
                    local pull = 38
                    coin.oPosX = coin.oPosX + dx / dist * pull
                    coin.oPosY = coin.oPosY + dy / dist * pull
                    coin.oPosZ = coin.oPosZ + dz / dist * pull
                end
                coin = obj_get_next_with_same_behavior_id(coin)
            end
        end
    end,
})

C.register({
    id = "shield_bubble", name = "Shield Bubble", kind = "help", duration = 15, target = "random",
    onMario = function(m)
        -- everyone sees the sparkles; only the owner's game applies the protection
        set_mario_particle_flags(m, PARTICLE_SPARKLES, 0)
        if is_local(m) and m.invincTimer < 3 then m.invincTimer = 3 end
    end,
})

---------------------------------------------------------------------------------------------- HINDER

C.register({
    id = "sticky_shoes", name = "Sticky Shoes", kind = "hinder", duration = 20,
    group = "landing",
    onStart = function(entry) entry.wasAir = false; entry.stuck = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if just_landed(m, entry) then entry.stuck = 22 end
        if entry.stuck > 0 then
            entry.stuck = entry.stuck - 1
            m.freeze = 3
            m.forwardVel = 0
            m.vel.x = 0
            m.vel.z = 0
        end
    end,
})

C.register({
    id = "rubber_legs", name = "Rubber Legs", kind = "hinder", duration = 20,
    group = "speed",
    onStart = function(entry) entry.lastAction = 0; entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if jump_started(m, entry) then
            m.vel.y = m.vel.y * (0.55 + math.random() * 0.95)
        end
    end,
    onBeforePhys = function(m, entry)
        if is_local(m) and grounded(m) then
            local s = 0.8 + 0.4 * math.sin((entry.tick or 0) / 9)
            m.vel.x = m.vel.x * s
            m.vel.z = m.vel.z * s
        end
    end,
})

C.register({
    id = "spaghetti_controls", name = "Spaghetti Controls", kind = "hinder", duration = 20,
    group = "controls",
    onBeforeMario = function(m, entry)
        if not is_local(m) then return end
        local t = tick_up(m, entry)
        rotate_stick(m, math.sin(t / 20) * 0.9)
    end,
})

C.register({
    id = "reverse_controls", name = "Reverse Controls", kind = "hinder", duration = 15,
    group = "controls",
    label = function() return "left is right" end,
    onBeforeMario = function(m)
        if is_local(m) then m.controller.stickX = -m.controller.stickX end
    end,
})

C.register({
    id = "heavy_cap", name = "Heavy Cap", kind = "hinder", duration = 20,
    group = "speed",
    onStart = function(entry) entry.lastAction = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if jump_started(m, entry) then m.vel.y = m.vel.y * 0.68 end
        if in_air(m) and not swimming(m) then m.vel.y = m.vel.y - 1.0 end
    end,
    onBeforePhys = function(m)
        if is_local(m) and grounded(m) then
            m.vel.x = m.vel.x * 0.88
            m.vel.z = m.vel.z * 0.88
        end
    end,
})

C.register({
    id = "slippery_floor", name = "Slippery Floor", kind = "hinder", scope = "world", duration = 20,
    group = "friction",
    onBeforePhys = function(m, entry) inertia(m, entry, 0.12) end,
})

C.register({
    id = "dizzy", name = "Dizzy", kind = "hinder", duration = 15,
    group = "controls",
    onStart = function(entry) entry.lastAction = 0; entry.tick = 0 end,
    onBeforeMario = function(m, entry)
        if not is_local(m) then return end
        local t = tick_up(m, entry)
        rotate_stick(m, math.sin(t / 14) * 0.55)
    end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if jump_started(m, entry) then
            m.faceAngle.y = m.faceAngle.y + math.random(0x3000, 0xD000)
        end
    end,
    hud = function(entry, sw, sh)
        local t = entry.tick or 0
        djui_hud_set_color(150, 120, 255, 28 + 18 * math.sin(t / 7))
        djui_hud_render_rect(0, 0, sw, sh)
    end,
})

C.register({
    id = "drunk", name = "Drunk", kind = "hinder", duration = 18,
    group = "controls",
    label = function() return "everything is backwards" end,
    onBeforeMario = function(m, entry)
        if not is_local(m) then return end
        local t = tick_up(m, entry)
        m.controller.stickX = -m.controller.stickX
        m.controller.stickY = -m.controller.stickY
        rotate_stick(m, math.sin(t / 16) * 0.6)
    end,
    -- no real blur available: a pulsing green-yellow haze and heavy eyelids
    hud = function(entry, sw, sh)
        local t = entry.tick or 0
        djui_hud_set_color(140, 255, 90, 38 + 26 * math.sin(t / 9))
        djui_hud_render_rect(0, 0, sw, sh)
        djui_hud_set_color(255, 90, 200, 20 + 16 * math.sin(t / 6 + 2))
        djui_hud_render_rect(0, 0, sw, sh)
        local lid = sh * (0.07 + 0.05 * (1 + math.sin(t / 25)) / 2)
        djui_hud_set_color(0, 0, 0, 170)
        djui_hud_render_rect(0, 0, sw, lid)
        djui_hud_render_rect(0, sh - lid, sw, lid)
    end,
})

------------------------------------------------------------------------------------ WORLD AND WEATHER

C.register({
    id = "lava_floor", name = "The Floor Is Lava", kind = "hinder", scope = "world", duration = 20,
    group = "ground",
    label = function() return "stay off the ground!" end,
    envfx = ENVFX_LAVA_BUBBLES,
    onStart = function(entry) entry.ground = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if grounded(m) then
            entry.ground = entry.ground + 1
        else
            entry.ground = (entry.ground < 0) and entry.ground + 1 or 0
        end
        if entry.ground == 30 then
            djui_chat_message_create("\\#ff8040\\The floor is lava!")
        end
        if entry.ground > 30 then set_mario_particle_flags(m, PARTICLE_FIRE, 0) end
        if entry.ground >= 70 and m.health > 0x100 then
            entry.ground = -60   -- grace period after being burnt
            set_mario_action(m, ACT_BURNING_JUMP, 0)
        end
    end,
})

C.register({
    id = "wind_gusts", name = "Wind Gusts", kind = "hinder", scope = "world", duration = 20,
    group = "wind",
    onStart = function(entry)
        entry.tick = 0
        entry.windAngle = entry.seed % 65536
    end,
    label = function(entry)
        local rel = (entry.windAngle - gMarioStates[0].faceAngle.y) & 0xFFFF
        if rel < 0x2000 or rel > 0xE000 then return "wind at your back" end
        if rel > 0x6000 and rel < 0xA000 then return "headwind!" end
        return "crosswind"
    end,
    onBeforePhys = function(m, entry)
        if not is_local(m) or swimming(m) or entry.manualStep then return end
        local gust = 0.55 + 0.45 * math.sin((entry.tick or 0) / 17)
        local wx, wz = sins(entry.windAngle), coss(entry.windAngle)
        local along = m.vel.x * wx + m.vel.z * wz
        local scale = (along < 0) and (1 - 0.7 * gust) or (1 + 0.3 * gust)
        local delta = along * (scale - 1)
        m.vel.x = m.vel.x + wx * delta
        m.vel.z = m.vel.z + wz * delta
        -- the shove also moves you when standing still (about 6 units a frame at full gust)
        local push = (in_air(m) and 5 or 7) * gust
        m.vel.x = m.vel.x + wx * push
        m.vel.z = m.vel.z + wz * push
    end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        tick_up(m, entry)
        -- standing players get blown along too
        local gust = 0.55 + 0.45 * math.sin(entry.tick / 17)
        C.push_standing(m, entry, sins(entry.windAngle) * 7 * gust, coss(entry.windAngle) * 7 * gust)
    end,
})

C.register({
    id = "ice_rink", name = "Ice Rink", kind = "hinder", scope = "world", duration = 20,
    group = "friction",
    envfx = ENVFX_SNOW_NORMAL,
    onBeforePhys = function(m, entry) inertia(m, entry, 0.045) end,
})

-- Darkness: a dim world with a warm light around every player (uses the lighting engine).
C.register({
    id = "darkness", name = "Lights Out", kind = "hinder", scope = "world", duration = 20,
    group = "light",
    onStart = function(entry)
        entry.lights = {}
        le_set_mode(LE_MODE_AFFECT_ALL_SHADED_AND_COLORED)
        le_set_ambient_color(28, 30, 55)
    end,
    onMario = function(m, entry)
        if not gNetworkPlayers[m.playerIndex].connected then return end
        local id = entry.lights[m.playerIndex]
        if id == nil then
            id = le_add_light(m.pos.x, m.pos.y + 80, m.pos.z, 255, 235, 200, 700, 1.0)
            entry.lights[m.playerIndex] = id
        else
            le_set_light_pos(id, m.pos.x, m.pos.y + 80, m.pos.z)
        end
    end,
    onEnd = function(entry)
        for _, id in pairs(entry.lights or {}) do le_remove_light(id) end
        le_set_ambient_color(255, 255, 255)
        le_set_mode(LE_MODE_AFFECT_ONLY_GEOMETRY_MODE)
    end,
})

-- Fog: uses the game's fog values, plus a light haze on screen so something shows even where fog is ignored.
C.register({
    id = "fog", name = "Thick Fog", kind = "hinder", scope = "world", duration = 20,
    group = "fog",
    onStart = function(entry)
        entry.oldIntensity = get_fog_intensity()
        entry.oldColor = { get_fog_color(0), get_fog_color(1), get_fog_color(2) }
        set_fog_color(0, 205)
        set_fog_color(1, 205)
        set_fog_color(2, 215)
        set_fog_intensity(1.06)
    end,
    onEnd = function(entry)
        if entry.oldColor ~= nil then
            for i = 0, 2 do set_fog_color(i, entry.oldColor[i + 1]) end
        end
        if entry.oldIntensity ~= nil then set_fog_intensity(entry.oldIntensity) end
    end,
    hud = function(entry, sw, sh)
        djui_hud_set_color(205, 205, 215, 70)
        djui_hud_render_rect(0, 0, sw, sh)
    end,
})

-- Rising water: only does something in levels that have a water plane.
C.register({
    id = "rising_water", name = "Rising Water", kind = "hinder", scope = "world", duration = 15,
    group = "water",
    onStart = function(entry)
        entry.base = get_water_level(0)
        entry.h = 0
    end,
    onMario = function(m, entry)
        if not is_local(m) or entry.base == nil or entry.base < -10000 then return end
        if entry.h < 900 then entry.h = entry.h + 6 end
        set_water_level(0, entry.base + entry.h, false)
    end,
    onEnd = function(entry)
        if entry.base ~= nil and entry.base > -10000 then set_water_level(0, entry.base, false) end
    end,
})

-- Bomb rain: bob-omb models fall and blow up on impact (a model that may be missing in some levels; the blast still lands).
local function bomb_init(o)
    o.oFlags = OBJ_FLAG_UPDATE_GFX_POS_AND_ANGLE
    cur_obj_scale(1.6)
    -- the bob-omb's own walk animation (legs kick while it falls) instead of a frozen pose
    o.oAnimations = gObjectAnimations.bobomb_seg8_anims_0802396C
    obj_init_animation_with_accel_and_sound(o, 0, 2.0)
end

local function bomb_loop(o)
    o.oVelY = o.oVelY - 1.8
    obj_move_xyz_using_fvel_and_yaw(o)
    o.oFaceAnglePitch = o.oFaceAnglePitch + 0x500
    local floor = find_floor_height(o.oPosX, o.oPosY + 120, o.oPosZ)
    if o.oPosY <= floor + 40 or o.oTimer > 240 then
        if floor > -10000 then
            C.blast(o, o.oPosX, floor, o.oPosZ, 2.4, 280, 2)   -- Bomb: medium blast, 2 damage
        end
        obj_mark_for_deletion(o)
    end
end

local bhvChaosBomb = hook_behavior(nil, OBJ_LIST_DEFAULT, true, bomb_init, bomb_loop)

C.register({
    id = "bomb_rain", name = "Bomb Rain", kind = "hinder", scope = "world", duration = 14,
    group = "sky",
    onStart = function(entry) entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        if entry.tick % 20 == 0 then
            local x, z = C.aim_drop(m, 750, 1800, 18)
            local ground = find_floor_height(x, m.pos.y + 400, z)
            if ground < -10000 then return end
            C.add_warning(x, ground, z, 280, C.fall_frames(1800, 18))
            spawn_non_sync_object(bhvChaosBomb, E_MODEL_BLACK_BOBOMB, x, ground + 1800, z, function(o)
                o.oVelY = -18
                o.oForwardVel = 0
            end)
        end
    end,
})

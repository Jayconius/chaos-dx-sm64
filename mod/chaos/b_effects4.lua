-- Chaos effects, batch 4: more Help. Vanish Cap, 1-Up, Regeneration, Safety Net, No Fall Damage, Turbo Swim,
-- Fireproof, Long Jump Rocket, Power Pound, Enemy Freeze, Star Radar, Regroup, Guardian Angel.
-- Hook order reminder: onBeforeMario (controls) -> Mario moves (onBeforePhys before each step) -> onMario.

local C = Chaos

local function is_local(m) return m.playerIndex == 0 end
local function in_air(m) return (m.action & ACT_FLAG_AIR) ~= 0 end
local function swimming(m) return (m.action & ACT_FLAG_SWIMMING) ~= 0 end
local function grounded(m) return not in_air(m) and not swimming(m) end

-- objects that count as enemies (same idea as Gravity Well)
local ENEMY_INTERACT = INTERACT_BOUNCE_TOP | INTERACT_BOUNCE_TOP2 | INTERACT_HIT_FROM_BELOW | INTERACT_KOOPA
    | INTERACT_DAMAGE | INTERACT_SHOCK | INTERACT_FLAME | INTERACT_SNUFIT_BULLET

local function for_each_enemy_near(m, radius, fn)
    for _, list in ipairs({ OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR }) do
        local o = obj_get_first(list)
        while o ~= nil do
            local nxt = obj_get_next(o)
            if (o.oInteractType & ENEMY_INTERACT) ~= 0 then
                local dx, dy, dz = o.oPosX - m.pos.x, o.oPosY - m.pos.y, o.oPosZ - m.pos.z
                if dx * dx + dz * dz < radius * radius and math.abs(dy) < radius then fn(o) end
            end
            o = nxt
        end
    end
end

local BURNING = { [ACT_BURNING_JUMP] = true, [ACT_BURNING_FALL] = true, [ACT_BURNING_GROUND] = true, [ACT_LAVA_BOOST] = true }

------------------------------------------------------------------------------------------------ HELP

C.register({
    id = "vanish_cap", name = "Vanish Cap", kind = "help", duration = 0, target = "random",
    onMario = function(m)
        if is_local(m) then
            m.flags = m.flags | MARIO_VANISH_CAP | MARIO_CAP_ON_HEAD
            m.capTimer = 20 * 30
        end
    end,
})

C.register({
    id = "one_up", name = "1-Up", kind = "help", duration = 0,
    onMario = function(m)
        if is_local(m) then
            m.numLives = math.min(m.numLives + 1, 99)
            play_sound(SOUND_GENERAL_COLLECT_1UP, gGlobalSoundSource)
        end
    end,
})

C.register({
    id = "regeneration", name = "Regeneration", kind = "help", duration = 20, group = "health",
    onStart = function(entry) entry.tick = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        entry.tick = entry.tick + 1
        -- about one health wedge every second
        if entry.tick % 30 == 0 and m.health > 0xFF and m.health < 0x880 then
            m.health = math.min(m.health + 0x100, 0x880)
            set_mario_particle_flags(m, PARTICLE_SPARKLES, 0)
        end
    end,
})

C.register({
    id = "safety_net", name = "Safety Net", kind = "help", duration = 25, group = "fall",
    label = function(entry) return entry.used and "used up" or "one free save from a pit" end,
    onStart = function(entry) entry.used = false end,
    onMario = function(m, entry)
        if not is_local(m) or entry.used then return end
        local floor = m.floor
        local deadly = (floor == nil) or (floor.type == SURFACE_DEATH_PLANE)
        if grounded(m) and floor ~= nil and floor.type ~= SURFACE_DEATH_PLANE and floor.type ~= SURFACE_BURNING then
            entry.safe = { x = m.pos.x, y = m.pos.y, z = m.pos.z }
        elseif in_air(m) and deadly and entry.safe ~= nil and m.pos.y < entry.safe.y - 500 then
            -- falling into a pit: put them back where they last stood safely
            entry.used = true
            m.pos.x, m.pos.y, m.pos.z = entry.safe.x, entry.safe.y + 100, entry.safe.z
            m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
            m.forwardVel = 0
            m.peakHeight = m.pos.y
            set_mario_action(m, ACT_FREEFALL, 0)
            play_sound(SOUND_GENERAL_HEART_SPIN, gGlobalSoundSource)
            djui_chat_message_create("\\#80ff80\\Safety Net caught you!")
        end
    end,
})

C.register({
    id = "no_fall_damage", name = "No Fall Damage", kind = "help", duration = 25, group = "fall",
    -- fall damage is worked out from the highest point of the fall; keep that at the current height
    onMario = function(m)
        if is_local(m) and in_air(m) and m.vel.y < 0 then m.peakHeight = m.pos.y end
    end,
})

C.register({
    id = "turbo_swim", name = "Turbo Swim", kind = "help", duration = 25,
    onStart = function(entry) entry.hp = nil end,
    onBeforePhys = function(m)
        if is_local(m) and swimming(m) then
            m.vel.x = m.vel.x * 1.7
            m.vel.y = m.vel.y * 1.4
            m.vel.z = m.vel.z * 1.7
        end
    end,
    -- no running out of breath: health can't drop while swimming
    onMario = function(m, entry)
        if not is_local(m) then return end
        if swimming(m) then
            if entry.hp ~= nil and m.health < entry.hp then m.health = entry.hp end
        else
            entry.hp = nil
        end
        if swimming(m) and entry.hp == nil then entry.hp = m.health end
    end,
})

C.register({
    id = "fireproof", name = "Fireproof", kind = "help", duration = 20, group = "fire",
    label = function() return "lava and blasts can't hurt you" end,
    onStart = function() C.fireproof = true end,
    onEnd = function() C.fireproof = false end,
    onMario = function(m)
        if not is_local(m) then return end
        if BURNING[m.action] then
            -- cancel the burn: no damage, no launch
            m.hurtCounter = 0
            if m.health < 0x100 then m.health = 0x100 end
            m.marioObj.oMarioBurnTimer = 0
            set_mario_action(m, in_air(m) and ACT_FREEFALL or ACT_IDLE, 0)
        end
    end,
})

C.register({
    id = "long_jump_rocket", name = "Long Jump Rocket", kind = "help", duration = 20,
    onStart = function(entry) entry.lastAction = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if m.action == ACT_LONG_JUMP and entry.lastAction ~= ACT_LONG_JUMP then
            m.forwardVel = math.min(m.forwardVel * 2, 110)
            m.vel.y = m.vel.y * 1.15
        end
        entry.lastAction = m.action
    end,
})

C.register({
    id = "power_pound", name = "Power Pound", kind = "help", duration = 25,
    label = function() return "ground pound to blast enemies" end,
    onStart = function(entry) entry.lastAction = 0 end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        if m.action == ACT_GROUND_POUND_LAND and entry.lastAction ~= ACT_GROUND_POUND_LAND then
            -- hit every enemy nearby as if it had been ground pounded (each enemy handles its own defeat)
            for_each_enemy_near(m, 650, function(o)
                o.oInteractStatus = ATTACK_GROUND_POUND_OR_TWIRL | INT_STATUS_INTERACTED | INT_STATUS_WAS_ATTACKED
            end)
            spawn_mist_particles_variable(0, 0, 200)
            set_environmental_camera_shake(SHAKE_ENV_EXPLOSION)
        end
        entry.lastAction = m.action
    end,
})

C.register({
    id = "enemy_freeze", name = "Enemy Freeze", kind = "help", scope = "world", duration = 15,
    onStart = function(entry) entry.held = {} end,
    onEnd = function(entry) entry.held = {} end,
    onMario = function(m, entry)
        if not is_local(m) then return end
        -- enemies near you are held where they were when they got close
        for_each_enemy_near(m, 1800, function(o)
            local h = entry.held[o]
            if h == nil then
                entry.held[o] = { x = o.oPosX, y = o.oPosY, z = o.oPosZ }
            else
                o.oPosX, o.oPosY, o.oPosZ = h.x, h.y, h.z
                o.oForwardVel = 0
                o.oVelY = 0
            end
        end)
    end,
})

-- Star Radar: a marker on screen over the nearest star or red coin
local radarPos, radarOut = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
C.register({
    id = "star_radar", name = "Star Radar", kind = "help", duration = 25,
    onMario = function(m, entry)
        if not is_local(m) then return end
        local best, bestD, bestKind = nil, math.huge, ""
        for _, b in ipairs({ { id_bhvStar, "star" }, { id_bhvRedCoin, "red coin" } }) do
            local o = obj_get_first_with_behavior_id(b[1])
            while o ~= nil do
                local dx, dy, dz = o.oPosX - m.pos.x, o.oPosY - m.pos.y, o.oPosZ - m.pos.z
                local d = dx * dx + dy * dy + dz * dz
                if d < bestD then best, bestD, bestKind = o, d, b[2] end
                o = obj_get_next_with_same_behavior_id(o)
            end
        end
        entry.radar = best and { x = best.oPosX, y = best.oPosY, z = best.oPosZ, kind = bestKind,
            dist = math.floor(math.sqrt(bestD) / 100) } or nil
    end,
    label = function(entry)
        if entry.radar == nil then return "nothing nearby" end
        return "nearest " .. entry.radar.kind .. ": " .. entry.radar.dist .. "m"
    end,
    hud = function(entry, sw, sh)
        local t = entry.radar
        if t == nil then return end
        radarPos.x, radarPos.y, radarPos.z = t.x, t.y + 60, t.z
        if djui_hud_world_pos_to_screen_pos(radarPos, radarOut) then
            local pulse = 1 + 0.25 * math.sin(get_global_timer() / 5)
            local s = 26 * pulse
            djui_hud_set_color(255, 214, 10, 230)
            djui_hud_render_rect(radarOut.x - s / 2, radarOut.y - 2, s, 4)
            djui_hud_render_rect(radarOut.x - 2, radarOut.y - s / 2, 4, s)
            djui_hud_print_text(t.dist .. "m", radarOut.x + 16, radarOut.y - 12, 1)
        end
    end,
})

-- Regroup: everyone in the host's level is pulled to the host. Only offered with 2+ players in the lobby.
C.register({
    id = "regroup", name = "Regroup", kind = "help", duration = 0, minPlayers = 2,
    onMario = function(m)
        if not is_local(m) or network_is_server() then return end
        local me, host = gNetworkPlayers[0], nil
        for i = 1, MAX_PLAYERS - 1 do
            if gNetworkPlayers[i].connected and gNetworkPlayers[i].globalIndex == 0 then host = i end
        end
        if host == nil then return end
        local hp = gNetworkPlayers[host]
        if hp.currLevelNum ~= me.currLevelNum or hp.currAreaIndex ~= me.currAreaIndex or hp.currActNum ~= me.currActNum then
            djui_chat_message_create("\\#ffb0ff\\Regroup: the host is in another level.")
            return
        end
        local h = gMarioStates[host].pos
        local a = math.random(0, 65535)
        m.pos.x, m.pos.y, m.pos.z = h.x + sins(a) * 120, h.y + 60, h.z + coss(a) * 120
        m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
        m.forwardVel = 0
        m.peakHeight = m.pos.y
        set_mario_action(m, ACT_FREEFALL, 0)
    end,
})

-- Guardian Angel: one free revive during the effect
local function guardian_check(m, entry)
    if not is_local(m) or entry.used then return end
    if m.health < 0x200 and (m.hurtCounter > 0 or m.health < 0x100) then
        entry.used = true
        m.health = 0x880
        m.hurtCounter = 0
        m.invincTimer = 60
        set_mario_particle_flags(m, PARTICLE_SPARKLES, 0)
        play_sound(SOUND_GENERAL_HEART_SPIN, gGlobalSoundSource)
        djui_chat_message_create("\\#80ff80\\Your Guardian Angel saved you!")
    end
end

C.register({
    id = "guardian_angel", name = "Guardian Angel", kind = "help", duration = 30, group = "health",
    label = function(entry) return entry.used and "used up" or "one free revive" end,
    onStart = function(entry) entry.used = false end,
    onBeforeMario = guardian_check,
    onMario = guardian_check,
})

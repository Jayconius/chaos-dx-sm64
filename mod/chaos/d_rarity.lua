-- Effect rarity: every effect gets a rarity from 0 (off) to 10. 5 is normal; the pick weight is rarity / 5.
-- Set in the Effect Rarity screen (mod menu button or /chaos effects). Saved per effect as r_<id> in chaos.sav.
-- Loads after all b_effects*.lua (alphabetical) and before main.lua.

local C = Chaos
C.RARITY_MAX = 10

-- Default rarities: everyday effects 5-6, strong/annoying ones 3-4, level-dependent ones 2, bosses 1.
C.DEFAULT_RARITY = {
    -- Help
    speed_boost = 6, moon_gravity = 6, super_jump = 6, tiny_mario = 5, heal = 5, wing_cap = 5, metal_cap = 4,
    coin_shower = 5, bounce_house = 5, featherweight = 5, second_wind = 5, magnet = 4, shield_bubble = 4,
    tailwind = 5, hover_boots = 5, rainbow_star = 3, vanish_cap = 4, one_up = 3, regeneration = 5, safety_net = 4,
    no_fall_damage = 5, turbo_swim = 3, fireproof = 4, long_jump_rocket = 5, power_pound = 4, enemy_freeze = 4,
    star_radar = 3, regroup = 3, guardian_angel = 3,
    -- Hinder
    heavy_gravity = 6, slow_walk = 6, giant_mario = 5, freeze = 5, knockback = 5, earthquake = 5, blizzard = 4,
    gravity_well = 4, fire_storm = 4, meteor_shower = 3, sticky_shoes = 5, rubber_legs = 5, spaghetti_controls = 4,
    reverse_controls = 4, heavy_cap = 5, slippery_floor = 5, dizzy = 4, drunk = 3, lava_floor = 4, wind_gusts = 5,
    ice_rink = 4, darkness = 3, fog = 3, rising_water = 2, bomb_rain = 3, lightning_storm = 3, hot_potato = 3,
    lava_rising = 2, low_res = 3, spotlight = 3, boo_mode = 3, bird_attack = 3,
    -- Bosses
    boss_goomba = 1, boss_wiggler = 1, boss_king_whomp = 1, boss_big_boo = 1,
}

function C.default_rarity(id) return C.DEFAULT_RARITY[id] or 5 end

function C.set_rarity(id, value, save)
    local def = C.effects[id]
    if def == nil then return false end
    value = math.max(0, math.min(C.RARITY_MAX, math.floor(value)))
    def.rarity = value
    def.weight = value / 5
    def.enabled = value > 0
    if save ~= false then mod_storage_save("r_" .. id, tostring(value)) end
    return true
end

-- saved rarity, else the old on/off tick box (off = 0), else the default
for _, id in ipairs(C.order) do
    local saved = tonumber(mod_storage_load("r_" .. id) or "")
    if saved == nil and mod_storage_load("off_" .. id) == "true" then saved = 0 end
    C.set_rarity(id, saved or C.default_rarity(id), false)
end

------------------------------------------------------------------------------------- Effect Rarity screen
local menu = { open = false, pending = false, sel = 2, top = 1, rows = {}, held = 0, heldDir = 0 }

local function build_rows()
    local rows = {}
    local function add_group(title, test)
        local ids = {}
        for _, id in ipairs(C.order) do
            if test(C.effects[id]) then table.insert(ids, id) end
        end
        table.sort(ids, function(a, b) return C.effects[a].name < C.effects[b].name end)
        table.insert(rows, { header = title })
        for _, id in ipairs(ids) do table.insert(rows, { id = id }) end
    end
    add_group("HELP", function(d) return d.kind == "help" and d.group ~= "boss" end)
    add_group("HINDER", function(d) return d.kind == "hinder" and d.group ~= "boss" end)
    add_group("BOSSES", function(d) return d.group == "boss" end)
    table.insert(rows, { button = "reset", label = "Reset all to defaults" })
    table.insert(rows, { button = "close", label = "Close" })
    menu.rows = rows
end

function C.open_rarity_menu()
    if not network_is_server() then
        djui_chat_message_create("\\#ffb0ff\\Only the host can change effect rarity.")
        return
    end
    build_rows()
    menu.sel, menu.top = 2, 1
    -- if it was opened from the pause menu, it appears as soon as the pause menu closes
    menu.pending = true
end

function C.rarity_menu_open() return menu.open end

local function close_menu() menu.open, menu.pending = false, false end

local function move(dir)
    local n = #menu.rows
    local i = menu.sel
    repeat
        i = i + dir
        if i < 1 then i = n elseif i > n then i = 1 end
    until menu.rows[i].header == nil
    menu.sel = i
end

local function change(dir)
    local row = menu.rows[menu.sel]
    if row and row.id then C.set_rarity(row.id, (C.effects[row.id].rarity or 0) + dir) end
end

local function activate()
    local row = menu.rows[menu.sel]
    if row == nil then return end
    if row.button == "close" then
        close_menu()
    elseif row.button == "reset" then
        for _, id in ipairs(C.order) do C.set_rarity(id, C.default_rarity(id)) end
        djui_chat_message_create("\\#80ff80\\Chaos: all effect rarities reset to defaults.")
    elseif row.id then
        -- A on an effect: toggle between off and its default
        local d = C.effects[row.id]
        C.set_rarity(row.id, (d.rarity or 0) > 0 and 0 or C.default_rarity(row.id))
    end
end

-- controller input (read before Mario uses it, then blocked so Mario stands still)
hook_event(HOOK_BEFORE_MARIO_UPDATE, function(m)
    if m.playerIndex ~= 0 then return end
    if menu.pending and not djui_hud_is_pause_menu_created() then
        menu.pending, menu.open = false, true
    end
    if not menu.open then return end
    local c = m.controller
    local pressed, down = c.buttonPressed, c.buttonDown
    -- stick / d-pad with repeat while held
    local dir, side = 0, 0
    if (down & U_JPAD) ~= 0 or c.stickY > 50 then dir = -1 elseif (down & D_JPAD) ~= 0 or c.stickY < -50 then dir = 1 end
    if (down & L_JPAD) ~= 0 or c.stickX < -50 then side = -1 elseif (down & R_JPAD) ~= 0 or c.stickX > 50 then side = 1 end
    local key = dir * 10 + side
    if key ~= 0 and key == menu.heldDir then
        menu.held = menu.held + 1
    else
        menu.held, menu.heldDir = 0, key
    end
    if key ~= 0 and (menu.held == 0 or (menu.held > 12 and menu.held % 4 == 0)) then
        if dir ~= 0 then move(dir) end
        if side ~= 0 then change(side) end
    end
    if (pressed & A_BUTTON) ~= 0 then activate() end
    if (pressed & B_BUTTON) ~= 0 then close_menu() end
    c.buttonPressed, c.buttonDown, c.stickX, c.stickY, c.stickMag = 0, 0, 0, 0, 0
end)

-- drawing + mouse (called from main.lua after its own HUD, so this draws on top)
function C.draw_rarity_menu()
    if not menu.open then return end
    djui_hud_set_resolution(RESOLUTION_DJUI)
    djui_hud_set_font(FONT_NORMAL)
    local sw, sh = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    local pw = math.min(820, sw - 60)
    local ph = sh - 100
    local px, py = (sw - pw) / 2, 50
    local rowH = 32
    local listY = py + 92
    local visible = math.max(4, math.floor((ph - 112) / rowH))

    -- keep the selection on screen
    if menu.sel < menu.top + 1 then menu.top = math.max(1, menu.sel - 1) end
    if menu.sel > menu.top + visible - 1 then menu.top = menu.sel - visible + 1 end

    -- mouse
    local mx, my = djui_hud_get_mouse_x(), djui_hud_get_mouse_y()
    local clicked = (djui_hud_get_mouse_buttons_pressed() & L_MOUSE_BUTTON) ~= 0
    local scroll = djui_hud_get_mouse_scroll_y()
    if scroll ~= 0 then
        menu.top = math.max(1, math.min(#menu.rows - visible + 1, menu.top - (scroll > 0 and 3 or -3)))
    end

    djui_hud_set_color(10, 12, 20, 235)
    djui_hud_render_rect(px, py, pw, ph)
    djui_hud_set_color(255, 200, 61, 255)
    djui_hud_render_rect(px, py, pw, 4)
    djui_hud_set_color(255, 200, 61, 255)
    djui_hud_print_text("EFFECT RARITY", px + 20, py + 14, 1.6)
    djui_hud_set_color(170, 175, 195, 255)
    djui_hud_print_text("Higher = more often.  0 = off.  Up/Down pick, Left/Right change, A on/off, B close.  Mouse works too.",
        px + 20, py + 58, 0.7)

    local nameX, barX = px + 24, px + pw - 400
    local segW, segGap = 28, 4
    for i = menu.top, math.min(#menu.rows, menu.top + visible - 1) do
        local row = menu.rows[i]
        local y = listY + (i - menu.top) * rowH
        local hover = mx >= px and mx <= px + pw and my >= y and my < y + rowH
        if row.header then
            djui_hud_set_color(255, 200, 61, 255)
            djui_hud_print_text(row.header, nameX, y + 6, 0.9)
        else
            if i == menu.sel then
                djui_hud_set_color(255, 200, 61, 60)
                djui_hud_render_rect(px + 10, y, pw - 20, rowH - 2)
            end
            if row.button then
                djui_hud_set_color(255, 255, 255, 255)
                djui_hud_print_text(row.label, nameX, y + 5, 0.9)
                if hover and clicked then menu.sel = i; activate() end
            else
                local d = C.effects[row.id]
                local r = d.rarity or 0
                if d.kind == "help" then djui_hud_set_color(120, 255, 140, 255) else djui_hud_set_color(255, 125, 125, 255) end
                if r == 0 then djui_hud_set_color(120, 120, 130, 255) end
                djui_hud_print_text(d.name, nameX, y + 5, 0.9)
                -- "off" box, then 10 segments
                local offX = barX - 44
                djui_hud_set_color(r == 0 and 220 or 70, 70, 80, 255)
                djui_hud_render_rect(offX, y + 6, 36, rowH - 14)
                djui_hud_set_color(255, 255, 255, 255)
                djui_hud_print_text("off", offX + 6, y + 6, 0.65)
                for k = 1, C.RARITY_MAX do
                    local sx = barX + (k - 1) * (segW + segGap)
                    if k <= r then djui_hud_set_color(255, 200, 61, 255) else djui_hud_set_color(55, 58, 72, 255) end
                    djui_hud_render_rect(sx, y + 6, segW, rowH - 14)
                end
                djui_hud_set_color(255, 255, 255, 255)
                djui_hud_print_text(r == 0 and "OFF" or tostring(r), barX + C.RARITY_MAX * (segW + segGap) + 8, y + 5, 0.9)
                if hover and clicked then
                    menu.sel = i
                    if mx >= offX and mx < offX + 36 then
                        C.set_rarity(row.id, 0)
                    elseif mx >= barX and mx < barX + C.RARITY_MAX * (segW + segGap) then
                        C.set_rarity(row.id, math.floor((mx - barX) / (segW + segGap)) + 1)
                    end
                end
            end
        end
    end

    -- scroll hint
    if #menu.rows > visible then
        local frac = (menu.top - 1) / math.max(1, #menu.rows - visible)
        djui_hud_set_color(70, 74, 90, 255)
        djui_hud_render_rect(px + pw - 10, listY, 4, visible * rowH)
        djui_hud_set_color(255, 200, 61, 255)
        djui_hud_render_rect(px + pw - 10, listY + frac * (visible * rowH - 30), 4, 30)
    end

    -- our own mouse cursor
    djui_hud_set_color(255, 255, 255, 255)
    djui_hud_render_rect(mx - 1, my - 7, 2, 14)
    djui_hud_render_rect(mx - 7, my - 1, 14, 2)
end

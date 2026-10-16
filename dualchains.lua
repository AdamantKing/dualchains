addon.name    = 'dualchains'
addon.author  = 'Adamantking'
addon.version = '1.0.0'
addon.desc    = 'Two characters on one computer: when both have enough TP, they use their weapon skills in order to make a skillchain.'
addon.link    = ''

require('common')
local chat  = require('chat')
local imgui = require('imgui')
local theme = require('theme')

----------------------------------------------------------------------
-- How it works
--   One character is the LEADER, the other the FOLLOWER (/dc role lead | follow, on each client).
--   Both clients run Ashita from the same install, so each one publishes a small status file
--   (config\addons\dualchains\dc_<Name>.txt: TP, engaged, zone, weapon skill, ...) and reads the other
--   character's - the same trick the Sidekick addon uses for its shared party list. No network needed.
--   When BOTH have at least their set TP and are engaged:
--     leader   : uses its weapon skill on its target
--     follower : assists the leader, sees the leader's TP drop (= the weapon skill went off), waits a moment
--                (/dc delay) so the skillchain window is open, then uses its own weapon skill.
--   That is all it does.
----------------------------------------------------------------------

local COL_DIM  = theme.C.muted
local COL_GO   = theme.C.green
local COL_WARN = theme.C.warn
local COL_HEAD = theme.C.gold

local TICK       = 0.2    -- seconds between checks
local STALE      = 3      -- partner status older than this many seconds = partner offline
local FIRE_WAIT  = 4      -- leader: seconds to wait for its weapon skill to go off
local FOLLOW_MAX = 8      -- follower: give up this long after the leader started
local COOLDOWN   = 6      -- leader: pause after a chain before the next attempt

local cfg = { role = '', ws = '', tp = 1000, delay = 3.0, assist = true, auto = false, ui = true }

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function say(msg)
    print(chat.header(addon.name):append(chat.message(msg)))
end

local evlog = {}        -- last few events, shown in the window
local function logf(msg)
    table.insert(evlog, 1, os.date('%H:%M:%S') .. '  ' .. msg)
    while #evlog > 6 do table.remove(evlog) end
end

local function queue(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd)
end

local function trim_quotes(s)
    s = (s or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local q = s:match('^"(.*)"$') or s:match("^'(.*)'$")
    return q or s
end

----------------------------------------------------------------------
-- Files: everything lives in <Ashita>\config\addons\dualchains\  (shared by every client of this install)
--   <Name>.cfg      this character's settings
--   dc_<Name>.txt   this character's live status, read by the other client
-- Characters are told apart by NAME (like Sidekick's party_<Name>.txt), not by role, so two characters set
-- to the same role are noticed instead of overwriting each other.
----------------------------------------------------------------------
local function share_dir()
    return AshitaCore:GetInstallPath():gsub('[\\/]+$', '') .. '\\config\\addons\\dualchains\\'
end

local dir_ready = false
local function ensure_dir()
    if dir_ready then return end
    pcall(function() ashita.fs.create_dir(share_dir()) end)
    dir_ready = true
end

local function status_path(name) return share_dir() .. 'dc_' .. name .. '.txt' end
local function cfg_path(name) return share_dir() .. name .. '.cfg' end

local cfg_name = nil
local function save_cfg()
    if not cfg_name then return end
    ensure_dir()
    local f = io.open(cfg_path(cfg_name), 'w')
    if not f then return end
    f:write(('role=%s\nws=%s\ntp=%d\ndelay=%.1f\nassist=%s\nauto=%s\nui=%s\n'):format(
        cfg.role, cfg.ws, cfg.tp, cfg.delay, tostring(cfg.assist), tostring(cfg.auto), tostring(cfg.ui)))
    f:close()
end

local function load_cfg(name)
    cfg_name = name
    local f = io.open(cfg_path(name), 'r')
    if not f then return end
    for line in f:lines() do
        local k, v = line:match('^(%w+)=(.*)$')
        if k == 'role' and (v == 'lead' or v == 'follow') then cfg.role = v
        elseif k == 'ws' then cfg.ws = v
        elseif k == 'tp' and tonumber(v) then cfg.tp = tonumber(v)
        elseif k == 'delay' and tonumber(v) then cfg.delay = tonumber(v)
        elseif k == 'assist' then cfg.assist = (v == 'true')
        elseif k == 'auto' then cfg.auto = (v == 'true')
        elseif k == 'ui' then cfg.ui = (v == 'true')
        end
    end
    f:close()
end

----------------------------------------------------------------------
-- Own state / partner state
----------------------------------------------------------------------
local own = nil          -- { name, tp, engaged, zone, sid }
local function read_own()
    local ok, r = pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        local party = mm:GetParty()
        if party:GetMemberIsActive(0) ~= 1 then return nil end
        local idx = party:GetMemberTargetIndex(0)
        return {
            name = party:GetMemberName(0),
            tp = party:GetMemberTP(0),
            engaged = (mm:GetEntity():GetStatus(idx) == 1),
            zone = party:GetMemberZone(0),
            sid = party:GetMemberServerId(0),
        }
    end)
    if ok and r and r.name and r.name ~= '' then return r end
    return nil
end

-- broadcast values: seq/fired/fail are the leader's handshake counters
local S = { seq = (os.time() % 1000000) * 100, fired = 0, fail = 0 }
local last_write, last_sig = -10, ''
local my_file = nil

local function write_status(now)
    if cfg.role == '' or not own then return end
    local body = ('name=%s\nrole=%s\ntp=%d\ntpneed=%d\nengaged=%d\nzone=%d\nsid=%d\nws=%s\narmed=%d\nseq=%d\nfired=%d\nfail=%d\n'):format(
        own.name, cfg.role, own.tp, cfg.tp, own.engaged and 1 or 0, own.zone or 0, own.sid or 0, cfg.ws,
        cfg.auto and 1 or 0, S.seq, S.fired, S.fail)
    if body == last_sig and now - last_write < 1.0 then return end
    last_sig, last_write = body, now
    ensure_dir()
    -- temp file, then swap it in (as Sidekick does): a reader never sees a half-written status
    local path = status_path(own.name)
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return end
    f:write(body .. ('ts=%d\nend=1\n'):format(os.time()))
    f:close()
    os.remove(path)                       -- os.rename cannot overwrite on Windows
    if not os.rename(tmp, path) then os.remove(tmp) return end
    my_file = path
end

local function parse_status(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local t = {}
    for line in f:lines() do
        local k, v = line:match('^(%w+)=(.*)$')
        if k then t[k] = v end
    end
    f:close()
    if t['end'] ~= '1' or not t.ts or not t.name then return nil end
    if math.abs(os.time() - (tonumber(t.ts) or 0)) > STALE then return nil end
    return {
        name = t.name, role = t.role or '', tp = tonumber(t.tp) or 0, tpneed = tonumber(t.tpneed) or 1000,
        engaged = (t.engaged == '1'), ws = t.ws or '', armed = (t.armed == '1'), zone = tonumber(t.zone) or 0,
        sid = tonumber(t.sid) or 0,
        seq = tonumber(t.seq) or 0, fired = tonumber(t.fired) or 0, fail = tonumber(t.fail) or 0,
    }
end

local partner = nil      -- the other character (opposite role), or nil when offline / stale
local conflict = nil     -- name of another character that picked the same role as you
local partner_t = -10    -- when partner was last read successfully (a missed read keeps it ~1.5 s)
local function read_partner(now)
    conflict = nil
    local found = nil
    if cfg.role ~= '' and own then
        -- list the folder unfiltered and match with a Lua pattern (get_dir's own filter is a std::regex)
        local ok, files = pcall(ashita.fs.get_dir, share_dir(), '.*', true)
        if ok and files then
            local names = {}
            for _, file in ipairs(files) do
                local owner = tostring(file):match('^dc_(.+)%.txt$')
                if owner and owner ~= own.name then names[#names + 1] = owner end
            end
            table.sort(names)
            for _, owner in ipairs(names) do
                local st = parse_status(status_path(owner))
                if st then
                    if st.role == cfg.role then conflict = conflict or st.name
                    elseif st.role ~= '' and not found then found = st end
                end
            end
        end
    end
    if found then
        partner, partner_t = found, now
    elseif partner and now - partner_t > 1.5 then
        partner = nil
    end
end

----------------------------------------------------------------------
-- State machines
----------------------------------------------------------------------
local lead = { phase = 'idle', t0 = 0, prev_tp = 0, cool = 0, manual = false }
local fol  = { phase = 'idle', t0 = 0, seen = nil, fire_at = 0 }
local note = ''          -- what the window shows as the current state

-- why the leader is not starting a chain right now (nil = ready)
local function not_ready()
    if cfg.role == '' then return 'Set a role: /dc role lead | follow' end
    if cfg.ws == '' then return 'Set your weapon skill: /dc ws <name>' end
    if not own then return 'Not logged in' end
    if not partner then return 'Waiting for the other character (is the addon loaded there?)' end
    if cfg.role == 'lead' and partner then
        if partner.ws == '' then return partner.name .. ' has no weapon skill set' end
        if not partner.armed then return partner.name .. ' is not armed (/dc on)' end
    end
    if partner.zone ~= own.zone then return partner.name .. ' is in another zone' end
    if own.tp < cfg.tp then return ('%s TP %d/%d'):format(own.name, own.tp, cfg.tp) end
    if partner.tp < partner.tpneed then return ('%s TP %d/%d'):format(partner.name, partner.tp, partner.tpneed) end
    if not own.engaged then return own.name .. ' is not engaged' end
    if not partner.engaged then return partner.name .. ' is not engaged' end
    return nil
end

local function lead_tick(now)
    if lead.phase == 'idle' then
        local why = not_ready()
        if why then note = why return end
        if not (cfg.auto or lead.manual) then note = 'Ready - auto is off (/dc on, or /dc go)' return end
        if now < lead.cool then note = 'Cooling down' return end
        lead.manual = false
        lead.prev_tp = own.tp
        S.seq = S.seq + 1
        lead.phase, lead.t0 = 'fire', now
        queue(('/ws "%s" <t>'):format(cfg.ws))
        note = 'Leader: ' .. cfg.ws
        logf('Leader started: ' .. cfg.ws)
    elseif lead.phase == 'fire' then
        if own.tp < lead.prev_tp - 100 or own.tp < cfg.tp then
            S.fired = S.seq                         -- the weapon skill went off: tell the follower
            lead.phase, lead.cool = 'idle', now + COOLDOWN
            note = 'Leader fired - follower next'
            logf('Leader weapon skill went off')
        elseif now - lead.t0 > FIRE_WAIT then
            S.fail = S.seq
            lead.phase, lead.cool = 'idle', now + 3
            note = 'Leader weapon skill did not go off (range? target?)'
            logf(note)
            say(note)
        end
    end
end

local function follow_tick(now)
    if not partner then note = 'Waiting for the leader (is the addon loaded there?)' return end
    if fol.seen == nil or partner.seq < fol.seen then fol.seen = partner.seq end   -- ignore old/reset counters
    if fol.phase == 'idle' then
        if cfg.role == '' or cfg.ws == '' then note = cfg.ws == '' and 'Set your weapon skill: /dc ws <name>' or '' return end
        if not cfg.auto then note = 'Not armed (/dc on)' return end
        note = ('Waiting for %s (%d/%d TP)'):format(partner.name, own and own.tp or 0, cfg.tp)
        if partner.seq > fol.seen then
            fol.seen = partner.seq
            fol.phase, fol.t0 = 'armed', now
            if cfg.assist then queue('/assist ' .. partner.name) end
        end
    elseif fol.phase == 'armed' then
        note = partner.name .. ' is starting...'
        if partner.fail == fol.seen then
            fol.phase = 'idle'
        elseif partner.fired == fol.seen then
            fol.phase, fol.fire_at = 'wait', now + cfg.delay
        elseif now - fol.t0 > FOLLOW_MAX then
            fol.phase = 'idle'
        end
    elseif fol.phase == 'wait' then
        note = ('Firing in %.1fs'):format(math.max(0, fol.fire_at - now))
        if now >= fol.fire_at then
            fol.phase = 'idle'
            if own and own.tp >= cfg.tp then
                queue(('/ws "%s" <t>'):format(cfg.ws))
                note = 'Follower: ' .. cfg.ws
                logf('Follower used: ' .. cfg.ws)
            else
                logf('Follower had too little TP - skipped')
                say('Follower does not have enough TP - skipped.')
            end
        end
    end
end

local last_tick = -10
local function tick(now)
    if now - last_tick < TICK then return end
    last_tick = now
    own = read_own()
    if own and cfg_name ~= own.name then load_cfg(own.name) end
    read_partner(now)
    write_status(now)
    if not own then note = 'Not logged in' return end
    if cfg.role == 'lead' then lead_tick(now)
    elseif cfg.role == 'follow' then follow_tick(now)
    else note = 'Set a role: /dc role lead | follow' end
end

----------------------------------------------------------------------
-- Window (/dc  or  /dc ui)
----------------------------------------------------------------------
local win_open = { true }
local TP_OPTS = { 1000, 1500, 2000, 2500, 3000 }

-- the weapon skills this character has learned (names), refreshed every few seconds
local ws_cache = { t = -10, list = {} }
local function learned_ws(now)
    if now - ws_cache.t < 3 then return ws_cache.list end
    ws_cache.t = now
    local list = {}
    pcall(function()
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        local res = AshitaCore:GetResourceManager()
        for id = 1, 255 do
            if player:HasWeaponSkill(id) then
                local a = res:GetAbilityById(id)
                local n = a and a.Name[1] or ''
                if n ~= '' then list[#list + 1] = n end
            end
        end
    end)
    table.sort(list)
    ws_cache.list = list
    return list
end

local function tp_row(label, tp, need, col)
    imgui.TextColored(col or COL_DIM, label)
    local frac = math.min(1, (tp or 0) / math.max(1, need or 1000))
    imgui.ProgressBar(frac, { -1, 14 }, ('%d / %d'):format(tp or 0, need or 0))
end

local function dot(ok) return ok and COL_GO or COL_WARN end

ashita.events.register('d3d_present', 'dualchains_present', function()
    local now = os.clock()
    tick(now)
    if not cfg.ui then return end

    imgui.SetNextWindowPos({ 300, 300 }, ImGuiCond_FirstUseEver)
    imgui.SetNextWindowSize({ 420, 470 }, ImGuiCond_FirstUseEver)
    win_open[1] = true
    local nc, nv = theme.push()
    if theme.begin('Dual Chains', win_open) then
        theme.header(win_open, 'DUAL', 'CHAINS', own and own.name or 'Not logged in')

        -- role + arm ---------------------------------------------------------
        theme.caption('ROLE')
        if theme.toggle('Leader  (goes first)', 'dcLead', cfg.role == 'lead') then
            cfg.role = 'lead' lead.phase, fol.phase = 'idle', 'idle' save_cfg()
        end
        imgui.SameLine()
        if theme.toggle('Follower  (goes second)', 'dcFol', cfg.role == 'follow') then
            cfg.role = 'follow' lead.phase, fol.phase = 'idle', 'idle' save_cfg()
        end
        if cfg.role == '' then
            imgui.TextColored(COL_WARN, 'Pick a role. Set the OTHER character to the opposite role.')
        end
        if conflict then
            imgui.TextColored(COL_WARN, conflict .. ' is also set to ' .. (cfg.role == 'lead' and 'Leader' or 'Follower')
                .. ' - one of you must switch.')
        end

        if theme.accent(cfg.auto and 'ARMED  (click to disarm)' or 'Arm', { 190, 0 }, cfg.auto) then
            cfg.auto = not cfg.auto
            if not cfg.auto then lead.phase, fol.phase = 'idle', 'idle' end
            save_cfg()
        end
        if cfg.role == 'lead' then
            imgui.SameLine()
            if theme.tinted('Chain now', COL_HEAD) then
                local why = not_ready()
                if why then logf('Not starting: ' .. why) else lead.manual, lead.cool = true, 0 end
            end
        end

        -- weapon skill ---------------------------------------------------------
        imgui.Spacing()
        theme.caption('WEAPON SKILL')
        local list = learned_ws(now)
        imgui.SetNextItemWidth(260)
        if imgui.BeginCombo('##dcws', cfg.ws ~= '' and cfg.ws or 'Choose a weapon skill...') then
            for _, n in ipairs(list) do
                if imgui.Selectable(n .. '##dcw', n == cfg.ws) then
                    cfg.ws = n
                    save_cfg()
                end
            end
            imgui.EndCombo()
        end
        if #list == 0 then
            imgui.TextColored(COL_DIM, "Couldn't read your weapon skills - use /dc ws <name>.")
        end

        -- TP + timing ------------------------------------------------------------
        imgui.Spacing()
        theme.caption('TP NEEDED  (this character)')
        for i, v in ipairs(TP_OPTS) do
            if i > 1 then imgui.SameLine() end
            if theme.toggle(tostring(v), 'dcTp' .. v, cfg.tp == v) then cfg.tp = v save_cfg() end
        end
        if cfg.role ~= 'lead' then
            theme.caption('FOLLOWER DELAY  (after the leader\'s weapon skill)')
            if imgui.Button('-##dcDm') then cfg.delay = math.max(0, cfg.delay - 0.5) save_cfg() end
            imgui.SameLine()
            imgui.Text(('%.1f s'):format(cfg.delay))
            imgui.SameLine()
            if imgui.Button('+##dcDp') then cfg.delay = math.min(8, cfg.delay + 0.5) save_cfg() end
            imgui.SameLine()
            if theme.toggle('Assist leader', 'dcAs', cfg.assist) then cfg.assist = not cfg.assist save_cfg() end
        end

        -- both characters --------------------------------------------------------
        imgui.Separator()
        tp_row((own and own.name or 'You') .. (own and own.engaged and '  (engaged)' or ''), own and own.tp or 0, cfg.tp,
            own and dot(own.tp >= cfg.tp) or COL_DIM)
        if partner then
            tp_row(partner.name .. (partner.engaged and '  (engaged)' or '') .. '   ' .. (partner.ws ~= '' and partner.ws or '(no weapon skill)')
                .. (partner.armed and '' or '   not armed'), partner.tp, partner.tpneed, dot(partner.tp >= partner.tpneed))
        else
            imgui.TextColored(COL_WARN, 'Other character: not found')
            imgui.TextColored(COL_DIM, 'Load Dual Chains on it too, with the opposite role. Both clients must run from the same Ashita install.')
        end

        imgui.Spacing()
        imgui.TextColored((fol.phase ~= 'idle' or lead.phase ~= 'idle') and COL_GO or COL_DIM, note)
        if #evlog > 0 then
            imgui.Spacing()
            theme.caption('RECENT')
            for _, l in ipairs(evlog) do imgui.TextColored(COL_DIM, l) end
        end
    end
    theme.finish()
    theme.pop(nc, nv)
    if not win_open[1] then cfg.ui = false save_cfg() end
end)

----------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------
local function help()
    say('Dual Chains - two characters on this computer use weapon skills in order to make a skillchain.')
    say('Load it on BOTH clients (same Ashita install), then:  /dc role lead  |  /dc role follow')
    say('/dc ws <name>        weapon skill this character uses (e.g. /dc ws Savage Blade)')
    say('/dc tp <amount>      TP this character needs before a chain starts (default 1000)')
    say('/dc on | off         arm / disarm (the leader starts a chain when both are armed and at TP)')
    say('/dc go               leader: start one chain now (both still need their TP)')
    say('/dc delay <sec>      follower waits this long after the leader\'s weapon skill (default 3)')
    say('/dc assist on|off    follower assists the leader before its weapon skill (default on)')
    say('/dc status           show settings and the other character')
    say('/dc  (or /dc ui)     show / hide the window - everything above can be set there too')
end

local function status()
    say(('role: %s   ws: %s   tp: %d   delay: %.1fs   assist: %s   %s'):format(
        cfg.role ~= '' and cfg.role or '(none)', cfg.ws ~= '' and cfg.ws or '(none)', cfg.tp, cfg.delay,
        cfg.assist and 'on' or 'off', cfg.auto and 'ARMED' or 'off'))
    if partner then
        say(('other: %s  ws: %s  tp: %d/%d  engaged: %s  armed: %s'):format(
            partner.name, partner.ws ~= '' and partner.ws or '(none)', partner.tp, partner.tpneed,
            partner.engaged and 'yes' or 'no', partner.armed and 'yes' or 'no'))
    else
        say('other character: not found (load the addon there and give it the opposite role)')
    end
    say('state: ' .. note)
end

ashita.events.register('command', 'dualchains_command', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local c = args[1]:lower()
    if c ~= '/dc' and c ~= '/dualchains' then return end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or ''
    local rest = e.command:match('^%S+%s+%S+%s+(.+)$')

    if sub == '' then
        cfg.ui = not cfg.ui
        save_cfg()
    elseif sub == 'help' then
        help()
    elseif sub == 'role' then
        local r = args[3] and args[3]:lower() or ''
        if r == 'lead' or r == 'leader' then cfg.role = 'lead'
        elseif r == 'follow' or r == 'follower' then cfg.role = 'follow'
        else say('Usage: /dc role lead | follow') return end
        lead.phase, fol.phase = 'idle', 'idle'
        save_cfg()
        say('Role: ' .. cfg.role)
    elseif sub == 'ws' then
        if not rest then say('Usage: /dc ws <weapon skill name>') return end
        cfg.ws = trim_quotes(rest)
        save_cfg()
        say('Weapon skill: ' .. cfg.ws)
    elseif sub == 'tp' then
        local n = tonumber(args[3])
        if not n or n < 1000 or n > 3000 then say('Usage: /dc tp <1000-3000>') return end
        cfg.tp = math.floor(n)
        save_cfg()
        say('TP needed: ' .. cfg.tp)
    elseif sub == 'delay' then
        local n = tonumber(args[3])
        if not n or n < 0 or n > 8 then say('Usage: /dc delay <0-8 seconds>') return end
        cfg.delay = n
        save_cfg()
        say(('Follower delay: %.1fs'):format(n))
    elseif sub == 'assist' then
        local v = args[3] and args[3]:lower() or ''
        if v ~= 'on' and v ~= 'off' then say('Usage: /dc assist on | off') return end
        cfg.assist = (v == 'on')
        save_cfg()
        say('Follower assist: ' .. v)
    elseif sub == 'on' then
        cfg.auto = true
        save_cfg()
        say('Armed.')
    elseif sub == 'off' then
        cfg.auto = false
        lead.phase, fol.phase = 'idle', 'idle'
        save_cfg()
        say('Off.')
    elseif sub == 'go' then
        if cfg.role ~= 'lead' then say('Only the leader starts a chain (/dc role lead).') return end
        local why = not_ready()
        if why then say('Not starting: ' .. why) return end
        lead.manual, lead.cool = true, 0
    elseif sub == 'status' then
        status()
    elseif sub == 'ui' or sub == 'window' then
        cfg.ui = not cfg.ui
        save_cfg()
    else
        help()
    end
end)

ashita.events.register('unload', 'dualchains_unload', function()
    if my_file then pcall(os.remove, my_file) end
end)

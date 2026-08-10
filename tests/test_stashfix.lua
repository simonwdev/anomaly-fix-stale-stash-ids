-- Behavioural test for zzz_aaa_stash_stale_id_fix.script under stubbed Anomaly API.
-- Run from the repo root: luajit tests/test_stashfix.lua
local SCRIPT = arg[1] or "gamedata/scripts/zzz_aaa_stash_stale_id_fix.script"

local INVBOX_CLSID, FOOD_CLSID = 41, 77

-- world: id -> { section, clsid, lvl, parent }
-- Game vertex id and level id are both just the object id in this stub, so
-- alife():level_name(game_graph():vertex(gvid):level_id()) round-trips to .lvl.
local world = {
    [100] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "l09_deadcity" },
    [101] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "l09_deadcity" },
    [102] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "l09_deadcity" },
    [103] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "zaton" },
    -- real box, but on a map treasure_manager blacklists: never a destination
    [104] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "l13_generators" },
    -- real box whose graph vertex is the 65535 sentinel: stash_level must not
    -- index the game graph with it
    [105] = { section = "inventory_box", clsid = INVBOX_CLSID, lvl = "zaton", bad_gvid = true },
    -- recycled IDs: were boxes, now items sitting in an NPC's inventory
    [200] = { section = "cooking",       clsid = FOOD_CLSID, lvl = "l09_deadcity", parent = 300 },
    [201] = { section = "ground_coffee", clsid = FOOD_CLSID, lvl = "l09_deadcity", parent = 300 },
    [202] = { section = "vodka",         clsid = FOOD_CLSID, lvl = "l09_deadcity", parent = 300 },
    [300] = { section = "merc_mechanic", clsid = 9,          lvl = "l09_deadcity" },
}

local DEADCITY_BOXES = { [100] = true, [101] = true, [102] = true }

local spots = {}                    -- [id][spot] = hint
local add_counts = {}               -- [id] = number of map_add_object_spot_ser calls
local log = {}

local function se(id)
    local o = world[id]
    if not o then return nil end
    return {
        id = id,
        parent_id = o.parent or 65535,
        m_game_vertex_id = o.bad_gvid and 65535 or id,
        clsid = function() return o.clsid end,
        name = function() return o.section .. tostring(id) end,
        section_name = function() return o.section end,
    }
end

-- ---- treasure_manager stub, mirroring the real module's shape --------------
local caches_count = 0              -- file-local in the real module
local tm = { caches = {} }

local function enroll(id) tm.caches[id] = false; caches_count = caches_count + 1 end

local BLACKLISTED_MAP = "l13_generators"
local env                           -- forward declared; the stub below needs it

function tm.release_stash_by_id(id)
    if id and tm.caches[id] then                     -- real code: falsy -> no-op
        tm.caches[id] = nil
        caches_count = caches_count - 1
    end
end

-- The unwrapped stub, kept so the vanilla falsy-guard defect can be asserted
-- directly rather than inferred. tm.release_stash_by_id is replaced by the
-- release_stash_by_id wrapper.
local base_release = tm.release_stash_by_id

local get_calls, set_calls = {}, {}
-- What the *unfiltered* base call draws. The wrapper does not force the inv_box
-- filter on: it validates the draw and only re-calls with the filter when the
-- draw was bad, so the stub has to be able to return a stale id.
local draws = { 100 }
local draw_n = 0

-- The four-value shape is the real one: get_random_stash returns
-- (id, new_name, new_descr, hint) when the box has translations
-- (treasure_manager.script:470), and dialogs_lostzone.script:777 unpacks all
-- four. The wrapper must pass every one of them through.
function tm.get_random_stash(no_spot, hint, spawn_local, inv_box)
    -- Normalised to a boolean: the interesting argument is now nil on the common
    -- path, and `t[#t + 1] = nil` does not grow the table, so the call would go
    -- unrecorded and every count below would read zero.
    get_calls[#get_calls + 1] = (inv_box and true or false)
    -- inv_box = true is the real filter: it can only ever return a live box.
    if inv_box then
        return 100, "st_name", "st_descr", hint
    end
    draw_n = draw_n + 1
    return (draws[draw_n] or draws[#draws]), "st_name", "st_descr", hint
end
function tm.set_random_stash(no_spot, hint, bonus, id, dbg)
    set_calls[#set_calls + 1] = id
    return id
end

-- ---- environment ---------------------------------------------------------
local callbacks = {}
env = {
    treasure_manager = tm,
    alife_object = se,
    IsInvbox = function(_, c) return c == INVBOX_CLSID end,
    printf = function(fmt, ...) log[#log + 1] = string.format(fmt, ...) end,
    RegisterScriptCallback = function(name, fn) callbacks[name] = fn end,
    -- sim:object(id) is what alife_object wraps (_g.script:2062-2068), minus the
    -- bounds guard. Code that has already screened the id with usable_id calls it
    -- directly to avoid the wrapper and a second alife() call, so the stub has to
    -- offer both. Unlike alife_object it is unguarded here too: an out-of-range id
    -- reaching it means the caller skipped its screen.
    alife = function()
        return {
            level_name = function(_, lid) return world[lid] and world[lid].lvl end,
            object = function(_, id)
                if type(id) ~= "number" or id < 0 or id >= 65535 then
                    error("alife():object(" .. tostring(id) .. ") was not screened", 2)
                end
                return se(id)
            end,
        }
    end,
    -- CGameGraph::vertex is `m_nodes + vertex_id` with no bounds check
    -- (game_graph_inline.h:117-120), so an out-of-range id is an out-of-bounds
    -- read in the real engine. Model that as an error: any code reaching it
    -- without calling valid_vertex_id first is a bug.
    game_graph = function()
        return {
            valid_vertex_id = function(_, gvid) return world[gvid] ~= nil end,
            vertex = function(_, gvid)
                if not world[gvid] then
                    error("game_graph():vertex(" .. tostring(gvid) .. ") is out of bounds", 2)
                end
                return { level_id = function() return gvid end }
            end,
        }
    end,
    -- No translations defined, so stash_hint falls back to "".
    game = { translate_string = function(k) return k end },
    level = {
        map_has_object_spot = function(id, spot)
            return (spots[id] and spots[id][spot]) and 1 or 0
        end,
        map_remove_object_spot = function(id, spot)
            if spots[id] then spots[id][spot] = nil end
        end,
        -- AddMapLocation has no duplicate guard (map_manager.cpp:123-132), so
        -- count adds rather than overwrite: a second add on the same key is a
        -- second overlapping location in the real engine.
        map_add_object_spot_ser = function(id, spot, hint)
            spots[id] = spots[id] or {}
            add_counts[id] = (add_counts[id] or 0) + 1
            spots[id][spot] = hint or ""
        end,
    },
}
setmetatable(env, { __index = _G })

-- Mirrors the real box_in_valid_map (treasure_manager.script:888-893) exactly,
-- including the part that matters: it reads the game graph *unguarded*. Anything
-- that hands it an id whose m_game_vertex_id is stale or the 65535 sentinel is
-- performing an out-of-bounds read in the engine, so here that errors. A stub
-- that read .lvl straight out of the world table would be weaker than the real
-- function and would let a missing screen pass silently.
function tm.box_in_valid_map(id)
    local se_stash = env.alife_object(id)
    local lvl = se_stash and env.alife():level_name(
        env.game_graph():vertex(se_stash.m_game_vertex_id):level_id())
    return lvl ~= BLACKLISTED_MAP
end

local chunk = assert(loadfile(SCRIPT))
setfenv(chunk, env)
chunk()

-- ---- scenario ------------------------------------------------------------
local LOOT_A = "wpn_k98,tarpaulin,headlamp"
local LOOT_B = "vodka,bread,bandage"
local LOOT_C = "kolbasa,conserva,medkit"
local LOOT_D = "wpn_pm,ammo_9x18_fmj"
local LOOT_E = "itm_basickit,vodka"

enroll(100); enroll(101); enroll(102); enroll(103); enroll(104); enroll(105)
enroll(200); enroll(201); enroll(202)              -- three stale entries

tm.caches[200] = LOOT_A                            -- bogus stash: loot + marker
spots[200] = { treasure = "Stash" }
tm.caches[202] = LOOT_B                            -- bogus unmarked stash: loot, no spot

env.on_game_start()
callbacks["actor_on_first_update"]()                -- run the sweep

-- ---- assertions ----------------------------------------------------------
local fails = 0
local function check(name, ok, extra)
    print((ok and "  PASS  " or "  FAIL  ") .. name .. (extra and ("  -- " .. extra) or ""))
    if not ok then fails = fails + 1 end
end

local function holder_of(loot)
    for id, state in pairs(tm.caches) do
        if state == loot then return id end
    end
    return nil          -- explicit: callers tostring() this, and a bare return
end                     -- yields *no* value rather than nil

check("stale entries all dropped",
    tm.caches[200] == nil and tm.caches[201] == nil and tm.caches[202] == nil)
check("bogus map spot removed from the non-box", spots[200].treasure == nil)

local a, b = holder_of(LOOT_A), holder_of(LOOT_B)
check("marked orphan loot relocated to a real box", a ~= nil, "landed on " .. tostring(a))
check("unmarked orphan loot relocated to a real box", b ~= nil, "landed on " .. tostring(b))
check("two orphans do not collide on one box", a ~= b)
check("replacement prefers the bogus marker's level",
    DEADCITY_BOXES[a] and DEADCITY_BOXES[b], "a=" .. tostring(a) .. " b=" .. tostring(b))
check("off-level box left alone", tm.caches[103] == false)
check("blacklisted-map box is never a destination", tm.caches[104] == false)
check("relocated marked stash raised the same spot type on the new box",
    a and spots[a] and spots[a].treasure ~= nil)
check("marker raised exactly once, no duplicate location",
    add_counts[a] == 1, "adds=" .. tostring(add_counts[a]))
check("relocated unmarked stash stayed unmarked",
    b and (not spots[b] or spots[b].treasure == nil))
check("caches_count back in sync with table", caches_count == 6,
    "count=" .. caches_count)

-- A real box whose graph vertex is the 65535 sentinel must be screened out
-- before anything reads the graph for it, including treasure_manager's own
-- box_in_valid_map, which reads it unguarded. Reaching the sweep at all proves
-- no out-of-bounds read happened (the stub errors on one); the entry itself is
-- left alone, just never chosen as a destination.
check("sentinel-gvid box survived the sweep without an out-of-bounds read",
    tm.caches[105] == false, "state=" .. tostring(tm.caches[105]))

-- A clean draw must not pay for the pool-wide inv_box filter: one base call, with
-- the caller's own inv_box argument passed through untouched.
local calls_before = #get_calls
local rid, rname, rdescr, rhint = tm.get_random_stash(nil, "h", true, nil)
check("clean draw does not force the inv_box filter",
    (#get_calls == calls_before + 1) and (get_calls[#get_calls] == false),
    "calls=" .. (#get_calls - calls_before) .. " inv_box=" .. tostring(get_calls[#get_calls]))
check("get_random_stash passes all four return values through",
    rid == 100 and rname == "st_name" and rdescr == "st_descr" and rhint == "h",
    string.format("%s,%s,%s,%s", tostring(rid), tostring(rname), tostring(rdescr),
        tostring(rhint)))

-- A caller that asks for the filter itself still gets
-- it, and is not double-checked.
calls_before = #get_calls
rid = tm.get_random_stash(nil, "h", true, true)
check("a caller's own inv_box = true is passed straight through",
    (#get_calls == calls_before + 1) and (get_calls[#get_calls] == true) and rid == 100,
    "inv_box=" .. tostring(get_calls[#get_calls]))

-- The stale draw: the guarantee has to survive not forcing the filter. The base
-- call hands back a recycled id, so the wrapper must drop it and redraw *with* the
-- filter, and the caller must never see the bad id.
enroll(200)
draws = { 200 }; draw_n = 0
calls_before = #get_calls
rid, rname, rdescr, rhint = tm.get_random_stash(nil, "h", true, nil)
check("a stale draw is redrawn with the filter forced on",
    (#get_calls == calls_before + 2) and (get_calls[#get_calls - 1] == false)
    and (get_calls[#get_calls] == true),
    "calls=" .. (#get_calls - calls_before))
check("the caller never sees the stale id", rid == 100 and rid ~= 200,
    "got " .. tostring(rid))
check("the stale entry is dropped on the way out", tm.caches[200] == nil)
check("the redraw still returns all four values",
    rname == "st_name" and rdescr == "st_descr" and rhint == "h")

-- Nothing available at all is not a bad draw: pass the nil back without a redraw.
draws = { nil }; draw_n = 0
calls_before = #get_calls
rid = tm.get_random_stash(nil, "h", true, nil)
check("an empty pool returns nil without a redraw",
    rid == nil and (#get_calls == calls_before + 1),
    "id=" .. tostring(rid) .. " calls=" .. (#get_calls - calls_before))
draws = { 100 }; draw_n = 0

local before = #set_calls
check("set_random_stash accepts a real box",
    tm.set_random_stash(nil, "h", nil, 101) == 101 and #set_calls == before + 1)

before = #set_calls
check("set_random_stash refuses a non-box",
    tm.set_random_stash(nil, "h", nil, 200) == nil and #set_calls == before)
check("set_random_stash refuses a missing id",
    tm.set_random_stash(nil, "h", nil, 9999) == nil and #set_calls == before)
check("set_random_stash still allows the dbg path",
    tm.set_random_stash(nil, nil, nil, 7, true) == 7 and #set_calls == before + 1)

enroll(200)
tm.set_random_stash(nil, "h", nil, 200)
check("refusal also prunes the entry", tm.caches[200] == nil and caches_count == 6,
    "count=" .. caches_count)

-- A point-of-use refusal on an entry that is already holding loot erases a
-- contents string the player may have been told about, and unlike the sweep these
-- hooks do not relocate it. The log line is the only route back to it, so it is
-- behaviour, not diagnostics.
local function logged_since(mark, needle)
    for i = mark + 1, #log do
        if string.find(log[i], needle, 1, true) then return true end
    end
    return false
end

local LOOT_E = "wpn_toz34,ammo_12x70_buck"
enroll(201); tm.caches[201] = LOOT_E
local log_mark = #log
tm.set_random_stash(nil, "h", nil, 201)
check("set_random_stash refusal names the loot it erases",
    tm.caches[201] == nil and logged_since(log_mark, "discarded: " .. LOOT_E))

-- The clean-draw hook shares drop_in_use but can never reach a string, since base
-- only ever draws an available (false) entry. Assert the quiet path stays quiet.
enroll(200)
draws = { 200, 100 }; draw_n = 0
log_mark = #log
tm.get_random_stash()
check("a draw-time drop of an available entry logs no discard",
    tm.caches[200] == nil and not logged_since(log_mark, "discarded: "))
draws = { 100 }; draw_n = 0

-- Hook 6: release_stash_by_id. Vanilla guards on the value rather than the key,
-- so it declines to prune exactly the available entries game_setup asks it about,
-- which is where the stale entries come from in the first place. Ids here are
-- arbitrary because this function is pure table bookkeeping with no class test.
enroll(9001)
local count_before = caches_count
base_release(9001)
check("vanilla release_stash_by_id no-ops on an available entry",
    tm.caches[9001] == false and caches_count == count_before,
    "count=" .. caches_count)

tm.release_stash_by_id(9001)
check("the wrapper prunes an available entry, caches_count in step",
    tm.caches[9001] == nil and caches_count == count_before - 1,
    "count=" .. caches_count)

-- Promoting an absent key would enrol a stash instead of removing one.
count_before = caches_count
tm.release_stash_by_id(9002)
check("the wrapper does not enrol an absent id",
    tm.caches[9002] == nil and caches_count == count_before)

-- A loaded entry already worked without the wrapper; it must not be counted twice.
enroll(9003); tm.caches[9003] = "vodka"
count_before = caches_count
tm.release_stash_by_id(9003)
check("a loaded entry is pruned exactly once",
    tm.caches[9003] == nil and caches_count == count_before - 1,
    "count=" .. caches_count)

check("the wrapper tolerates a nil id", pcall(tm.release_stash_by_id, nil))

-- ---- -keep_lua: on_game_start runs again on a state that kept the wrappers ---
-- Without the once-only guard the wrappers would gain a layer per load; without
-- clearing `swept` the sweep would never run again. Both on the same live chunk,
-- because that is what a persistent Lua state gives you.
local wrapped_get, wrapped_set = tm.get_random_stash, tm.set_random_stash
local wrapped_release = tm.release_stash_by_id
callbacks["actor_on_first_update"] = nil
enroll(202); tm.caches[202] = LOOT_C                 -- a fresh stale entry
spots[202] = { treasure = "Stash" }

env.on_game_start()
check("second on_game_start does not stack wrappers",
    tm.get_random_stash == wrapped_get and tm.set_random_stash == wrapped_set
    and tm.release_stash_by_id == wrapped_release)
check("callback is registered again on a persistent state",
    type(callbacks["actor_on_first_update"]) == "function")

callbacks["actor_on_first_update"]()
check("sweep runs again after a second on_game_start", tm.caches[202] == nil)
check("relocated again rather than binned", holder_of(LOOT_C) ~= nil,
    "landed on " .. tostring(holder_of(LOOT_C)))

-- No same-level box left: relocation must fall back to any level rather than bin
-- it, but still never to the blacklisted-map box (104).
tm.caches[100] = nil; tm.caches[101] = nil; tm.caches[102] = nil; tm.caches[105] = nil
caches_count = 2                                     -- 103 (zaton) + 104 (blacklisted)
tm.caches[103] = false
tm.caches[104] = false
enroll(201); tm.caches[201] = LOOT_A
spots[201] = { treasure = "Stash" }
local swept_again = loadfile(SCRIPT)
setfenv(swept_again, env)
swept_again()                                        -- fresh chunk: `swept` resets
env.on_game_start()
callbacks["actor_on_first_update"]()
check("falls back to another level when none on the marker's level",
    tm.caches[103] == LOOT_A and spots[103] and spots[103].treasure ~= nil)
check("fallback still refuses the blacklisted-map box", tm.caches[104] == false)

-- ---- a real box whose game vertex will not survive the read ----------------
-- 105 is a genuine inventory box carrying the 65535 sentinel. set_random_stash
-- indexes the game graph with that vertex unchecked (treasure_manager:372),
-- so the wrapper must refuse it. But it is a real box, so unlike a non-box
-- refusal the entry has to stay in the pool.
enroll(105)
before = #set_calls
check("set_random_stash refuses a box with a sentinel game vertex",
    tm.set_random_stash(nil, "h", nil, 105) == nil and #set_calls == before)
check("that refusal keeps the entry, it is a real box",
    tm.caches[105] == false and caches_count == 3, "count=" .. caches_count)

-- ---- a clean pool -----------------------------------------------------------
-- Nothing stale: the sweep must touch nothing, and must still say it ran. A
-- silent no-op is indistinguishable from the mod not being loaded.
local fresh = loadfile(SCRIPT)
setfenv(fresh, env)
fresh()
env.on_game_start()
callbacks["actor_on_first_update"]()
check("clean pool leaves every entry alone",
    tm.caches[103] == LOOT_A and tm.caches[104] == false and tm.caches[105] == false
    and caches_count == 3, "count=" .. caches_count)
check("clean pool still logs that it ran",
    log[#log] and string.find(log[#log], "no stale ids", 1, true) ~= nil,
    tostring(log[#log]))

-- ---- nowhere left to move the loot: the discard path ------------------------
-- The only branch that destroys player loot, so it does not get to go untested.
-- Pool is one stale entry holding loot plus a single real box that sits on a
-- blacklisted map, which is never a valid destination.
tm.caches[103] = nil; tm.caches[105] = nil
caches_count = 1                                     -- 104 (blacklisted) only
tm.caches[104] = false
enroll(200); tm.caches[200] = LOOT_D
spots[200] = { treasure = "Stash" }

local log_before = #log
fresh = loadfile(SCRIPT)
setfenv(fresh, env)
fresh()
env.on_game_start()
callbacks["actor_on_first_update"]()

check("stale entry is still dropped when there is nowhere to move it",
    tm.caches[200] == nil and caches_count == 1, "count=" .. caches_count)
check("its bogus marker goes with it",
    not spots[200] or spots[200].treasure == nil)
check("the blacklisted-map box is not used as a last resort", tm.caches[104] == false)
check("discarded contents are named in the log, so they can be restored by hand",
    (function()
        for i = log_before + 1, #log do
            if string.find(log[i], "discarded: " .. LOOT_D, 1, true) then return true end
        end
        return false
    end)())

-- ---- an error mid-sweep must not have already binned the loot ---------------
-- `swept` is set before any work, so a sweep that throws never runs again. If
-- the stale entries were pruned before relocation, the contents string would be
-- gone from caches and held only in a local that dies with the error. Model
-- that with the likeliest real culprit: box_in_valid_map, which reads the game
-- graph bare while screening candidates.
tm.caches[104] = nil
caches_count = 0
enroll(100); enroll(101)
enroll(200); tm.caches[200] = LOOT_E
spots[200] = { treasure = "Stash" }

local real_valid_map = tm.box_in_valid_map
tm.box_in_valid_map = function(id) error("game graph read failed", 2) end

fresh = loadfile(SCRIPT)
setfenv(fresh, env)
fresh()
env.on_game_start()
local ok = pcall(callbacks["actor_on_first_update"])
tm.box_in_valid_map = real_valid_map

check("the failing sweep did raise", not ok)
check("loot is still in the pool after a sweep that threw",
    tm.caches[200] == LOOT_E or holder_of(LOOT_E) ~= nil,
    "200=" .. tostring(tm.caches[200]) ..
    " holder=" .. tostring(holder_of(LOOT_E)))

-- ...and a later load, with the graph working again, still repairs it.
fresh = loadfile(SCRIPT)
setfenv(fresh, env)
fresh()
env.on_game_start()
callbacks["actor_on_first_update"]()
check("the next sweep completes the repair the failed one started",
    tm.caches[200] == nil and holder_of(LOOT_E) ~= nil,
    "landed on " .. tostring(holder_of(LOOT_E)))

-- ---- debug flags ------------------------------------------------------------
-- Both flags default to on and a normal install never writes them, so the whole
-- risk here is the off path silently not taking: a kill switch that looks set but
-- isn't would make every A/B measurement taken with it wrong, and quietly.
--
-- The env has carried no axr_main until now, which is itself the first case:
-- every scenario above ran through the `not (axr_main and axr_main.config)`
-- fallback and behaved normally, so the absent-config default is already covered.
local cfg = {}
env.axr_main = {
    config = {
        -- Same contract as ini_file_ex (_g.script:1613-1633): an absent key
        -- returns the caller's default, a present one returns the stored value.
        r_value = function(_, s, k, _typ, def)
            local v = cfg[s .. "&" .. k]
            if v == nil then return def end
            return v
        end,
        w_value = function(_, s, k, val) cfg[s .. "&" .. k] = val end,
        save = function() end,
    },
}

local function reset_pool_with_one_orphan(loot)
    for id in pairs(tm.caches) do tm.caches[id] = nil end
    spots[200] = nil
    caches_count = 0
    enroll(100); enroll(101)
    enroll(200); tm.caches[200] = loot
    spots[200] = { treasure = "Stash" }
    enroll(201)                          -- second stale entry, deliberately empty
end

local function reload()
    local c = loadfile(SCRIPT)
    setfenv(c, env)
    c()
end

-- autosweep = false: the load-time sweep is skipped, and `swept` is left clear,
-- so the pool is still repairable on demand rather than marked done. That last
-- part is what makes the flag useful rather than just destructive.
local LOOT_F = "svd,ammo_762x54_7h1"
reset_pool_with_one_orphan(LOOT_F)
cfg["stashfix&autosweep"] = false
log_before = #log
reload()
env.on_game_start()
callbacks["actor_on_first_update"]()

check("autosweep=false leaves the stale entry in place", tm.caches[200] == LOOT_F)
check("autosweep=false says so, loudly", (function()
    for i = log_before + 1, #log do
        if string.find(log[i], "autosweep is OFF", 1, true) then return true end
    end
    return false
end)())
-- Probe with the empty stale entry, not the one holding loot: a point-of-use
-- refusal drops the entry outright (the documented no-substitution behaviour),
-- which would bin LOOT_F before the deferred sweep ever got to relocate it.
check("autosweep=false still installs the point-of-use hooks",
    tm.set_random_stash(nil, "h", nil, 201) == nil and tm.caches[201] == nil,
    "a non-box was accepted")

-- ...and the deferred repair still works when asked for.
check("debug_force_sweep repairs a pool autosweep left alone",
    env.debug_force_sweep() == true and tm.caches[200] == nil
    and holder_of(LOOT_F) ~= nil,
    "200=" .. tostring(tm.caches[200]) .. " holder=" .. tostring(holder_of(LOOT_F)))

-- enabled = false: nothing at all. No wrappers, no sweep, and a manual sweep is
-- refused too, since repairing with the hooks absent is a state no real install is
-- ever in, so anything measured from it would be measuring a fiction.
local LOOT_G = "wpn_val,ammo_9x39_pab9"
reset_pool_with_one_orphan(LOOT_G)
cfg["stashfix&autosweep"] = nil
cfg["stashfix&enabled"] = false

local get_before, set_before = tm.get_random_stash, tm.set_random_stash
local cb_before = callbacks["actor_on_first_update"]
log_before = #log
reload()
env.on_game_start()

check("enabled=false does not wrap get_random_stash", tm.get_random_stash == get_before)
check("enabled=false does not wrap set_random_stash", tm.set_random_stash == set_before)
check("enabled=false registers no sweep callback",
    callbacks["actor_on_first_update"] == cb_before)
check("enabled=false says so, loudly", (function()
    for i = log_before + 1, #log do
        if string.find(log[i], "DISABLED by debug flag", 1, true) then return true end
    end
    return false
end)())

local swept_ok, swept_why = env.debug_force_sweep()
check("enabled=false refuses a manual sweep too",
    swept_ok == false and tm.caches[200] == LOOT_G,
    tostring(swept_why))

-- ...and clearing the flag brings everything back.
cfg["stashfix&enabled"] = nil
reload()
env.on_game_start()
callbacks["actor_on_first_update"]()
check("clearing the flags restores normal behaviour",
    tm.caches[200] == nil and holder_of(LOOT_G) ~= nil,
    "200=" .. tostring(tm.caches[200]) .. " holder=" .. tostring(holder_of(LOOT_G)))

print("\n--- log ---")
for i = 1, #log do print("  " .. log[i]) end
print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILURE(S)"))
os.exit(fails == 0 and 0 or 1)

# Fix Stale Stash IDs

Stops Anomaly attaching loot and a map marker to an object that is not a stash. The
marker cannot be opened and never goes away. Also repairs saves that already carry
one.

It patches at runtime and overrides no files. Two scripts, one of them debug-only.

## Scope and line numbers

The bug is stock Anomaly 1.5.3. It needs no mods to occur and every campaign starts
with three of them.

Line numbers are vanilla, from `tools\_unpacked\scripts`. A mod that overrides one
of these files will renumber it. Find the function by name instead. Everything
hooked is vanilla: one callback and three wrappers on `treasure_manager`, nothing
else.

## The bug

`treasure_manager` holds its candidate pool in `caches`, keyed by server object ID.
`on_game_load` (`:626`) builds it once, walking IDs `1..65534` and enrolling every
object `IsInvbox` accepts (`:640`), guarded by `if (caches_count > 0) then return
end`. An available box is stored as `false` (`:643`; the comment at `:299` says so
outright). `release_stash_by_id` (`:602-607`) guards on the value, not the key:

```lua
function release_stash_by_id(id)
	if id and caches[id] then      -- false for every available box
		caches[id] = nil
		caches_count = caches_count - 1
	end
end
```

So the one thing it exists to remove is the one thing it declines to touch. Its
single caller is `game_setup.script:411-419`, which releases everything named in
`new_game_setup.ltx` `[remove_objects]` and calls the pruner for the inventory boxes
among them. Three of those 146 entries are boxes: `esc_treasure_5`,
`dark_valley_treasure_9` and `val_q2_n`.

Ordering makes it certain rather than occasional. `load_state` runs from the engine's
`CALifeStorageManager_load` before `on_game_load` is sent from `bind_stalker_ext:61`,
so `caches_count` is already positive on a load and the walk only ever happens on a
new game. `game_setup` releases the three boxes moments later on
`actor_on_first_update`, and the prune does nothing. Every campaign starts with three
entries pointing at IDs the engine has already taken back.

The engine treats an ID as a slot handle, not an identity. `xrServer::entity_Destroy`
returns it to a free pool (`xrServer.cpp:873`, `id_generator.h:106`) and it is
reissued later, so a stale entry eventually names a live object that is not a box.
Reuse is not uniform. The generator is 256 blocks of 256 IDs and takes from the block
with the oldest free timestamp (`xrServer.h:144-155`, `id_generator.h:35-38,101`),
which is why this is rare rather than constant. A box cannot be destroyed any other
way: `CInventoryBox` is a plain `CGameObject` with no `CPHDestroyable` or
`CDamageManager` (`InventoryBox.h:6`), so only an explicit script release frees one.

Nothing downstream checks class. `get_random_stash` self-heals an ID whose object is
*gone* (`:320-325`), which is why the bug needs a recycled ID rather than merely a
released one, but its class filter is opt-in on `inv_box` (`:288-296`) and almost no
caller sets it. `set_random_stash` checks nothing at all: it fetches the object only
to read `m_game_vertex_id` for tiering, then writes the contents string and adds the
map spot. Reserve-now-apply-later callers widen the window further: a PDA contact
message picks an ID and stores it in the save, and `set_random_stash` does not run
until the player opens that message.

Once a marker lands on a non-box it is permanent. `try_spawn_treasure` (`:512`) only
runs from `physic_object_on_use_callback`, gated on `IsInvbox` (`:708-711`), so the
loot never spawns and the spot is never removed.

## Save game evidence

Audited on a real save. The profile has a large modlist, so the pool is bigger than
vanilla's: of 1182 entries cross-referenced against the `.scop` alife registry, 1179
were genuine inventory boxes and 3 were stale, all reissued to items in Dead City
merc inventories.

| ID | was | is now | inside | state |
|---|---|---|---|---|
| 10302 | `dark_valley_treasure_9` | `ground_coffee` | merc medic | available |
| 10330 | `val_q2_n` | `cooking` | merc mechanic | holding loot + a live `treasure` marker |
| 15694 | `esc_treasure_5` | `ammo_7.62x25_ps` | merc trader | available |

Three stale entries, three boxes in `[remove_objects]`, one to one. The count is
established by class, not by reading names. An ID can only be in `caches` if
`IsInvbox` accepted it when the pool was built, so `caches` membership *is* the class
test: the boxes `game_setup` released are the 3 stale entries plus the 0 entries whose
ID is absent from the registry.

The registry holds 1194 boxes, 15 more than the pool. Those 15 are exactly the 15
names in `treasure_manager.ltx` `[blacklist_stashes_names]`, which `on_game_load`
skips at `:642`. So the pool is fully accounted for, and nothing could have been
released without first being enrolled.

Which box each stale ID *was* follows from the registry. Within a run of consecutive
box IDs, all.spawn allocates in name order, so 15694 sits between `esc_treasure_4`
(15693) and `esc_treasure_6` (15695), 10302 follows `dark_valley_treasure_8` (10301),
and 10330 sits between `val_q1_n` (10329) and `val_q3_t_a` (10331). Neighbours alone
would not settle it. Boxes are interleaved with other objects, so a gap between two
boxes need not have held one. It is `caches` membership that proves each was a box,
and the name-sorted gap that says which.

## What this mod does

One callback and three wrappers. The numbers are used in the script's comments too:

| | |
|---|---|
| (1) | the sweep, on `actor_on_first_update` |
| (2) | `treasure_manager.get_random_stash` |
| (3) | `treasure_manager.set_random_stash` |
| (4) | `treasure_manager.release_stash_by_id` |

1. Walks the pool once per session and drops every entry whose ID is no longer an
   inventory box, clearing any bogus map spot with it. An entry that was holding
   loot has its contents and marker moved onto a real box first, preferring the
   level the bogus marker was on. This is what repairs an existing save.

   Relocation writes `caches` directly rather than re-entering `set_random_stash`,
   so the contents string moves across byte for byte with nothing re-rolled and no
   news fired. The hint is rebuilt from the new box's own strings, which costs a
   relocated `treasure_unique` its bespoke text. It runs before pruning, so a
   failure mid-sweep cannot lose a contents string that has already left the table.

2. Validates the ID base drew, so a caller can never receive a non-box. A bad draw
   is dropped and redrawn with `inv_box` forced on. Forcing that filter on every
   call instead would cost far more: base's filter block runs before the cheap
   availability test (`:288-299`), so it pays `alife_object` + `clsid` + `name` for
   the whole pool including the filled entries the next line discards. Checking the
   one ID that came back is a single lookup.

3. Refuses an ID that is not a box before it can attach loot or a marker, and drops
   the entry. This is what covers the reserve-now-apply-later callers. It also
   refuses a real box whose `m_game_vertex_id` would not survive the graph read at
   `:372`, which is guarded against a missing object but not a bad vertex. That
   refusal keeps the entry, because the box belongs in the pool.

4. Makes the pruner able to prune. Promoting a present-but-`false` value to `true`
   before delegating is the whole fix: the vanilla body then removes the key and
   decrements its own file-local `caches_count`, which no wrapper can do directly.

   This is the only hook that changes behaviour on a well-formed call: one that is a
   silent no-op in vanilla now removes the entry, which is what every caller is
   asking for, including `game_setup`'s "Clear inventory boxes from their manager".
   (2) and (3) diverge from base only when handed an ID that is not a box, which is
   exactly where base produced the bug.

   It earns its place over leaving this to (1) because of ordering. Both run on
   `actor_on_first_update`, and `axr_main` stores intercepts as
   `intercepts[name][fn] = true`, keyed by the function object, so their order is
   unspecified. If (1) runs first on a new game it reports a clean pool and the
   entries `game_setup` then seeds survive the session. Fixing the pruner removes the
   entry at the moment of release instead.

Everything disables itself if `treasure_manager` is missing or has an unexpected
shape.

## Known limits

- A refusal at (3) does not substitute a fresh stash, so that reward is not issued.
  Nothing obtainable is lost, since the alternative was a marker on an object that
  cannot be opened, and the contents string is printed to the log so it can be
  restored by hand. Draws through (2) lose nothing at all. On the PDA contact path
  the miss is permanent, since `ui_pda_npc_tab` discards the return value and sets
  `stash_read = true` regardless (`:696-701`).
- (2) cannot screen a bad game vertex. `get_random_stash` dereferences the drawn
  object's `m_game_vertex_id` bare at `:328` and `box_in_valid_map` does the same for
  every candidate at `:597`, both before the wrapper sees a return value, so a real
  box carrying a stale or 65535 vertex still faults inside the base function. That is
  stock behaviour. The sweep leaves such entries in the pool because they belong
  there, and `stashfix audit` counts them separately as `bad-vertex`.

## Load order

Anywhere. `zzz_aaa_stash_stale_id_fix.script` is a filename no other mod ships, so it
cannot lose a file conflict at any priority.

Wrapping happens in `on_game_start` rather than at file scope so it lands on top of
anything that patched `treasure_manager` at load time. `axr_main.on_game_start` loads
every script before calling any of their `on_game_start`s
(`axr_main.script:307-327`), so file-scope wrappers are all in place by then, and
outermost is where the validation has to be. The loop does not load anything
explicitly: it reads `_G[file_name]` to test for an `on_game_start`, and that read is
the load, because `_G` carries a lazy-load `__index` calling `process_file_if_exists`
on a miss (`script_engine.cpp:348,356`).

The name does not secure that. Dispatch is alphabetical by filename and plenty of
scripts sort after `zzz_aaa_`, so the prefix buys uniqueness rather than lastness.

## Install

Drop `gamedata` into a mod folder, or for a dev checkout link the repo in as an MO2
mod:

```powershell
.\scripts\link-mo2-mod.ps1 -ModsDir "<your MO2 mods folder>"
```

Creates a junction so the working copy is playable without copying files. Refresh
MO2 (F5) and enable `[DEBUG] anomaly-fix-stale-stash-ids` in the left pane (the name
follows the repo folder). Add `-Remove` to undo it.

## Verifying

The log reports what the sweep found, and reports on a healthy save too, so a clean
pool is distinguishable from the mod not being loaded:

```
~ STASHFIX| moved orphaned stash loot: id 10330 (cooking inside cit_killers_merc_mechanic_stalker) -> id 14372 (inventory_box)
~ STASHFIX| swept stash pool: 1182 entries checked, dropped 3 stale entries, relocated 1 of 1 bogus stash
~ STASHFIX| swept stash pool: 1182 entries checked, no stale ids
```

If you see neither line, it is not running. Check the profile, not just the mods
folder.

```
luajit tests/test_stashfix.lua
```

60 assertions against a stubbed Anomaly API: the wrappers and their multi-value
pass-through, the sweep, relocation and its level preference, map spot cleanup,
`caches_count` bookkeeping, refusal of a real box with an unusable game vertex, both
debug flags, and the `-keep_lua` path where `on_game_start` runs twice on one Lua
state. The `release_stash_by_id` set pins the vanilla defect directly by calling the
unwrapped stub and asserting it does nothing. Two tests are regression guards rather
than coverage: the graph stub errors on an out-of-range vertex the way the engine's
unchecked read would misbehave, so a missing bounds check fails the suite instead of
passing quietly, and one injects a failure into `box_in_valid_map` mid-sweep to
assert the loot survives, which fails if relocation and pruning are swapped back. The
suite takes an optional script path as `arg[1]`.

## In-game debug console

`zzz_stashfix_debug.script` adds a `stashfix` command to the F7 debug menu's console,
inert unless the game was launched with `-dbg`. It registers by assigning into the
table `debug_cmd_list.command_get_list()` hands out, so no UI or XML is overridden.

| Command | |
|---|---|
| `stashfix audit` | walk `treasure_manager.caches`, classify every entry |
| `stashfix list [page]` | detail lines for the problem entries only |
| `stashfix blocks` | stale ids bucketed by 256-id generator block |
| `stashfix status` | hooks, flags, last sweep, staged repro |
| `stashfix autosweep on\|off` | off = do not repair on load, so the audit can see the damage |
| `stashfix fix on\|off` | off = whole mod inert, for measuring a save without it |
| `stashfix sweep` | run the repair on demand |
| `stashfix probe [n]` | is this save recycling id space at all |
| `stashfix arm` / `check [n]` / `disarm` | stage and fire a real recycling repro |

Everything goes to the xray log as well as the console, which holds 27 lines and
cannot fit a ~1200-entry pool. `audit`, `list`, `blocks` and `status` only read, so
they are safe on a live save, and they work with the fix uninstalled, which is how to
measure what it is worth.

### Flags

The sweep runs on `actor_on_first_update`, long finished by the time the console can
be opened, so on a repaired save `audit` reports a clean pool. That is correct but
useless, because a save that was never broken looks identical. Two flags in
`[stashfix]` in `axr_options.ltx` deal with that, both defaulting to on so a normal
install never writes them. Both are read at load, so set one and reload.

`autosweep off` defers the repair while leaving the point-of-use hooks on, so nothing
can attach a stash to a recycled ID while the pool is inspected. The log says loudly
on every load that it is off, because an unrepaired pool that looks repaired is the
one way this could quietly cost someone a stash.

```
stashfix autosweep off      (then reload)
stashfix audit              -- the real damage
stashfix list               -- what each broken entry actually became
stashfix sweep              -- repair on demand
stashfix autosweep on       (then reload)
```

`fix off` makes the whole mod inert, no hooks and no sweep, for measuring a save as it
would be without it while keeping the console. A manual `sweep` is refused in that
state, since repairing with the hooks absent is a configuration no real install is in.

`status` and `audit` also report what the last sweep did, which answers the same
question without a reload.

### The repro

`arm` spawns real `inventory_box` objects, enrols them in `caches` the way
`on_game_load` would, and frees them. `check` burns IDs until the allocator hands one
back, as a loaf of bread, with the pool still listing that ID as an empty stash. Do
not save and reload between the two: loading builds a fresh generator via
`clear_ids()` (`xrServer.h:172-175`), resetting every block timestamp.

Both depend on a release actually freeing the ID. `alife():release()` frees
immediately only when the object is offline (`alife_simulator_script.cpp:298-302`);
given an online object it posts a `GE_DESTROY` event and never touches the generator,
so churn spawned at the actor's feet frees nothing. These commands spawn on another
level, where objects are created offline and released on the spot. On a real save:

```
arm   := 8 x inventory_box spawned offline, enrolled, released
         blocks : 8 distinct
check := REPRODUCED after 184 ids -- id 42501 (bread)
         caches[42501] = false
```

184 IDs through 184 distinct blocks is one per block, the allocator stepping forward
as described, with the armed block coming up on the first pass.

`probe` is the sanity check to run first: it burns a few IDs and reports how many
distinct blocks they came from. Several blocks means frees are landing. One block
means IDs are not being freed and nothing else here will work.

`arm`, `check`, `probe` and `disarm` spawn objects and write to the pool. Every object
is offline, on another level, and destroyed as soon as its ID has been read, but `arm`
leaves entries in `caches` until `disarm` runs. Use them on a save you are willing to
lose.

## Licence

AGPL-3.0. See `LICENSE`.

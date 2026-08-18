# MS Leveling 2 - User Manual (v2.07)

Raid manager for Manastorm leveling groups (15 players, ready check, auto-invite,
group sorting, anti-leech, auto Manastorm entry).

## Install

1. Unzip the release into `Interface\AddOns\` so you end up with `Interface\AddOns\MSLeveling 2\`.
2. `/reload` (or restart the game).
3. Open the panel with `/mslv` (or `/msl2`, `/ms201b`).

## Composition

The addon manages up to **15 players**: 2 Tanks, 3 Heals, 10 DPS, 3 Auras.

## Quick start (basic flow)

1. **Load Raid** - starts a count: members reply in raid chat with `1` (Tank), `2` (Heal), `3` (Aura), e.g. `1 3`. No reply = DPS without aura.
2. **Finish Count** - saves everyone's role/aura.
3. **Sort Groups** - automatically places tanks/heals/auras into balanced groups.
4. When a level 59 hits 60, the addon warns the raid with their role and removes them.

## Panel buttons

| Button | What it does |
|---|---|
| **Post LFM** | Posts the "looking for more" message to your selected channels once. |
| **AutoSPAM-LFM (30s)** | Re-posts the LFM message every 30 seconds. |
| **AutoInviteLFG** | Auto-invites from your selected LFG channels (message must say LFG/LF + MS leveling/Manastorm + a role). |
| **AutoReply** | Auto-replies to whispers with your queue/reject messages. |
| **AutoInviteWhisper** | Auto-invites players who whisper their role/aura when there is room. |
| **Load Raid** | Starts a ready/count cycle (see Quick start). |
| **Finish Count** | Saves everyone's roles after the count. |
| **Sort Groups** | Balances the raid groups (tanks/heals/auras first). |
| **Update raid** | Removes leavers / frees weekly slots. |
| **Reset all data** | Clears candidates, invited list and replies. |
| **Mark MT buttons** | Click a tank's button to set them as Main Tank (uses `/maintank`). |
| **Channel buttons (1-3)** | Click to set which chat channels are used for LFM/LFG. |

## Feature buttons

- **Ready Check** - sends a raid ready check.
- **Enter MS 1** - enters the Manastorm Level 1 automatically (tries `C_Manastorm`, falls back to the in-game panel).
- **Disband+Re-inv** - disbands the raid, waits until out of the dungeon, and re-invites everyone with their saved roles (announces via raid warning).
- **Anti-leech** - tracks who actually deals damage/heals. Opens the warning panel with suspicious players.

## Automatic behaviors

- When the raid reaches 15/15, it announces "Last invite sent, waiting for them to accept before sorting the groups." and **sorts automatically when the last player accepts**.
- Auto-invites are blocked (with a whisper to the player) if the group is full or you are **inside a Manastorm**.
- Level 59 members who hit 60 are announced with their role and removed from the group.
- Players with no damage/healing for 45+ seconds are flagged as idle.

## Slash commands

| Command | What it does |
|---|---|
| `/mslv` (or `/msl2`, `/ms201b`) | Toggle the main panel. |
| `/mslv reset` | Reset all data. |
| `/mslv lfm` | Post the LFM message once. |
| `/mslv raid` | Start the ready/count cycle. |
| `/mslv enter` | Enter Manastorm Level 1. |
| `/mslv entersave <name>` | Save a custom enter button name. |
| `/mslv rw` (or `/ms201rw`) | Announce idle players via raid warning. |
| `/mslv api` | Debug: prints Manastorm API info. |
| `/msw` (or `/mswarnings`) | Toggle the Leech / 59+ Warnings panel. |

## Whisper format for players

To sign up by whisper: **"tank aura"**, **"heal no aura"**, **"dps"**, etc.
The LFG channel message should include: LFG/LF + MS leveling/Manastorm + role/aura.

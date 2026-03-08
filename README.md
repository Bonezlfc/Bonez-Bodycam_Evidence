# bonez-bodycam_evidence

Court-grade bodycam evidence recording and playback addon for [Bonez-Bodycam](https://github.com/Bonezlfc/Bonez-Bodycam).

Clips are recorded automatically based on active ERS events and weapon discharge. Video is encoded in the client and uploaded to [Fivemanage](https://fivemanage.com). Authorized staff can search, watch, and manage footage through an in-game evidence viewer — no external tools required.

---

## How It Works With Bonez-Bodycam

`bonez-bodycam_evidence` is an **addon** that sits on top of `Bonez-Bodycam`. It does not replace it — both resources must run together.

| Resource | Role |
|---|---|
| **Bonez-Bodycam** | Renders the on-screen overlay; provides the player's unit ID; toggles the overlay on/off when evidence recording starts and stops |
| **bonez-bodycam_evidence** | Watches ERS state and weapon events; triggers video recording; uploads clips to Fivemanage; provides the in-game evidence browser |

When a recording trigger fires, this resource calls `exports['Bonez-Bodycam']:setOverlayEnabled(true)` so the bodycam overlay is visible during the recorded footage. When recording ends, the overlay returns to its normal ERS-driven state.

---

## Requirements

| Dependency | Notes |
|---|---|
| [`Bonez-Bodycam`](../Bonez-Bodycam/README.md) | Required — overlay and unit ID source |
| [`night_ers`](https://store.nights-software.com/category/ersgamemode) | Required — callout and tracking state |
| [`NativeUI`](https://github.com/FrazzIe/NativeUILua) | Required — in-game evidence browser menu |
| [`oxmysql`](https://github.com/overextended/oxmysql) | **Optional but strongly recommended** — persistent MySQL storage; without it clips are stored in server KVP and are lost on resource restart |
| [Fivemanage](https://fivemanage.com) | Required — video hosting; you need an account and a Video API key |

---

## Installation

### 1. Install Bonez-Bodycam first

Follow the [Bonez-Bodycam installation guide](https://github.com/Bonezlfc/Bonez-Bodycam/blob/main/README.md). Both resources must be configured and running before this addon will work.

### 2. Copy the resource

Drop the `bonez-bodycam_evidence` folder into your server's `resources` directory.

### 3. Add to server.cfg

```
ensure Bonez-Bodycam
ensure night_ers
ensure NativeUI
ensure oxmysql          # optional but strongly recommended
ensure bonez-bodycam_evidence
```

`bonez-bodycam_evidence` **must start after** all of its dependencies. If `Bonez-Bodycam` is not running when this resource starts, evidence recording will not work.

### 4. Set your Fivemanage API key

Open `server/apiKeys.lua` and paste your key:

```lua
ApiKeys.Fivemanage = 'YOUR_FIVEMANAGE_VIDEO_API_KEY_HERE'
```

To get a key:
1. Go to [fivemanage.com/dashboard](https://fivemanage.com/dashboard)
2. Navigate to **API Keys** → **Create Key**
3. Set the type to **Video** (Video and Image keys are separate — make sure you pick Video)
4. Copy and paste the key above

> **Keep this key private.** If it leaks, regenerate it immediately in the Fivemanage dashboard.

### 5. Configure job permissions

Open `config.lua` and set your job names. These must exactly match what your framework (ESX or QBCore) returns — both are auto-detected:

```lua
-- Players with these jobs can VIEW evidence clips
Config.AuthorizedJobs = {
    'police',
    'da',
}

-- Players with these jobs can also DELETE clips
Config.AdminJobs = {
    'admin',
}
```

> **Note:** Players with the txAdmin `command` ACE permission always have full admin access regardless of job.

### 6. Set your service type

In `config.lua`, choose one of the provided options for `Config.GetServiceType`. The simplest is Option A — just replace the placeholder with your department name:

```lua
Config.GetServiceType = function()
    return 'POLICE'   -- shown on every clip record
end
```

### 7. (Optional) Set up MySQL

If `oxmysql` is running, the `bodycam_evidence` table is created automatically on first start — no manual SQL needed. Without `oxmysql`, clips are stored in server KVP and will be lost on resource restart.

---

## Configuration Reference

All settings are in `config.lua`.

| Setting | Default | Description |
|---|---|---|
| `Config.Debug` | `false` | Print state transitions and upload events to the F8 / txAdmin console. |
| `Config.DefaultKey` | `F9` | Default keybind to open the evidence menu. Players can rebind in FiveM Settings → Key Bindings. |
| `Config.MenuCommand` | `evidence` | Chat command to open the evidence menu. |
| `Config.ERSPollInterval` | `500` | Milliseconds between ERS state polls. |
| `Config.TrackingCooldown` | `60` | Seconds of grace period after tracking ends before the clip is finalized. If tracking resumes within this window, recording continues. |
| `Config.WeaponClipDuration` | `60` | How long (seconds) a weapon-discharge clip records before auto-stopping. |
| `Config.ClipsPerUnit` | `20` | Maximum clips stored per unit. Oldest clips are automatically deleted (from both the database and Fivemanage) when exceeded. |
| `Config.UnitIdentifierType` | `discord` | Which player identifier to tag clips with. Options: `fivem`, `discord`, `license`, `steam`, `xbl`, `live`. |
| `Config.AuthorizedJobs` | see file | Jobs that can view evidence. |
| `Config.AdminJobs` | see file | Jobs that can delete evidence. |

---

## How Recording Works

Clips are triggered automatically — no player action required. The player must be **on shift** in ERS for any trigger to fire.

### Trigger 1 — Callout (highest priority)

Recording starts when a unit is attached to a callout in ERS. It stops when the unit detaches. If a weapon or tracking clip is already recording, it is immediately finalized and a new callout clip begins.

### Trigger 2 — Unit Tracking

Recording starts when a unit begins tracking another unit in ERS. A `TrackingCooldown` grace period (default 60 s) applies after tracking ends — if tracking resumes within the window, recording continues uninterrupted. After the cooldown, the clip is finalized.

### Trigger 3 — Weapon Discharged

Recording starts the moment a player fires a weapon (while on shift, with no higher-priority recording active). The clip runs for `WeaponClipDuration` seconds (default 60 s) then finalizes automatically. The trigger cannot fire again until the player fully releases their trigger.

### Recording pipeline

1. A clip record is created in the database with status `PENDING`
2. The NUI captures the game framebuffer via `CfxTexture` — no stutter, no GPU readback
3. Video is encoded to WebM using the browser's built-in `MediaRecorder`
4. A presigned upload URL is obtained from Fivemanage (API key stays server-side, never touches clients)
5. The encoded file is uploaded directly to Fivemanage
6. The database record is updated to `UPLOADED` with the video URL

---

## Using the Evidence Viewer

Open the menu in-game with the keybind (default **F9**) or the chat command (default `/evidence`).

### Menu flow

1. **Search by Unit ID** — enter the unit's identifier to load their clips
2. **Browse Clips** — lists all clips for that unit, newest first, with trigger type, date, and status
3. Select a clip → **Watch Footage** — opens the fullscreen viewer with the video and clip metadata
4. **Export Clip Info to Chat** — prints clip metadata to your local chat log
5. **[Admin] Delete Clip** — permanently removes the clip from the database and Fivemanage

### Clip statuses

| Status | Meaning |
|---|---|
| `PENDING` | Clip created but recording has not finished |
| `PROCESSING` | Recording complete; video is uploading |
| `UPLOADED` | Video is available for playback |
| `ABANDONED` | Recording was interrupted before any footage was captured |
| `NO_FRAMES` | Recording completed but no footage was produced |
| `NO_RETRY` | Upload failed and cannot be retried (e.g. server restarted mid-recording) |

---

## File Structure

```
bonez-bodycam_evidence/
  config.lua              -- job permissions, triggers, unit ID type
  fxmanifest.lua
  shared/
    util.lua              -- shared helper functions (UUID, formatting, etc.)
  client/
    recorder.lua          -- NUI capture start/stop wrappers
    viewer.lua            -- evidence viewer NUI callbacks
    main.lua              -- ERS polling, trigger state machine, keybinds
  server/
    apiKeys.lua           -- Fivemanage API key (fill this in, keep it private)
    upload.lua            -- Fivemanage HTTP delete adapter
    storage.lua           -- MySQL / KVP dual-backend clip storage
    video.lua             -- video deletion wrapper
    main.lua              -- clip lifecycle events, authorization, retry logic
  html/
    index.html            -- evidence viewer NUI (hub + player pages)
    style.css
    script.js
    cfx_renderer.js       -- CfxTexture frame capture
  module/                 -- bundled Three.js (required by cfx_renderer.js)
```

---

## Troubleshooting

**Clips are not being created**
- Confirm `Bonez-Bodycam`, `night_ers`, and `NativeUI` are all running before `bonez-bodycam_evidence`
- Confirm the player is **on shift** in ERS — no trigger fires off-shift
- Enable `Config.Debug = true` and check the F8 console for `[BCE]` state messages

**Video says "No footage" / status stays PENDING**
- Check the F8 / txAdmin console for upload errors
- Confirm `ApiKeys.Fivemanage` in `server/apiKeys.lua` is a valid **Video** type key (not Image)
- Check your Fivemanage dashboard to confirm the key is active

**Clips are lost after server restart**
- Install and ensure `oxmysql` — without it, clips are stored in server KVP and are not persistent

**"bonez-bodycam not detected" on screen**
- `Bonez-Bodycam` must start before this resource — check your `server.cfg` ensure order

**Players can't open the evidence menu**
- Check their job name matches an entry in `Config.AuthorizedJobs` exactly (case-sensitive)
- txAdmin `command` ACE permission always grants access as a fallback

---

## Credits

- **Bonez Workshop** — script author
- [Fivemanage](https://fivemanage.com) — video hosting platform
- [FrazzIe/NativeUILua](https://github.com/FrazzIe/NativeUILua) — in-game menu library
- [overextended/oxmysql](https://github.com/overextended/oxmysql) — MySQL storage backend

-- bonez-bodycam_evidence | config.lua
-- Shared configuration. API keys → server/apiKeys.lua (server-side only).

Config = {}

-- ── Debug ──────────────────────────────────────────────────────────────────
-- Set to true to print state transitions and upload events to the F8 / txAdmin console.
-- Leave false on production.
Config.Debug = true

-- ── Keybind ────────────────────────────────────────────────────────────────
Config.DefaultKey   = 'F9'       -- Default key for /evidence command (rebindable in FiveM Settings)
Config.MenuCommand  = 'evidence' -- In-game chat command to open the evidence system

-- ── Manual Recording ────────────────────────────────────────────────────────
-- The manual record key (default F10) ALWAYS works regardless of ManualRecordingMode.
-- Use it to record traffic stops, interviews, or any situation that isn't a callout.
--
-- Config.ManualRecordingMode controls whether AUTO-TRIGGERS also fire:
--   false (default) — auto-triggers ON  + manual key ON  (recommended)
--   true            — auto-triggers OFF + manual key only (fully manual server)
Config.ManualRecordingMode = false
Config.ManualRecordCommand = 'evidencerec'  -- command name for manual start/stop
Config.ManualRecordKey     = 'F6'           -- default keybind (rebindable in FiveM Settings)

-- ── ERS polling ────────────────────────────────────────────────────────────
Config.ERSPollInterval = 500  -- ms between night_ers state polls

-- ── Recording triggers ─────────────────────────────────────────────────────
Config.TrackingCooldown   = 60  -- seconds of cooldown after tracking ends before finalizing (Trigger 2)
Config.WeaponClipDuration = 60  -- seconds a weapon-fired clip records before auto-stopping (Trigger 3)

-- ── Clip storage ───────────────────────────────────────────────────────────
Config.ClipsPerUnit = 20  -- max clips stored per unit ID; oldest are deleted when exceeded

-- ── Job permissions (validated server-side only) ───────────────────────────
-- Any player whose framework job name matches a value here can view evidence.
Config.AuthorizedJobs = {
    -- Add your framework's job name(s) here, e.g. 'police', 'sheriff', 'da'
}

-- Admin jobs — can delete clips in addition to viewing.
-- txAdmin / server ACE 'command' permission always grants admin access regardless.
Config.AdminJobs = {
    -- Add your framework's admin job name(s) here, e.g. 'admin', 'superadmin'
}

-- ── Unit identifier ────────────────────────────────────────────────────────
-- Which player identifier to tag clips with and search by in the hub.
-- The prefix is stripped before storing, so 'fivem:787929' is stored as '787929'.
--
--   'fivem'   — CFX.re account number  (e.g. 787929)       ← recommended, short & easy to type
--   'license' — Rockstar license key   (e.g. f02e5e4aba…)
--   'discord' — Discord user ID        (e.g. 313541362806947842)
--   'steam'   — Steam hex ID           (e.g. 1100001096ff9a3)
--   'xbl'     — Xbox Live ID
--   'live'    — Microsoft Live ID
Config.UnitIdentifierType = 'fivem'   -- 'fivem' | 'discord' | 'license' | 'steam'

-- ── Service type resolver ───────────────────────────────────────────────────
-- Returns a string label for the officer's current service/department.
-- This is stored with every clip for evidence records.
--
-- Uses the bonez-bodycam export which already handles priority:
--   ERS active service → player's manually-set service type → nil
Config.GetServiceType = function()
    local ok, svc = pcall(function() return exports['bonez-bodycam']:getActiveServiceType() end)
    return (ok and type(svc) == 'string' and svc ~= '') and svc or 'UNKNOWN'
end

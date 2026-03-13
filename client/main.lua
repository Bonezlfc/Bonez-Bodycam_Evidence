-- bonez-bodycam_evidence | client/main.lua
-- State machine, ERS polling, recording trigger detection, keybind.

-- ── State constants ────────────────────────────────────────────────────────
local STATE_IDLE       = 'IDLE'
local STATE_RECORDING  = 'RECORDING'
local STATE_COOLDOWN   = 'COOLDOWN'
local STATE_FINALIZING = 'FINALIZING'

-- ── State ──────────────────────────────────────────────────────────────────
local currentState   = STATE_IDLE
local currentTrigger = nil  -- 'CALLOUT' | 'TRACKING' | 'WEAPON_FIRED'

-- ERS cached values
local ersOnShift          = false
local ersAttachedCallout  = false
local ersTrackingUnit     = false

-- Previous-tick ERS values (for edge detection)
local prevAttachedCallout = false
local prevTrackingUnit    = false

-- Cooldown tracking (Trigger 2)
local cooldownActive    = false
local cooldownStartTime = 0

-- Weapon clip timer (Trigger 3)
local weaponTimerActive    = false
local weaponTimerStartTime = 0
-- Prevents a new WEAPON_FIRED clip from starting until the player stops shooting
local weaponResetRequired  = false

-- Dependency flags
local bodycamAvailable = false
local ersAvailable     = false

local awaitingClipId   = false

-- ── Helpers ────────────────────────────────────────────────────────────────

local function GetERSExport(name, fallback)
    local ok, val = pcall(function()
        return exports['night_ers'][name](exports['night_ers'])
    end)
    if ok then return val end
    return fallback
end

local function GetServiceType()
    local ok, svc = pcall(Config.GetServiceType)
    return (ok and type(svc) == 'string' and svc ~= '') and svc or 'UNKNOWN'
end

-- Requests server to create a clip record and returns the assigned clipId
-- via the 'bonez-bodycam_evidence:clipStartAck' event.
local function RequestClipStart(trigger, serviceType)
    awaitingClipId = true
    TriggerServerEvent('bonez-bodycam_evidence:startClip', trigger, serviceType)
end

-- ── Auto-overlay toggle ────────────────────────────────────────────────────
-- Calls the setOverlayEnabled export on bonez-bodycam so the HUD overlay
-- turns on when a callout or tracking session is active and off when both end.
-- Does NOT persist — bonez-bodycam's stub skips Settings.Save().

local overlayAutoState = nil  -- nil = never set, true/false = last set value

local function SetBodycamOverlay(state)
    if overlayAutoState == state then return end  -- skip if nothing changed
    overlayAutoState = state
    local ok = pcall(function()
        exports['bonez-bodycam']:setOverlayEnabled(state)
    end)
    DebugPrint('CLIENT', 'Auto-overlay ' .. (state and 'ON' or 'OFF') .. (ok and '' or ' (export unavailable)'))
end

-- ── State transitions ──────────────────────────────────────────────────────

local function TransitionToRecording(trigger)
    currentState   = STATE_RECORDING
    currentTrigger = trigger
    cooldownActive = false
    DebugPrint('CLIENT', 'STATE → RECORDING | trigger: ' .. tostring(trigger))
    -- Notify bonez-bodycam to play the "recording started" sound
    pcall(function() exports['bonez-bodycam']:playRecordSound(true) end)
    -- Recorder.Start is called once server ACKs with clipId (see event handler below)
    local svc = GetServiceType()
    RequestClipStart(trigger, svc)
end

local function TransitionToFinalizing()
    if currentState == STATE_IDLE or currentState == STATE_FINALIZING then return end
    DebugPrint('CLIENT', 'STATE → FINALIZING | was: ' .. tostring(currentState) .. ' trigger: ' .. tostring(currentTrigger))
    if currentTrigger == 'WEAPON_FIRED' then
        -- Require player to stop shooting before a new weapon clip can start
        weaponResetRequired = true
    end
    currentState   = STATE_FINALIZING
    currentTrigger = nil
    cooldownActive = false
    weaponTimerActive = false

    -- Notify bonez-bodycam to play the "recording stopped" sound
    pcall(function() exports['bonez-bodycam']:playRecordSound(false) end)

    Recorder.Stop()
    -- IDLE transition happens when server ACKs receipt (bonez-bodycam_evidence:chunksDone)
end

local function TransitionToCooldown()
    DebugPrint('CLIENT', 'STATE → COOLDOWN | tracking ended, waiting ' .. Config.TrackingCooldown .. 's')
    currentState   = STATE_COOLDOWN
    cooldownActive = true
    cooldownStartTime = GetGameTimer()
end

-- ── Cooldown ticker (runs on ERS poll thread) ─────────────────────────────
local function CheckCooldown()
    if not cooldownActive then return end
    if currentState ~= STATE_COOLDOWN then
        cooldownActive = false
        return
    end
    local elapsed = (GetGameTimer() - cooldownStartTime) / 1000
    if elapsed >= Config.TrackingCooldown then
        cooldownActive = false
        TransitionToFinalizing()
    end
end

-- ── Weapon clip timer (runs on weapon detection thread) ───────────────────
local function CheckWeaponTimer()
    if not weaponTimerActive then return end
    if currentState ~= STATE_RECORDING or currentTrigger ~= 'WEAPON_FIRED' then
        weaponTimerActive = false
        return
    end
    local elapsed = (GetGameTimer() - weaponTimerStartTime) / 1000
    if elapsed >= Config.WeaponClipDuration then
        weaponTimerActive = false
        TransitionToFinalizing()
    end
end

-- ── ERS change handler (called every poll tick) ────────────────────────────
local function HandleERSChanges()
    if not ersOnShift then return end

    -- ── Trigger 1: CALLOUT ─────────────────────────────────────────────────
    local calloutStarted = ersAttachedCallout and not prevAttachedCallout
    local calloutEnded   = not ersAttachedCallout and prevAttachedCallout

    if calloutStarted then
        -- Callout attached — highest priority
        if currentState == STATE_RECORDING and currentTrigger == 'WEAPON_FIRED' then
            -- Interrupt weapon clip, upload it, then start callout clip
            TransitionToFinalizing()
            -- A short delay lets finalize propagate before starting new clip
            -- New clip will start on next poll once state returns to IDLE
            -- We set a flag to auto-start CALLOUT once IDLE
            -- Handled in the poll loop below via pendingCalloutStart
        elseif currentState == STATE_RECORDING and currentTrigger == 'TRACKING' then
            -- Callout overrides tracking
            TransitionToFinalizing()
        elseif currentState == STATE_COOLDOWN then
            cooldownActive = false
            TransitionToFinalizing()
        elseif currentState == STATE_IDLE then
            TransitionToRecording('CALLOUT')
        end
    end

    if calloutEnded then
        if currentState == STATE_RECORDING and currentTrigger == 'CALLOUT' then
            TransitionToFinalizing()
        end
    end

    -- ── Trigger 2: TRACKING (only if not in CALLOUT) ───────────────────────
    if currentTrigger ~= 'CALLOUT' then
        local trackingStarted = ersTrackingUnit and not prevTrackingUnit
        local trackingEnded   = not ersTrackingUnit and prevTrackingUnit

        if trackingStarted then
            if currentState == STATE_IDLE then
                TransitionToRecording('TRACKING')
            elseif currentState == STATE_COOLDOWN then
                -- Tracking resumed — cancel cooldown, continue recording
                cooldownActive = false
                currentState   = STATE_RECORDING
            end
        end

        if trackingEnded then
            if currentState == STATE_RECORDING and currentTrigger == 'TRACKING' then
                TransitionToCooldown()
            end
        end
    end
end

-- ── ERS polling thread (500 ms) ────────────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(Config.ERSPollInterval)

        if GetResourceState('night_ers') ~= 'started' then
            ersAvailable = false
        else
            ersAvailable = true

            -- Snapshot previous
            prevAttachedCallout = ersAttachedCallout
            prevTrackingUnit    = ersTrackingUnit

            -- Read current
            ersOnShift         = GetERSExport('getIsPlayerOnShift',           false)
            ersAttachedCallout = GetERSExport('getIsPlayerAttachedToCallout', false)
            ersTrackingUnit    = GetERSExport('getIsPlayerTrackingUnit',       false)

            -- Auto-triggers only run when not in manual recording mode
            if not Config.ManualRecordingMode then
                HandleERSChanges()
                CheckCooldown()

                -- Auto-overlay: ON while on shift + (callout or tracking), OFF otherwise
                SetBodycamOverlay(ersOnShift and (ersAttachedCallout or ersTrackingUnit))
            end
        end

        -- If not on shift, don't hold an active recording, and kill the overlay
        if not ersOnShift and not Config.ManualRecordingMode then
            SetBodycamOverlay(false)
            if currentState ~= STATE_IDLE and currentState ~= STATE_FINALIZING then
                TransitionToFinalizing()
            end
        end
    end
end)

-- ── Weapon detection thread (per-frame, only in IDLE, only in auto mode) ──
Citizen.CreateThread(function()
    while true do
        if not Config.ManualRecordingMode and currentState == STATE_IDLE and ersOnShift and ersAvailable and bodycamAvailable then
            Citizen.Wait(0)
            local ped = PlayerPedId()
            if IsPedShooting(ped) then
                if not weaponResetRequired then
                    weaponTimerActive    = true
                    weaponTimerStartTime = GetGameTimer()
                    TransitionToRecording('WEAPON_FIRED')
                end
            else
                -- Player stopped shooting — allow a new WEAPON_FIRED clip
                weaponResetRequired = false
            end
        else
            -- Check weapon timer expiry (Trigger 3 active)
            if weaponTimerActive then
                CheckWeaponTimer()
            end
            Citizen.Wait(100)
        end
    end
end)

-- ── Server ACK: clip started — server provides clipId ─────────────────────
RegisterNetEvent('bonez-bodycam_evidence:clipStartAck')
AddEventHandler('bonez-bodycam_evidence:clipStartAck', function(clipId, trigger, serviceType)
    if not awaitingClipId then return end
    awaitingClipId = false

    if currentState == STATE_RECORDING then
        Recorder.Start(clipId, trigger, serviceType)
    else
        -- State changed before server replied — tell server to abandon this clip
        TriggerServerEvent('bonez-bodycam_evidence:abandonClip', clipId)
        -- Nothing was recorded, so no chunksDone will ever arrive — reset to IDLE now
        currentState   = STATE_IDLE
        currentTrigger = nil
    end
end)

-- ── Server ACK: all chunks received — return to IDLE ──────────────────────
RegisterNetEvent('bonez-bodycam_evidence:chunksDone')
AddEventHandler('bonez-bodycam_evidence:chunksDone', function()
    currentState   = STATE_IDLE
    currentTrigger = nil

    -- If a callout was pending (weapon clip was interrupted by callout), start it now
    if ersOnShift and ersAttachedCallout then
        TransitionToRecording('CALLOUT')
    end
end)

-- ── Keybind / command ─────────────────────────────────────────────────────
RegisterCommand(Config.MenuCommand, function()
    if Viewer.IsOpen() then
        Viewer.Close()
        return
    end
    Viewer.OpenHub()
end, false)

RegisterKeyMapping(Config.MenuCommand, 'Open Evidence System', 'keyboard', Config.DefaultKey)

-- ── Manual recording start / stop command ─────────────────────────────────
-- Only active when Config.ManualRecordingMode = true.

RegisterCommand(Config.ManualRecordCommand, function()
    -- Manual key always works regardless of ManualRecordingMode.
    -- ManualRecordingMode only controls whether auto-triggers fire.
    if not bodycamAvailable then
        DebugPrint('CLIENT', 'ManualRec pressed but bonez-bodycam unavailable')
        return
    end

    -- Allow stopping an active clip off-duty, but block starting a new one
    if currentState == STATE_IDLE and not ersOnShift then
        DebugPrint('CLIENT', 'ManualRec blocked — not on shift')
        return
    end

    if currentState == STATE_IDLE then
        -- Start a manual clip (e.g. traffic stop — no callout/tracking active)
        TransitionToRecording('MANUAL')
    elseif currentState == STATE_RECORDING or currentState == STATE_COOLDOWN then
        -- Stop the current clip (manual override — works on any trigger type)
        TransitionToFinalizing()
    end
end, false)

RegisterKeyMapping(
    Config.ManualRecordCommand,
    'Evidence: Start / Stop Recording',
    'keyboard',
    Config.ManualRecordKey
)

-- ── Exports ────────────────────────────────────────────────────────────────

-- Queried by bonez-bodycam every 500 ms to decide whether to show the overlay.
-- Returns true during RECORDING and COOLDOWN (clip is still live during cooldown).
exports('isRecording', function()
    return currentState == STATE_RECORDING or currentState == STATE_COOLDOWN
end)

-- Called by bonez-bodycam's overlay toggle (]) to start a MANUAL clip.
-- No-op if already recording or player is not on shift.
exports('startManualRecord', function()
    if not bodycamAvailable then return end
    if not ersOnShift then return end
    if currentState == STATE_IDLE then
        TransitionToRecording('MANUAL')
    end
end)

-- Called by bonez-bodycam's overlay toggle (]) to stop the current clip.
-- Works regardless of what trigger started it.
exports('stopManualRecord', function()
    if currentState == STATE_RECORDING or currentState == STATE_COOLDOWN then
        TransitionToFinalizing()
    end
end)

-- ── Resource init ─────────────────────────────────────────────────────────
AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    bodycamAvailable = GetResourceState('bonez-bodycam') == 'started'
    ersAvailable     = GetResourceState('night_ers') == 'started'

    if not bodycamAvailable then
        print('^1[bonez-bodycam_evidence] WARNING: bonez-bodycam is not running. Recording disabled.^0')
    end
    if not ersAvailable then
        print('^1[bonez-bodycam_evidence] WARNING: night_ers is not running. Recording disabled.^0')
    end
end)

-- Keep dependency flags updated as resources start/stop
AddEventHandler('onClientResourceStart', function(name)
    if name == 'bonez-bodycam' then bodycamAvailable = true end
    if name == 'night_ers'     then ersAvailable     = true end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name == 'bonez-bodycam' then
        bodycamAvailable = false
        if currentState ~= STATE_IDLE then TransitionToFinalizing() end
    end
    if name == 'night_ers' then
        ersAvailable = false
        if currentState ~= STATE_IDLE then TransitionToFinalizing() end
    end
end)

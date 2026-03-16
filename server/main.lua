---@diagnostic disable: undefined-global
-- bonez-bodycam_evidence | server/main.lua
-- Net event handlers, job auth, clip lifecycle.
-- API keys → server/apiKeys.lua | Upload provider → config.lua + server/upload.lua

-- ── Job auth helpers ──────────────────────────────────────────────────────

local function GetPlayerJob(src)
    -- Framework-agnostic: try ESX, then QBCore, then return nil
    -- ESX
    local esx = exports['es_extended']
    if esx then
        local ok, xPlayer = pcall(function() return esx:GetPlayerFromId(src) end)
        if ok and xPlayer then
            return xPlayer.getJob and xPlayer.getJob().name or nil
        end
    end
    -- QBCore
    local qb = exports['qb-core']
    if qb then
        local ok, QBCore = pcall(function() return qb:GetCoreObject() end)
        if ok and QBCore then
            local player = QBCore.Functions.GetPlayer(src)
            if player then
                return player.PlayerData and player.PlayerData.job and player.PlayerData.job.name or nil
            end
        end
    end
    return nil
end

local function IsAuthorized(src)
    -- txAdmin / server ACE admins always have access
    if IsPlayerAceAllowed(src, 'command') then return true end
    local job = GetPlayerJob(src)
    if not job then return false end
    for _, j in ipairs(Config.AuthorizedJobs) do
        if j == job then return true end
    end
    for _, j in ipairs(Config.AdminJobs) do
        if j == job then return true end
    end
    return false
end

local function IsAdmin(src)
    if IsPlayerAceAllowed(src, 'command') then return true end
    local job = GetPlayerJob(src)
    if not job then return false end
    for _, j in ipairs(Config.AdminJobs) do
        if j == job then return true end
    end
    return false
end

-- ── Unit identifier helper ────────────────────────────────────────────────
-- Returns the player's configured identifier with the type prefix stripped,
-- e.g. 'fivem:787929' → '787929'.  Falls back to server ID string on failure.
local function GetUnitIdentifier(src)
    local idType = Config.UnitIdentifierType or 'fivem'
    local prefix = idType .. ':'
    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id and id:sub(1, #prefix) == prefix then
            return id:sub(#prefix + 1)  -- strip prefix
        end
    end
    -- Fallback: server ID as string (always available)
    return tostring(GetPlayerServerId(src))
end

-- ── In-flight clip sessions ───────────────────────────────────────────────
-- Structure: { [clipId] = { unitId, trigger, serviceType, startTime, src, playerName } }
local activeSessions = {}

-- ── Event: client requests a new clip to be created ──────────────────────
-- trigger      — 'CALLOUT' | 'TRACKING' | 'WEAPON_FIRED' | 'MANUAL'
-- serviceType  — active service label (e.g. 'POLICE')
-- clientUnitId — player's custom badge / callsign (may be '' if not set)
RegisterNetEvent('bonez-bodycam_evidence:startClip')
AddEventHandler('bonez-bodycam_evidence:startClip', function(trigger, serviceType, clientUnitId)
    local src = source

    if not trigger then return end
    trigger     = tostring(trigger):upper()
    serviceType = tostring(serviceType or 'UNKNOWN'):upper()

    -- Use the player's custom unit ID if they have one set, otherwise fall back
    -- to their account identifier (discord / fivem / license etc. per config).
    local unitId
    if type(clientUnitId) == 'string' and clientUnitId ~= '' then
        unitId = clientUnitId:sub(1, 20)   -- cap length to prevent abuse
    else
        unitId = GetUnitIdentifier(src)
    end

    local playerName = GetPlayerName(src) or ''

    local clipId    = GenerateUUID()
    local startTime = os.time()

    activeSessions[clipId] = {
        src         = src,
        unitId      = unitId,
        trigger     = trigger,
        serviceType = serviceType,
        startTime   = startTime,
        playerName  = playerName,
    }

    local clipRecord = {
        clipId       = clipId,
        unitId       = unitId,
        trigger      = trigger,
        serviceType  = serviceType,
        startTime    = startTime,
        uploadStatus = 'pending',
        uploadType   = 'MP4',
        playerName   = playerName,
    }

    Storage.CreateClip(clipRecord)

    print(string.format(
        '^2[BCE] Clip START → id: %s | unit: %s | player: %s | trigger: %s | service: %s | src: %s^7',
        clipId, tostring(unitId), playerName, trigger, serviceType, tostring(src)
    ))

    -- ACK back to client with assigned clipId
    TriggerClientEvent('bonez-bodycam_evidence:clipStartAck', src, clipId, trigger, serviceType)
end)

-- ── Event: client abandons a clip (state changed before server ACK) ───────
RegisterNetEvent('bonez-bodycam_evidence:abandonClip')
AddEventHandler('bonez-bodycam_evidence:abandonClip', function(clipId)
    local src = source
    local session = activeSessions[clipId]
    if not session or session.src ~= src then return end
    activeSessions[clipId] = nil
    Storage.UpdateUpload(clipId, nil, nil, 'abandoned', 'MP4')
    -- Safety: ensure client returns to IDLE (client already resets itself in
    -- the clipStartAck handler, but this covers any other abandon paths)
    TriggerClientEvent('bonez-bodycam_evidence:chunksDone', src)
end)

-- ── Event: client signals capture phase complete ─────────────────────────
-- Fired when Recorder.Stop() is called. Frames are already buffered locally
-- on the client and passed to the NUI for background WebM encoding/upload.
-- We finalise the DB record here and immediately return the state machine to
-- IDLE — the NUI upload continues in the background.
RegisterNetEvent('bonez-bodycam_evidence:clipCaptureComplete')
AddEventHandler('bonez-bodycam_evidence:clipCaptureComplete', function(clipId, totalFrames)
    local src = source

    -- Always return client to IDLE first — even if our session record is missing
    -- (server restart, duplicate event, etc.) the client must not stay stuck.
    TriggerClientEvent('bonez-bodycam_evidence:chunksDone', src)

    local session = activeSessions[clipId]
    if not session or session.src ~= src then return end

    local endTime  = os.time()
    local duration = endTime - (session.startTime or endTime)
    totalFrames    = tonumber(totalFrames) or 0

    activeSessions[clipId] = nil

    print(string.format(
        '^2[BCE] Clip CAPTURE DONE → id: %s | frames: %d | duration: %ds | trigger: %s^7',
        clipId, totalFrames, duration, session.trigger
    ))

    -- Mark as 'processing' — saveVideoUrl will update to 'uploaded' when NUI finishes
    local status = totalFrames > 0 and 'processing' or 'no_frames'
    Storage.FinalizeClip(clipId, endTime, duration, totalFrames)
    Storage.UpdateUpload(clipId, nil, nil, status, 'MP4')
end)

-- ── Event: client requests clips for a unit ───────────────────────────────
-- targetUnitId may be an exact unit ID OR a free-text search query.
-- The storage layer tries an exact match first, then falls back to a
-- partial search across unitId, callsign, and playerName.
RegisterNetEvent('bonez-bodycam_evidence:requestClips')
AddEventHandler('bonez-bodycam_evidence:requestClips', function(targetUnitId)
    local src = source
    if not IsAuthorized(src) then
        TriggerClientEvent('bonez-bodycam_evidence:receiveClips', src, {})
        return
    end

    local query = tostring(targetUnitId or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if query == '' then
        TriggerClientEvent('bonez-bodycam_evidence:receiveClips', src, {})
        return
    end

    Storage.SearchClips(query, function(clips)
        TriggerClientEvent('bonez-bodycam_evidence:receiveClips', src, clips or {})
    end)
end)

-- ── Event: admin requests clip deletion ───────────────────────────────────
RegisterNetEvent('bonez-bodycam_evidence:deleteClip')
AddEventHandler('bonez-bodycam_evidence:deleteClip', function(clipId)
    local src = source
    if not IsAdmin(src) then
        TriggerClientEvent('bonez-bodycam_evidence:clipDeleted', src, clipId, false, 'Insufficient permissions')
        return
    end

    Storage.GetClip(clipId, function(clip)
        if not clip then
            TriggerClientEvent('bonez-bodycam_evidence:clipDeleted', src, clipId, false, 'Clip not found')
            return
        end

        local fmId   = clip.fivemanageId or clip.fivemanage_id
        local unitId = clip.unitId       or clip.unit_id

        Video.DeleteFromFivemanage(fmId, function(success)
            if success then
                Storage.DeleteClip(clipId, unitId)
                TriggerClientEvent('bonez-bodycam_evidence:clipDeleted', src, clipId, true, nil)
            else
                TriggerClientEvent('bonez-bodycam_evidence:clipDeleted', src, clipId, false, 'Fivemanage DELETE failed')
            end
        end)
    end)
end)

-- ── Event: viewer requests a Fivemanage presigned URL for WebM video upload ─
-- The NUI encodes frames as WebM via MediaRecorder and needs a presigned URL
-- to upload it directly to Fivemanage (API key stays server-side).
RegisterNetEvent('bonez-bodycam_evidence:requestVideoPresignedUrl')
AddEventHandler('bonez-bodycam_evidence:requestVideoPresignedUrl', function()
    local src = source
    if not IsAuthorized(src) then return end

    PerformHttpRequest(
        'https://api.fivemanage.com/api/v3/file/presigned-url',
        function(status, body)
            if status == 200 or status == 201 then
                local resp = json.decode(body or '{}') or {}
                local url  = resp.data and resp.data.presignedUrl
                if url then
                    TriggerClientEvent('bonez-bodycam_evidence:videoPresignedUrlResult', src, url, nil)
                    return
                end
            end
            print(string.format('^1[BCE] Video presigned URL failed: HTTP %s^7', tostring(status)))
            TriggerClientEvent('bonez-bodycam_evidence:videoPresignedUrlResult', src, nil, 'HTTP ' .. tostring(status))
        end,
        'GET', '',
        { ['Authorization'] = ApiKeys.Fivemanage }
    )
end)

-- ── Event: NUI reports the uploaded WebM video URL — save to DB ────────────
-- Called after background encoding + upload finishes (viewer open or not).
RegisterNetEvent('bonez-bodycam_evidence:saveVideoUrl')
AddEventHandler('bonez-bodycam_evidence:saveVideoUrl', function(clipId, videoUrl)
    local src = source
    if not IsAuthorized(src) then return end
    if type(clipId) ~= 'string' or type(videoUrl) ~= 'string' then return end
    if not videoUrl:match('^https://') then return end

    Storage.UpdateUpload(clipId, nil, videoUrl, 'uploaded', 'MP4')
    print(string.format('^2[BCE] Video URL saved for clip %s^7', clipId))

    -- Enforce per-unit clip cap now that upload is confirmed
    Storage.GetClip(clipId, function(clip)
        if clip then
            Storage.EnforceClipCap(clip.unitId or clip.unit_id)
        end
    end)
end)

-- ── On resource start: retry any failed uploads ───────────────────────────
AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        Storage.RetryFailedClips()
    end
end)

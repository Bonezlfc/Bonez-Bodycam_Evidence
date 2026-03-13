---@diagnostic disable: undefined-global
-- bonez-bodycam_evidence | server/storage.lua
-- Clip CRUD — oxmysql preferred, server KVP fallback.
-- All functions are synchronous-style via coroutine/await or KVP directly.

Storage = {}

-- ── Detect oxmysql ────────────────────────────────────────────────────────
local useMySQL = false

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        useMySQL = GetResourceState('oxmysql') == 'started'
        if useMySQL then
            -- Ensure table exists
            exports.oxmysql:execute([[
                CREATE TABLE IF NOT EXISTS bodycam_evidence (
                    id            INT AUTO_INCREMENT PRIMARY KEY,
                    clipId        VARCHAR(36)  NOT NULL UNIQUE,
                    unitId        VARCHAR(120) NOT NULL,
                    triggerType   VARCHAR(20)  NOT NULL,
                    serviceType   VARCHAR(50),
                    startTime     BIGINT       NOT NULL,
                    endTime       BIGINT,
                    duration      INT,
                    totalFrames   INT          DEFAULT 0,
                    fivemanageId  VARCHAR(100),
                    fivemanageUrl TEXT,
                    uploadStatus  VARCHAR(20)  DEFAULT 'pending',
                    uploadType    VARCHAR(20)  DEFAULT 'MP4',
                    playerName    VARCHAR(100),
                    callsign      VARCHAR(50),
                    createdAt     TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
                )
            ]], {})
            -- Migrate unitId column from INT to VARCHAR for existing installs
            exports.oxmysql:execute(
                'ALTER TABLE bodycam_evidence MODIFY COLUMN unitId VARCHAR(120) NOT NULL',
                {}
            )
            -- Migrate: add playerName and callsign columns for existing installs
            exports.oxmysql:execute(
                "ALTER TABLE bodycam_evidence ADD COLUMN IF NOT EXISTS playerName VARCHAR(100)",
                {}
            )
            exports.oxmysql:execute(
                "ALTER TABLE bodycam_evidence ADD COLUMN IF NOT EXISTS callsign VARCHAR(50)",
                {}
            )
            print('^2[bonez-bodycam_evidence] Storage: oxmysql^0')
        else
            print('^3[bonez-bodycam_evidence] Storage: server KVP (oxmysql not detected)^0')
        end
    end
end)

-- ── KVP helpers ────────────────────────────────────────────────────────────

local KVP_PREFIX_CLIP = 'bce_clip_'
local KVP_PREFIX_UNIT = 'bce_unit_'

local function KvpSetClip(clip)
    SetResourceKvp(KVP_PREFIX_CLIP .. clip.clipId, json.encode(clip))
end

local function KvpGetClip(clipId)
    local raw = GetResourceKvpString(KVP_PREFIX_CLIP .. clipId)
    if raw then return json.decode(raw) end
    return nil
end

local function KvpDeleteClip(clipId)
    DeleteResourceKvp(KVP_PREFIX_CLIP .. clipId)
end

local function KvpGetUnitClipIds(unitId)
    local raw = GetResourceKvpString(KVP_PREFIX_UNIT .. tostring(unitId))
    if raw then return json.decode(raw) or {} end
    return {}
end

local function KvpSetUnitClipIds(unitId, ids)
    SetResourceKvp(KVP_PREFIX_UNIT .. tostring(unitId), json.encode(ids))
end

-- ── Public API ─────────────────────────────────────────────────────────────

-- Insert a new clip record (called at clip start, before frames arrive)
function Storage.CreateClip(clip)
    if useMySQL then
        exports.oxmysql:execute(
            [[INSERT INTO bodycam_evidence
              (clipId, unitId, triggerType, serviceType, startTime, uploadStatus, uploadType, playerName, callsign)
              VALUES (?, ?, ?, ?, ?, 'pending', 'MP4', ?, ?)]],
            { clip.clipId, clip.unitId, clip.trigger, clip.serviceType, clip.startTime,
              clip.playerName or '', clip.callsign or nil }
        )
    else
        KvpSetClip(clip)
        local ids = KvpGetUnitClipIds(clip.unitId)
        table.insert(ids, clip.clipId)
        KvpSetUnitClipIds(clip.unitId, ids)
        Storage.EnforceClipCap(clip.unitId)
    end
end

-- Update clip when recording ends (endTime, duration, totalFrames)
function Storage.FinalizeClip(clipId, endTime, duration, totalFrames)
    if useMySQL then
        exports.oxmysql:execute(
            [[UPDATE bodycam_evidence SET endTime=?, duration=?, totalFrames=? WHERE clipId=?]],
            { endTime, duration, totalFrames, clipId }
        )
    else
        local clip = KvpGetClip(clipId)
        if clip then
            clip.endTime     = endTime
            clip.duration    = duration
            clip.totalFrames = totalFrames
            KvpSetClip(clip)
        end
    end
end

-- Update after Fivemanage upload completes
function Storage.UpdateUpload(clipId, fivemanageId, fivemanageUrl, uploadStatus, uploadType)
    if useMySQL then
        exports.oxmysql:execute(
            [[UPDATE bodycam_evidence
              SET fivemanageId=?, fivemanageUrl=?, uploadStatus=?, uploadType=?
              WHERE clipId=?]],
            { fivemanageId, fivemanageUrl, uploadStatus, uploadType or 'MP4', clipId }
        )
    else
        local clip = KvpGetClip(clipId)
        if clip then
            clip.fivemanageId  = fivemanageId
            clip.fivemanageUrl = fivemanageUrl
            clip.uploadStatus  = uploadStatus
            clip.uploadType    = uploadType or 'MP4'
            KvpSetClip(clip)
        end
    end
end

-- Retrieve all clips for a unit (returns safe subset for client)
function Storage.GetClipsForUnit(unitId, cb)
    if useMySQL then
        exports.oxmysql:execute(
            [[SELECT clipId, unitId, triggerType AS `trigger`, serviceType, startTime, endTime,
                     duration, totalFrames, fivemanageUrl, uploadStatus
              FROM bodycam_evidence WHERE unitId=? ORDER BY startTime DESC LIMIT ?]],
            { unitId, Config.ClipsPerUnit },
            function(rows)
                cb(rows or {})
            end
        )
    else
        local ids  = KvpGetUnitClipIds(unitId)
        local clips = {}
        for _, id in ipairs(ids) do
            local clip = KvpGetClip(id)
            if clip then
                -- Return only safe fields (no fivemanageId, no API-adjacent data)
                table.insert(clips, {
                    clipId       = clip.clipId,
                    unitId       = clip.unitId,
                    trigger      = clip.trigger,
                    serviceType  = clip.serviceType,
                    startTime    = clip.startTime,
                    endTime      = clip.endTime,
                    duration     = clip.duration,
                    totalFrames  = clip.totalFrames,
                    fivemanageUrl = clip.fivemanageUrl,
                    uploadStatus  = clip.uploadStatus,
                })
            end
        end
        -- Sort newest first
        table.sort(clips, function(a, b) return (a.startTime or 0) > (b.startTime or 0) end)
        cb(clips)
    end
end

-- Search clips by unitId, callsign, or playerName (partial, case-insensitive).
-- Returns the most-recent Config.ClipsPerUnit matches.
function Storage.SearchClips(query, cb)
    if useMySQL then
        local pattern = '%' .. tostring(query) .. '%'
        exports.oxmysql:execute(
            [[SELECT clipId, unitId, triggerType AS `trigger`, serviceType, startTime, endTime,
                     duration, totalFrames, fivemanageUrl, uploadStatus, playerName, callsign
              FROM bodycam_evidence
              WHERE unitId LIKE ? OR callsign LIKE ? OR playerName LIKE ?
              ORDER BY startTime DESC LIMIT ?]],
            { pattern, pattern, pattern, Config.ClipsPerUnit },
            function(rows) cb(rows or {}) end
        )
    else
        -- KVP: scan all clip keys and filter in Lua
        local q    = tostring(query):lower()
        local all  = {}
        local h    = StartFindKvp(KVP_PREFIX_CLIP)
        if h ~= -1 then
            while true do
                local key = FindKvp(h)
                if not key then break end
                local raw = GetResourceKvpString(key)
                if raw then
                    local clip = json.decode(raw)
                    if clip then
                        local unitMatch = tostring(clip.unitId or ''):lower():find(q, 1, true)
                        local csMatch   = clip.callsign   and tostring(clip.callsign):lower():find(q, 1, true)
                        local nameMatch = clip.playerName and tostring(clip.playerName):lower():find(q, 1, true)
                        if unitMatch or csMatch or nameMatch then
                            table.insert(all, {
                                clipId        = clip.clipId,
                                unitId        = clip.unitId,
                                trigger       = clip.trigger,
                                serviceType   = clip.serviceType,
                                startTime     = clip.startTime,
                                endTime       = clip.endTime,
                                duration      = clip.duration,
                                totalFrames   = clip.totalFrames,
                                fivemanageUrl = clip.fivemanageUrl,
                                uploadStatus  = clip.uploadStatus,
                                playerName    = clip.playerName,
                                callsign      = clip.callsign,
                            })
                        end
                    end
                end
            end
            EndFindKvp(h)
        end
        table.sort(all, function(a, b) return (a.startTime or 0) > (b.startTime or 0) end)
        -- Trim to cap
        local trimmed = {}
        for i = 1, math.min(#all, Config.ClipsPerUnit) do trimmed[i] = all[i] end
        cb(trimmed)
    end
end

-- Get a single clip by ID (full record, server-side only)
function Storage.GetClip(clipId, cb)
    if useMySQL then
        exports.oxmysql:execute(
            'SELECT * FROM bodycam_evidence WHERE clipId=? LIMIT 1',
            { clipId },
            function(rows)
                cb(rows and rows[1] or nil)
            end
        )
    else
        cb(KvpGetClip(clipId))
    end
end

-- Permanently delete a clip record (called after Fivemanage DELETE succeeds)
function Storage.DeleteClip(clipId, unitId)
    if useMySQL then
        exports.oxmysql:execute('DELETE FROM bodycam_evidence WHERE clipId=?', { clipId })
    else
        KvpDeleteClip(clipId)
        local ids = KvpGetUnitClipIds(unitId)
        for i = #ids, 1, -1 do
            if ids[i] == clipId then table.remove(ids, i) end
        end
        KvpSetUnitClipIds(unitId, ids)
    end
end

-- Enforce per-unit clip cap — delete oldest beyond Config.ClipsPerUnit
-- (deletes from Fivemanage too via Video.DeleteFromFivemanage)
function Storage.EnforceClipCap(unitId)
    if useMySQL then
        exports.oxmysql:execute(
            [[SELECT clipId, fivemanageId FROM bodycam_evidence
              WHERE unitId=? ORDER BY startTime DESC]],
            { unitId },
            function(rows)
                if not rows then return end
                if #rows <= Config.ClipsPerUnit then return end
                for i = Config.ClipsPerUnit + 1, #rows do
                    local old = rows[i]
                    if old.fivemanageId then
                        Video.DeleteFromFivemanage(old.fivemanageId)
                    end
                    Storage.DeleteClip(old.clipId, unitId)
                end
            end
        )
    else
        local ids = KvpGetUnitClipIds(unitId)
        if #ids <= Config.ClipsPerUnit then return end
        -- KVP list is ordered insertion; oldest are at the start
        while #ids > Config.ClipsPerUnit do
            local oldId = table.remove(ids, 1)
            local clip  = KvpGetClip(oldId)
            if clip and clip.fivemanageId then
                Video.DeleteFromFivemanage(clip.fivemanageId)
            end
            KvpDeleteClip(oldId)
        end
        KvpSetUnitClipIds(unitId, ids)
    end
end

-- On restart: collect all 'failed' clips and retry upload
function Storage.RetryFailedClips()
    if useMySQL then
        exports.oxmysql:execute(
            "SELECT * FROM bodycam_evidence WHERE uploadStatus='failed'",
            {},
            function(rows)
                if not rows then return end
                for _, clip in ipairs(rows) do
                    print(string.format('[bonez-bodycam_evidence] Retrying failed upload for clip %s', clip.clipId))
                    -- No frames available after restart — just mark as metadata-only re-attempt
                    -- Real retry with frames is not possible post-restart; mark note in DB
                    Storage.UpdateUpload(clip.clipId, nil, nil, 'no_retry', clip.uploadType)
                end
            end
        )
    end
    -- KVP: no retry logic post-restart (frames not persisted)
end

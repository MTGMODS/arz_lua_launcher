
-- NeoMLoader In-Game 
if type(script_name) == "function" then script_name("SAMP API Testing Tool v2") end
if type(script_author) == "function" then script_author("NeoMLoader Team") end
if type(script_version) == "function" then script_version("2.0.0") end

local hasMimgui, imgui = pcall(require, "mimgui")
local hasSAMemory, samemory = pcall(require, "SAMemory")
local unpack = unpack or table.unpack

-- ═══ Mobile DPI Scaling ═══
local rawDpi = (type(MONET_DPI_SCALE) == "number" and MONET_DPI_SCALE > 0) and MONET_DPI_SCALE or 1.0
local dpiScale = math.max(0.5, math.min(4.0, rawDpi))
local function dp(v)
    return math.floor(v * dpiScale + 0.5)
end

local showWindow, liveMonitorEnabled, targetPlayerId, targetVehicleId, searchFilter, expandedCategories = nil, nil, nil, nil, nil, {}
if hasMimgui and imgui and imgui.new then
    showWindow = imgui.new.bool(true)
    liveMonitorEnabled = imgui.new.bool(false)
    targetPlayerId = imgui.new.int(-1)
    targetVehicleId = imgui.new.int(-1)
    searchFilter = imgui.new("char[128]", "")
end

local lastMonitorTick, totalTested, totalPassed, totalFailed, totalMissing = 0, 0, 0, 0, 0
local allTestResults, logHistory, maxLogLines = {}, {}, 100

-- ═══ Helpers ═══

local function addLog(msg)
    table.insert(logHistory, string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg)))
    if #logHistory > maxLogLines then table.remove(logHistory, 1) end
    print("[SAMP_TEST] " .. tostring(msg))
end

local function sendChatMessage(text, color)
    if type(sampAddChatMessage) == "function" then pcall(sampAddChatMessage, text, color or 0x00FF88FF)
    else print("[SAMP_CHAT] " .. tostring(text)) end
end

local function formatValue(val)
    if val == nil then return "nil" end
    local t = type(val)
    if t == "boolean" then return val and "true" or "false"
    elseif t == "number" then
        if val == math.floor(val) and math.abs(val) > 0x10000 then return string.format("%d (0x%X)", val, val)
        elseif val == math.floor(val) then return string.format("%d", val)
        else return string.format("%.4f", val) end
    elseif t == "string" then
        if #val == 0 then return '""' elseif #val > 64 then return '"'..val:sub(1,61)..'..."' else return '"'..val..'"' end
    elseif t == "table" then
        local p, n = {}, 0; for k,v in pairs(val) do n=n+1; if n<=3 then p[#p+1]=tostring(k).."="..tostring(v) end end
        return "{"..table.concat(p, ", ")..(n>3 and ", ..." or "").."}"
    else return tostring(val) end
end

local function formatReturnValues(results)
    if #results == 0 then return "<void>" end
    local p = {}; for _,v in ipairs(results) do p[#p+1]=formatValue(v) end; return table.concat(p, ", ")
end

local function invokeBind(name, fn, args)
    if type(fn) ~= "function" then
        return {name=name, exists=false, ok=false, values={}, formatted="<not defined>", err="not defined"}
    end
    args = args or {}
    local ret = {pcall(fn, unpack(args))}
    local ok = table.remove(ret, 1)
    if ok then return {name=name, exists=true, ok=true, values=ret, formatted=formatReturnValues(ret), err=nil}
    else return {name=name, exists=true, ok=false, values={}, formatted="<error>", err=tostring(ret[1] or "unknown")} end
end

-- ═══ Target Helpers ═══

local function getTargetPlayer()
    if targetPlayerId and targetPlayerId[0] and targetPlayerId[0] >= 0 then return targetPlayerId[0] end
    if type(sampGetLocalPlayerId) == "function" then
        local ok, id = pcall(sampGetLocalPlayerId); if ok and id and id >= 0 then return id end
    end
    return 0
end

local function getTargetVehicle()
    if targetVehicleId and targetVehicleId[0] and targetVehicleId[0] >= 1 then return targetVehicleId[0] end
    if type(sampIsVehicleStreamedIn) == "function" then
        for i = 1, 2000 do
            local ok, streamed = pcall(sampIsVehicleStreamedIn, i)
            if ok and streamed then return i end
        end
    end
    return 0
end

local function getTargetPlayerHandle()
    local pid = getTargetPlayer()
    if type(sampGetCharHandleBySampPlayerId) == "function" then
        local ok, h = pcall(sampGetCharHandleBySampPlayerId, pid)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    if type(getPlayerChar) == "function" then
        local ok, h = pcall(getPlayerChar, 0)
        if ok and type(h) == "number" and h > 0 then return h end
    end
    return 0
end

local function getTargetVehicleHandle()
    local vid = getTargetVehicle()
    if vid < 1 or type(sampGetCarHandleBySampVehicleId) ~= "function" then return 0 end
    local ok, h = pcall(sampGetCarHandleBySampVehicleId, vid)
    return ok and type(h) == "number" and h or 0
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validateResult(test, values)
    if not test.validate then return true end
    local ok, valid, reason = pcall(test.validate, values)
    if not ok then return false, "validator error: "..tostring(valid) end
    if valid then return true end
    return false, reason or "validation failed"
end

-- ═══ Argument Resolution ═══

local function resolveArgs(group)
    local cat = group.category
    if cat == "Players" then return {getTargetPlayer()}
    elseif cat == "Vehicles" then return {getTargetVehicle()}
    elseif cat == "GTA Char Health" or cat == "GTA Char Position" then return {getTargetPlayerHandle()}
    elseif cat == "GTA Vehicles" or cat == "GTA Veh Position" then return {getTargetVehicleHandle()}
    end
    return {}
end

-- ═══ Test Catalog ═══

local testCatalog = {
    { category = "Core & Server", tests = {
        { name = "sampGetBase", desc = "Get SA-MP module base address", fn = function() return sampGetBase() end },
        { name = "sampGetConnState", desc = "Get connection state (4=connected)", fn = function() return sampGetConnState() end },
        { name = "sampGetServerAddress", desc = "Get server IP address", fn = function() return sampGetServerAddress() end },
        { name = "sampGetServerPort", desc = "Get server port", fn = function() return sampGetServerPort() end },
        { name = "sampGetServerName", desc = "Get server name", fn = function() return sampGetServerName() end },
        { name = "sampGetLocalPlayerId", desc = "Get local player SAMP ID", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end, fn = function() return sampGetLocalPlayerId() end },
        { name = "sampIsPlayerConnected", desc = "Check if local player is connected", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsPlayerConnected(getTargetPlayer()) end },
        { name = "sampIsLocalPlayerSpawned", desc = "Check if local player is spawned", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsLocalPlayerSpawned() end },
        { name = "sampGetMaxPlayerId", desc = "Get max player slot ID", fn = function() return sampGetMaxPlayerId() end },
        { name = "sampGetPlayerCount", desc = "Get total player count", fn = function() return sampGetPlayerCount() end },
    }},
    { category = "Players", tests = {
        { name = "sampGetPlayerHealth", desc = "Get player health (0-200)", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 and v[1] <= 200 end, fn = function(pid) return sampGetPlayerHealth(pid) end },
        { name = "sampGetPlayerArmor", desc = "Get player armour (0-100)", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 and v[1] <= 100 end, fn = function(pid) return sampGetPlayerArmor(pid) end },
        { name = "sampGetPlayerPing", desc = "Get player ping in ms", fn = function(pid) return sampGetPlayerPing(pid) end },
        { name = "sampGetPlayerScore", desc = "Get player score", fn = function(pid) return sampGetPlayerScore(pid) end },
        { name = "sampGetPlayerWeapon", desc = "Get current weapon ID", fn = function(pid) return sampGetPlayerWeapon(pid) end },
        { name = "sampGetPlayerAmmo", desc = "Get current weapon ammo", fn = function(pid) return sampGetPlayerAmmo(pid) end },
        { name = "sampGetPlayerVehicle", desc = "Get vehicle handle occupied by player", fn = function(pid) return sampGetPlayerVehicle(pid) end },
        { name = "sampGetPlayerNickname", desc = "Get player nickname", fn = function(pid) return sampGetPlayerNickname(pid) end },
        { name = "sampGetPlayerState", desc = "Get player state (0=off,1=onfoot,3=incar)", fn = function(pid) return sampGetPlayerState(pid) end },
        { name = "sampGetPlayerSkin", desc = "Get player skin model ID", fn = function(pid) return sampGetPlayerSkin(pid) end },
        { name = "sampGetPlayerTeam", desc = "Get player team", fn = function(pid) return sampGetPlayerTeam(pid) end },
        { name = "sampGetPlayerColor", desc = "Get player color (RGBA)", fn = function(pid) return sampGetPlayerColor(pid) end },
        { name = "sampGetPlayerPos", desc = "Get player position (x,y,z)", fn = function(pid) return sampGetPlayerPos(pid) end },
        { name = "sampGetPlayerFacingAngle", desc = "Get player facing angle", fn = function(pid) return sampGetPlayerFacingAngle(pid) end },
        { name = "sampGetPlayerAnimationId", desc = "Get current animation ID", fn = function(pid) return sampGetPlayerAnimationId(pid) end },
        { name = "sampGetPlayerSpecialAction", desc = "Get special action ID", fn = function(pid) return sampGetPlayerSpecialAction(pid) end },
        { name = "sampGetPlayerFightingStyle", desc = "Get fighting style", fn = function(pid) return sampGetPlayerFightingStyle(pid) end },
        { name = "sampIsPlayerPaused", desc = "Check if player is AFK/paused", validate = function(v) return type(v[1]) == "boolean" end, fn = function(pid) return sampIsPlayerPaused(pid) end },
        { name = "sampIsPlayerNpc", desc = "Check if player is NPC", validate = function(v) return type(v[1]) == "boolean" end, fn = function(pid) return sampIsPlayerNpc(pid) end },
        { name = "sampIsPlayerInVehicle", desc = "Check if player is in a vehicle", validate = function(v) return type(v[1]) == "boolean" end, fn = function(pid) return sampIsPlayerInVehicle(pid) end },
        { name = "sampGetPlayerPoolPtr", desc = "Get player pool pointer", fn = function() return sampGetPlayerPoolPtr() end },
        { name = "sampGetPlayerStructPtr", desc = "Get remote player struct ptr", fn = function(pid) return sampGetPlayerStructPtr(pid) end },
    }},
    { category = "Vehicles", tests = {
        { name = "sampGetVehicleHealth", desc = "Get vehicle health", fn = function(vid) return sampGetVehicleHealth(vid) end },
        { name = "sampGetVehicleIdByCarHandle", desc = "Get SAMP ID from vehicle handle", fn = function() return sampGetVehicleIdByCarHandle(getTargetVehicleHandle()) end },
        { name = "sampGetCarHandleBySampVehicleId", desc = "Get vehicle handle from SAMP ID", fn = function(vid) return sampGetCarHandleBySampVehicleId(vid) end },
        { name = "sampGetVehiclePos", desc = "Get vehicle position (x,y,z)", fn = function(vid) return sampGetVehiclePos(vid) end },
        { name = "sampGetVehicleParams", desc = "Get engine/lights/doors params", fn = function(vid) return sampGetVehicleParams(vid) end },
        { name = "sampGetVehicleIdByEntityPtr", desc = "Get SAMP vehicle ID from entity pointer", fn = function() return sampGetVehicleIdByEntityPtr(getTargetVehicleHandle()) end },
        { name = "sampIsVehicleStreamedIn", desc = "Check if vehicle is streamed in", validate = function(v) return type(v[1]) == "boolean" end, fn = function(vid) return sampIsVehicleStreamedIn(vid) end },
    }},
    { category = "Dialogs", tests = {
        { name = "sampIsDialogActive", desc = "Check if dialog is active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsDialogActive() end },
        { name = "sampGetCurrentDialogType", desc = "Get dialog type", fn = function() return sampGetCurrentDialogType() end },
        { name = "sampGetCurrentDialogId", desc = "Get dialog ID", fn = function() return sampGetCurrentDialogId() end },
        { name = "sampGetDialogTitle", desc = "Get dialog title", fn = function() return sampGetDialogTitle() end },
        { name = "sampGetDialogText", desc = "Get dialog text", fn = function() return sampGetDialogText() end },
        { name = "sampGetCurrentDialogListItem", desc = "Get selected list item", fn = function() return sampGetCurrentDialogListItem() end },
        { name = "sampGetListboxItemsCount", desc = "Get list item count", fn = function() return sampGetListboxItemsCount() end },
    }},
    { category = "Chat & Input", tests = {
        { name = "sampGetChatDisplayMode", desc = "Get chat display mode (0=off,1=light,2=full)", fn = function() return sampGetChatDisplayMode() end },
        { name = "sampIsChatVisible", desc = "Check if chat is visible", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsChatVisible() end },
        { name = "sampIsChatInputActive", desc = "Check if chat input is active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsChatInputActive() end },
        { name = "sampSendChat", desc = "Verify send chat is callable", fn = function() return type(sampSendChat) == "function" end, isSynthetic = true },
        { name = "sampSendCommand", desc = "Verify send command is callable", fn = function() return type(sampSendCommand) == "function" end, isSynthetic = true },
    }},
    { category = "TextDraws", tests = {
        { name = "sampTextdrawCreate", desc = "Verify textdraw create bound", fn = function() return type(sampTextdrawCreate) == "function" end, isSynthetic = true },
        { name = "sampTextdrawSetString", desc = "Verify textdraw set string bound", fn = function() return type(sampTextdrawSetString) == "function" end, isSynthetic = true },
        { name = "sampTextdrawShowForPlayer", desc = "Verify textdraw show bound", fn = function() return type(sampTextdrawShowForPlayer) == "function" end, isSynthetic = true },
        { name = "sampTextdrawHideForPlayer", desc = "Verify textdraw hide bound", fn = function() return type(sampTextdrawHideForPlayer) == "function" end, isSynthetic = true },
        { name = "sampTextdrawDelete", desc = "Verify textdraw delete bound", fn = function() return type(sampTextdrawDelete) == "function" end, isSynthetic = true },
    }},
    { category = "3D Texts", tests = {
        { name = "sampCreate3dTextEx", desc = "Verify 3D text create bound", fn = function() return type(sampCreate3dTextEx) == "function" end, isSynthetic = true },
        { name = "sampDelete3dText", desc = "Verify 3D text delete bound", fn = function() return type(sampDelete3dText) == "function" end, isSynthetic = true },
    }},
    { category = "GTA Char Health", tests = {
        { name = "getCharHealth", desc = "Get ped health (0-200)", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "getCharArmour", desc = "Get ped armour (0-100)", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "isCharDead", desc = "Is ped dead", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharOnScreen", desc = "Is ped visible on screen", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharOnFoot", desc = "Is ped on foot", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAnyCar", desc = "Is ped in any car", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAnyBoat", desc = "Is ped in a boat", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAnyHeli", desc = "Is ped in a heli", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAnyPlane", desc = "Is ped in a plane", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAnyTrain", desc = "Is ped in a train", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharOnAnyBike", desc = "Is ped on a bike", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharSwimming", desc = "Is ped swimming", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInWater", desc = "Is ped in water", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharDucking", desc = "Is ped ducking", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharMale", desc = "Is ped male", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharStopped", desc = "Is ped standing still", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharShooting", desc = "Is ped shooting", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharSitting", desc = "Is ped sitting", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharTalking", desc = "Is ped talking", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharStuckUnderCar", desc = "Is ped stuck under car", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCharInAir", desc = "Is ped airborne", validate = function(v) return type(v[1]) == "boolean" end },
    }},
    { category = "GTA Char Position", tests = {
        { name = "getCharCoordinates", desc = "Get ped world coordinates (x,y,z)", validate = function(v) return isFiniteNumber(v[1]) and isFiniteNumber(v[2]) and isFiniteNumber(v[3]) end },
        { name = "getCharHeading", desc = "Get ped heading angle", validate = function(v) return isFiniteNumber(v[1]) end },
        { name = "getCharPointer", desc = "Get CPed memory pointer", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "isPlayerDead", desc = "Check if player slot 0 is dead", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPlayerDead(0) end },
        { name = "isPlayerControlOn", desc = "Check if player has control", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPlayerControlOn(0) end },
        { name = "isPlayerControllable", desc = "Check if player is controllable", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPlayerControllable(0) end },
        { name = "isPlayerClimbing", desc = "Check if player is climbing", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPlayerClimbing(0) end },
        { name = "isPlayerUsingJetpack", desc = "Check if player is using jetpack", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPlayerUsingJetpack(0) end },
        { name = "getPlayerChar", desc = "Get character handle for player 0", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end, fn = function() return getPlayerChar(0) end },
    }},
    { category = "GTA Vehicles", tests = {
        { name = "getCarHealth", desc = "Get vehicle health points", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "isCarDead", desc = "Is vehicle dead", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarOnScreen", desc = "Is vehicle visible on screen", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarUpright", desc = "Is vehicle upright", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarUpsidedown", desc = "Is vehicle upside down", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarInWater", desc = "Is vehicle in water", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarStopped", desc = "Is vehicle stopped", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarStuck", desc = "Is vehicle stuck", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarOnFire", desc = "Is vehicle on fire", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarSirenOn", desc = "Is vehicle siren on", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarEngineOn", desc = "Is vehicle engine on", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarVisiblyDamaged", desc = "Does vehicle have visible damage", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarAttached", desc = "Is vehicle attached to something", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isCarOnTrailer", desc = "Is vehicle on a trailer", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "getCarModel", desc = "Get vehicle model ID (400-611)", validate = function(v) return isFiniteNumber(v[1]) and (v[1] == 0 or (v[1] >= 400 and v[1] <= 611)) end },
        { name = "getVehiclePointerHandle", desc = "Get CVehicle memory pointer", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "getDriverOfCar", desc = "Get driver ped handle", fn = function(h) return getDriverOfCar(h) end },
        { name = "getMaximumNumberOfPassengers", desc = "Get max passenger capacity", fn = function(h) return getMaximumNumberOfPassengers(h) end },
        { name = "getNumberOfPassengers", desc = "Get current passenger count", fn = function(h) return getNumberOfPassengers(h) end },
        { name = "getCarDoorLockStatus", desc = "Get door lock status", fn = function(h) return getCarDoorLockStatus(h) end },
        { name = "isPlayerPressingHorn", desc = "Is player pressing horn", fn = function() return isPlayerPressingHorn(0) end, validate = function(v) return type(v[1]) == "boolean" end },
    }},
    { category = "GTA Veh Position", tests = {
        { name = "getVehicleCoordinates", desc = "Get vehicle world coordinates", validate = function(v) return isFiniteNumber(v[1]) and isFiniteNumber(v[2]) and isFiniteNumber(v[3]) end },
        { name = "getVehicleVelocity", desc = "Get vehicle velocity vector", validate = function(v) return isFiniteNumber(v[1]) end },
        { name = "isVehicleOnScreen", desc = "Is vehicle visible on screen", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "isVehicleOnAllWheels", desc = "Is vehicle on all wheels", validate = function(v) return type(v[1]) == "boolean" end },
        { name = "getVehicleModel", desc = "Get vehicle model from handle", validate = function(v) return isFiniteNumber(v[1]) end },
        { name = "SAMemory.GetVehicleDirtLevel", desc = "Get vehicle dirt level (SAMemory)", fn = function() local h = getTargetVehicleHandle(); if h > 0 and samemory and samemory.GetVehicleDirtLevel then return samemory.GetVehicleDirtLevel(h) end return nil end, validate = function(v) return v[1] == nil or isFiniteNumber(v[1]) end },
        { name = "SAMemory.GetVehicleEngineState", desc = "Get vehicle engine state (SAMemory)", fn = function() local h = getTargetVehicleHandle(); if h > 0 and samemory and samemory.GetVehicleEngineState then return samemory.GetVehicleEngineState(h) end return nil end, validate = function(v) return v[1] == nil or type(v[1]) == "boolean" end },
        { name = "SAMemory.GetVehicleLockState", desc = "Get vehicle lock state (SAMemory)", fn = function() local h = getTargetVehicleHandle(); if h > 0 and samemory and samemory.GetVehicleLockState then return samemory.GetVehicleLockState(h) end return nil end, validate = function(v) return v[1] == nil or isFiniteNumber(v[1]) end },
        { name = "SAMemory.GetVehicleSirenState", desc = "Get vehicle siren state (SAMemory)", fn = function() local h = getTargetVehicleHandle(); if h > 0 and samemory and samemory.GetVehicleSirenState then return samemory.GetVehicleSirenState(h) end return nil end, validate = function(v) return v[1] == nil or type(v[1]) == "boolean" end },
    }},
    { category = "GTA Camera", tests = {
        { name = "isDebugCameraOn", desc = "Is debug camera active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isDebugCameraOn() end },
        { name = "setCameraBehindPlayer", desc = "Verify setCameraBehindPlayer bound", fn = function() return type(setCameraBehindPlayer) == "function" end, isSynthetic = true },
        { name = "restoreCamera", desc = "Verify restoreCamera bound", fn = function() return type(restoreCamera) == "function" end, isSynthetic = true },
        { name = "restoreCameraJumpcut", desc = "Verify restoreCameraJumpcut bound", fn = function() return type(restoreCameraJumpcut) == "function" end, isSynthetic = true },
        { name = "setCameraInFrontOfPlayer", desc = "Verify setCameraInFrontOfPlayer bound", fn = function() return type(setCameraInFrontOfPlayer) == "function" end, isSynthetic = true },
    }},
    { category = "GTA Drawing", tests = {
        { name = "printStringNow", desc = "Verify printStringNow bound", fn = function() return type(printStringNow) == "function" end, isSynthetic = true },
        { name = "printBig", desc = "Verify printBig bound", fn = function() return type(printBig) == "function" end, isSynthetic = true },
        { name = "printHelp", desc = "Verify printHelp bound", fn = function() return type(printHelp) == "function" end, isSynthetic = true },
        { name = "printStyledString", desc = "Verify printStyledString bound", fn = function() return type(printStyledString) == "function" end, isSynthetic = true },
        { name = "printText", desc = "Verify printText bound", fn = function() return type(printText) == "function" end, isSynthetic = true },
        { name = "showGameText", desc = "Verify showGameText bound", fn = function() return type(showGameText) == "function" end, isSynthetic = true },
        { name = "hideGameText", desc = "Verify hideGameText bound", fn = function() return type(hideGameText) == "function" end, isSynthetic = true },
        { name = "setTextFont", desc = "Verify setTextFont bound", fn = function() return type(setTextFont) == "function" end, isSynthetic = true },
        { name = "setTextScale", desc = "Verify setTextScale bound", fn = function() return type(setTextScale) == "function" end, isSynthetic = true },
        { name = "setTextColour", desc = "Verify setTextColour bound", fn = function() return type(setTextColour) == "function" end, isSynthetic = true },
    }},
    { category = "GTA World", tests = {
        { name = "getWeather", desc = "Get current weather ID", validate = function(v) return isFiniteNumber(v[1]) end, fn = function() return getWeather() end },
        { name = "getGravity", desc = "Get current gravity", validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end, fn = function() return getGravity() end },
        { name = "getTimeOfDay", desc = "Get current time (h, m)", validate = function(v) return isFiniteNumber(v[1]) and isFiniteNumber(v[2]) end, fn = function() return getTimeOfDay() end },
        { name = "getGameTick", desc = "Get game tick count", validate = function(v) return isFiniteNumber(v[1]) and v[1] > 0 end, fn = function() return getGameTick() end },
        { name = "getTimeStepValue", desc = "Get time step value", validate = function(v) return isFiniteNumber(v[1]) and v[1] > 0 end, fn = function() return getTimeStepValue() end },
        { name = "isPauseMenuActive", desc = "Is pause menu active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isPauseMenuActive() end },
        { name = "isInfraredVisionActive", desc = "Is night vision active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isInfraredVisionActive() end },
        { name = "isNightVisionActive", desc = "Is night vision goggles active", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isNightVisionActive() end },
        { name = "randomInt", desc = "Generate random int 1-100", validate = function(v) return isFiniteNumber(v[1]) end, fn = function() return randomInt(1, 100) end },
        { name = "randomFloat", desc = "Generate random float 0-1", validate = function(v) return isFiniteNumber(v[1]) end, fn = function() return randomFloat(0.0, 1.0) end },
    }},
    { category = "GTA Memory", tests = {
        { name = "readMemory", desc = "Verify readMemory bound", fn = function() return type(readMemory) == "function" end, isSynthetic = true },
        { name = "ReadFloat", desc = "Verify ReadFloat bound", fn = function() return type(ReadFloat) == "function" end, isSynthetic = true },
        { name = "ReadInt32", desc = "Verify ReadInt32 bound", fn = function() return type(ReadInt32) == "function" end, isSynthetic = true },
        { name = "ReadInt64", desc = "Verify ReadInt64 bound", fn = function() return type(ReadInt64) == "function" end, isSynthetic = true },
        { name = "ReadUInt16", desc = "Verify ReadUInt16 bound", fn = function() return type(ReadUInt16) == "function" end, isSynthetic = true },
        { name = "ReadUInt32", desc = "Verify ReadUInt32 bound", fn = function() return type(ReadUInt32) == "function" end, isSynthetic = true },
        { name = "getPointer", desc = "Verify getPointer bound", fn = function() return type(getPointer) == "function" end, isSynthetic = true },
    }},
    { category = "GTA Models", tests = {
        { name = "hasModelLoaded", desc = "Verify hasModelLoaded bound", fn = function() return type(hasModelLoaded) == "function" end, isSynthetic = true },
        { name = "isModelAvailable", desc = "Verify isModelAvailable bound", fn = function() return type(isModelAvailable) == "function" end, isSynthetic = true },
        { name = "isThisModelACar", desc = "Check if model 411 is a car", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isThisModelACar(411) end },
        { name = "isThisModelABoat", desc = "Check if model 472 is a boat", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isThisModelABoat(472) end },
        { name = "isThisModelAHeli", desc = "Check if model 425 is a heli", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isThisModelAHeli(425) end },
        { name = "isThisModelAPlane", desc = "Check if model 592 is a plane", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return isThisModelAPlane(592) end },
    }},
    { category = "SAMPFUNCS", tests = {
        { name = "sampIsChatInputActive", desc = "Check if chat input is active (actual name)", validate = function(v) return type(v[1]) == "boolean" end, fn = function() return sampIsChatInputActive() end },
        { name = "sampGetChatString", desc = "Get chatbox content (actual name)", fn = function() return sampGetChatString() end },
    }},
    { category = "RakNet", tests = {
        { name = "sampGetRpcPtr", desc = "Get RPC pointer", fn = function() return sampGetRpcPtr() end, validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "sampGetPacketPtr", desc = "Get packet pointer", fn = function() return sampGetPacketPtr() end, validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
        { name = "sampGetRakClientPtr", desc = "Get RakClient pointer", fn = function() return sampGetRakClientPtr() end, validate = function(v) return isFiniteNumber(v[1]) and v[1] >= 0 end },
    }},
    { category = "SAMP Sending", tests = {
        { name = "sampSendChat", desc = "Verify sampSendChat bound", fn = function() return type(sampSendChat) == "function" end, isSynthetic = true },
        { name = "sampSendCommand", desc = "Verify sampSendCommand bound", fn = function() return type(sampSendCommand) == "function" end, isSynthetic = true },
        { name = "sampRequestSpawn", desc = "Verify sampRequestSpawn bound", fn = function() return type(sampRequestSpawn) == "function" end, isSynthetic = true },
        { name = "sampSendSpawn", desc = "Verify sampSendSpawn bound", fn = function() return type(sampSendSpawn) == "function" end, isSynthetic = true },
        { name = "sampSpawnPlayer", desc = "Verify sampSpawnPlayer bound", fn = function() return type(sampSpawnPlayer) == "function" end, isSynthetic = true },
        { name = "sampSendDialogResponse", desc = "Verify dialog response sender bound", fn = function() return type(sampSendDialogResponse) == "function" end, isSynthetic = true },
        { name = "sampSendClickTextdraw", desc = "Verify textdraw click sender bound", fn = function() return type(sampSendClickTextdraw) == "function" end, isSynthetic = true },
        { name = "sampShowDialog", desc = "Verify show dialog is callable", fn = function() return type(sampShowDialog) == "function" end, isSynthetic = true },
    }},
}

local function collectUnlistedFunctions()
    local functions = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and type(value) == "function" and
            (name:find("^samp") or name:find("^get") or name:find("^set") or
             name:find("^is") or name:find("^does") or name:find("^create") or
             name:find("^delete") or name:find("^remove")) then
            functions[name] = true
        end
    end
    for _, group in ipairs(testCatalog) do for _, test in ipairs(group.tests) do functions[test.name] = nil end end
    local names = {}; for name in pairs(functions) do names[#names+1] = name end; table.sort(names); return names
end

-- ═══ Execution Engine ═══

-- ═══ Execution Engine ═══

local function executeTest(test, group, verbose)
    local globalFn = _G[test.name]
    local execFn = test.fn or globalFn
    local args = resolveArgs(group)
    local res
    if not execFn and not test.isSynthetic then
        res = {name=test.name, exists=false, ok=false, values={}, formatted="<not defined>", err="not defined"}
    else
        res = invokeBind(test.name, execFn, args)
        if res.ok then
            local valid, reason = validateResult(test, res.values)
            if not valid then res.ok = false; res.err = reason end
        end
    end
    res.category = group.category
    res.desc = test.desc
    allTestResults[test.name] = res
    if verbose then
        if not res.exists then
            totalMissing = totalMissing + 1
            addLog(string.format("  MISS  %s: not defined", test.name))
        elseif res.ok then
            totalPassed = totalPassed + 1
            if test.name == "sampGetPlayerHealth" or test.name == "sampGetPlayerArmor"
                or test.name == "getCharHealth" or test.name == "getCharArmour"
                or test.name == "sampGetPlayerPing" or test.name == "sampGetPlayerScore"
                or test.name == "sampGetPlayerWeapon" or test.name == "sampGetPlayerAmmo"
                or test.name == "sampGetPlayerVehicle" or test.name == "sampIsPlayerInVehicle"
                or test.name == "sampIsPlayerPaused" or test.name == "sampGetChatDisplayMode"
                or test.name == "sampIsChatInputActive" or test.name == "sampGetPlayerStructPtr" then
                addLog(string.format("  PASS  %s = %s", test.name, res.formatted))
            end
        else
            totalFailed = totalFailed + 1
            addLog(string.format("  FAIL  %s: %s", test.name, res.err or res.formatted))
        end
        totalTested = totalTested + 1
    end
    return res
end

local function runCategory(catIdx)
    local group = testCatalog[catIdx]
    if not group then return end
    addLog(string.format("[%d/%d] %s (%d tests)", catIdx, #testCatalog, group.category, #group.tests))
    for _, test in ipairs(group.tests) do
        executeTest(test, group, true)
    end
end

-- Read-only monitoring categories refreshed continuously when Live is enabled
local liveCategories = { 1, 2, 3, 4, 5, 8, 9, 10, 11, 14, 17 }

local function runLiveUpdate()
    for _, catIdx in ipairs(liveCategories) do
        local group = testCatalog[catIdx]
        if group then
            for _, test in ipairs(group.tests) do
                executeTest(test, group, false)
            end
        end
    end
    local t, p, f, m = 0, 0, 0, 0
    for _, r in pairs(allTestResults) do
        t = t + 1
        if not r.exists then m = m + 1
        elseif r.ok then p = p + 1
        else f = f + 1 end
    end
    totalTested, totalPassed, totalFailed, totalMissing = t, p, f, m
end

local function runAllTests()
    totalTested = 0; totalPassed = 0; totalFailed = 0; totalMissing = 0; allTestResults = {}
    addLog("=== SA-MP API Probe | Player: "..getTargetPlayer().." | Vehicle: "..getTargetVehicle().." ===")
    for i = 1, #testCatalog do runCategory(i) end
    addLog(string.format("TOTAL: %d | PASS: %d | FAIL: %d | MISS: %d", totalTested, totalPassed, totalFailed, totalMissing))
    local unlisted = collectUnlistedFunctions()
    if #unlisted > 0 then
        addLog("UNLISTED: "..#unlisted)
        for _, name in ipairs(unlisted) do addLog("  [UNLISTED] "..name) end
    end
    addLog("=== END ===")
    sendChatMessage(string.format("{00FF88}[Test]{FFFFFF} Done! Total: {00FFFF}%d{FFFFFF} Pass: {00FF00}%d{FFFFFF} Fail: {FF4444}%d{FFFFFF}", totalTested, totalPassed, totalFailed))
end

local function dumpAllValues()
    runAllTests()
    print("=== NEOMLOADER SA-MP API DIAGNOSTIC DUMP ===")
    print(string.format("TIME: %s | TOTAL: %d | PASS: %d | FAIL: %d", os.date("%H:%M:%S"), totalTested, totalPassed, totalFailed))
    for catIdx, group in ipairs(testCatalog) do
        print(string.format("\n-- [%d] %s --", catIdx, group.category))
        for _, test in ipairs(group.tests) do
            local res = allTestResults[test.name]
            local tag, val = "[?]", "<not invoked>"
            if res then
                if not res.exists then tag, val = "[MISS]", "<nil>"
                elseif res.ok then tag, val = "[PASS]", res.formatted or "nil"
                else tag, val = "[FAIL]", res.err or "error" end
            end
            local d = (test.desc and #test.desc > 0) and (" // " .. test.desc) or ""
            print(string.format("  %s %-32s %-32s%s", tag, test.name, val, d))
        end
    end
    print("=== END DUMP ===")
    sendChatMessage("{00FF88}[Test]{FFFFFF} Diagnostic report dumped to neomloader.log")
end

-- ═══ mimgui UI ═══

if hasMimgui and imgui and imgui.OnFrame then
    local themeApplied = false
    imgui.OnFrame(
        function() return showWindow and showWindow[0] end,
        function(player)
            if not themeApplied then
                local s = imgui.GetStyle()
                if s then
                    s.WindowRounding = dp(8)
                    s.FrameRounding = dp(5)
                    s.GrabRounding = dp(5)
                    s.ScrollbarRounding = dp(6)
                    s.ScrollbarSize = dp(16)
                    s.WindowPadding = imgui.ImVec2(dp(10), dp(8))
                    s.FramePadding = imgui.ImVec2(dp(8), dp(5))
                    s.ItemSpacing = imgui.ImVec2(dp(8), dp(5))
                    s.ItemInnerSpacing = imgui.ImVec2(dp(5), dp(4))
                end
                imgui.PushStyleColor(imgui.Col.WindowBg, 0.08,0.08,0.10,0.94)
                imgui.PushStyleColor(imgui.Col.ChildBg, 0.10,0.10,0.12,0.90)
                imgui.PushStyleColor(imgui.Col.Border, 0.25,0.25,0.30,0.60)
                imgui.PushStyleColor(imgui.Col.FrameBg, 0.14,0.14,0.18,0.90)
                imgui.PushStyleColor(imgui.Col.FrameBgHovered, 0.20,0.20,0.26,0.90)
                imgui.PushStyleColor(imgui.Col.Button, 0.18,0.40,0.50,0.80)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, 0.22,0.50,0.62,1.0)
                imgui.PushStyleColor(imgui.Col.ButtonActive, 0.16,0.42,0.54,1.0)
                imgui.PushStyleColor(imgui.Col.Header, 0.16,0.34,0.44,0.80)
                imgui.PushStyleColor(imgui.Col.HeaderHovered, 0.22,0.44,0.56,0.90)
                imgui.PushStyleColor(imgui.Col.HeaderActive, 0.14,0.38,0.48,1.0)
                imgui.PushStyleColor(imgui.Col.Text, 0.92,0.92,0.94,1.0)
                imgui.PushStyleColor(imgui.Col.TextDisabled, 0.50,0.50,0.54,1.0)
                themeApplied = true
            end
            local resX, resY = 1280, 720
            if imgui.GetMainViewport then
                local vp = imgui.GetMainViewport()
                if vp and vp.Size then resX, resY = vp.Size.x, vp.Size.y end
            end
            local initW = math.min(dp(850), resX - dp(24))
            local initH = math.min(dp(540), resY - dp(24))
            imgui.SetNextWindowSize(imgui.ImVec2(initW, initH), imgui.Cond.FirstUseEver)
            imgui.SetNextWindowPos(imgui.ImVec2(dp(12), dp(12)), imgui.Cond.FirstUseEver)
            if imgui.Begin("API Tester [NeoMLoader]", showWindow) then
                imgui.Separator()
                if imgui.Button("Run All", imgui.ImVec2(dp(80), dp(28))) then runAllTests() end
                imgui.SameLine()
                if imgui.Button("Dump", imgui.ImVec2(dp(60), dp(28))) then dumpAllValues() end
                imgui.SameLine()
                local isLive = liveMonitorEnabled and liveMonitorEnabled[0]
                if isLive then
                    imgui.PushStyleColor(imgui.Col.Button, 0.15, 0.65, 0.25, 0.90)
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, 0.20, 0.75, 0.35, 1.00)
                    imgui.PushStyleColor(imgui.Col.ButtonActive, 0.10, 0.55, 0.20, 1.00)
                else
                    imgui.PushStyleColor(imgui.Col.Button, 0.24, 0.26, 0.32, 0.85)
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, 0.32, 0.36, 0.45, 1.00)
                    imgui.PushStyleColor(imgui.Col.ButtonActive, 0.18, 0.20, 0.26, 1.00)
                end
                if imgui.Button(isLive and "Live: ON" or "Live: OFF", imgui.ImVec2(dp(85), dp(28))) then
                    if liveMonitorEnabled then
                        liveMonitorEnabled[0] = not liveMonitorEnabled[0]
                        if liveMonitorEnabled[0] then
                            addLog("Live monitoring enabled")
                        else
                            addLog("Live monitoring paused")
                        end
                    end
                end
                imgui.PopStyleColor(3)
                imgui.SameLine()
                if totalTested > 0 then
                    imgui.TextColored(0.5,0.5,0.55,1.0,"|"); imgui.SameLine()
                    imgui.TextColored(0.0,0.85,0.3,1.0, string.format("%d pass", totalPassed)); imgui.SameLine()
                    if totalFailed>0 then imgui.TextColored(0.95,0.3,0.2,1.0, string.format("%d fail", totalFailed)); imgui.SameLine() end
                    if totalMissing>0 then imgui.TextColored(0.75,0.5,0.0,1.0, string.format("%d miss", totalMissing)) end
                end
                imgui.Separator()
                imgui.SetNextItemWidth(dp(65)); if targetPlayerId then imgui.InputInt("PID", targetPlayerId, 0, 0) end
                imgui.SameLine(); imgui.SetNextItemWidth(dp(65)); if targetVehicleId then imgui.InputInt("VID", targetVehicleId, 0, 0) end
                imgui.SameLine()
                local filterWidth = imgui.GetWindowWidth() - imgui.GetCursorPosX() - dp(15)
                if filterWidth > dp(60) then imgui.SetNextItemWidth(filterWidth) end
                if searchFilter then imgui.InputText("##filter", searchFilter) end
                imgui.Separator()
                imgui.BeginChild("CatList", imgui.ImVec2(0,0), false)
                local filterText = ""; if searchFilter then filterText = tostring(searchFilter):lower() end
                for catIdx, group in ipairs(testCatalog) do
                    local hasMatch = #filterText == 0
                    if not hasMatch then
                        for _,test in ipairs(group.tests) do
                            if test.name:lower():find(filterText,1,true) or test.desc:lower():find(filterText,1,true) then
                                hasMatch = true; break
                            end
                        end
                    end
                    if hasMatch then
                        local catPass, catFail, catTotal = 0, 0, 0
                        for _,test in ipairs(group.tests) do
                            local r = allTestResults[test.name]
                            if r then
                                catTotal = catTotal + 1
                                if r.ok then catPass = catPass + 1 else catFail = catFail + 1 end
                            end
                        end
                        local icon, iR,iG,iB = " ", 0.5,0.5,0.55
                        if catTotal > 0 then
                            if catFail == 0 then icon = "v"; iR,iG,iB = 0.0,0.85,0.3
                            else icon = "x"; iR,iG,iB = 0.95,0.3,0.2 end
                        end
                        imgui.PushStyleColor(imgui.Col.Text, iR,iG,iB,1.0)
                        local clicked = imgui.CollapsingHeader(string.format("%s %s [%d/%d]###c%d", icon, group.category, catPass, catTotal, catIdx))
                        imgui.PopStyleColor()
                        if clicked then
                            local runBtnW = dp(55)
                            imgui.SameLine(imgui.GetWindowWidth() - runBtnW - dp(24))
                            if imgui.SmallButton(string.format("Run##%d", catIdx)) then runCategory(catIdx) end
                            imgui.Indent(dp(10))
                            for _, test in ipairs(group.tests) do
                                if #filterText > 0 then
                                    if not test.name:lower():find(filterText,1,true) and not test.desc:lower():find(filterText,1,true) then
                                        goto continue
                                    end
                                end
                                local res = allTestResults[test.name]
                                if not res then imgui.TextColored(0.4,0.4,0.45,1.0," - ")
                                elseif not res.exists then imgui.TextColored(0.7,0.35,0.0,1.0,"?  ")
                                elseif res.ok then imgui.TextColored(0.0,0.80,0.30,1.0,"v  ")
                                else imgui.TextColored(0.95,0.25,0.15,1.0,"x  ") end

                                imgui.SameLine()
                                imgui.TextColored(0.90,0.90,0.92,1.0, test.name)
                                if res and res.exists then
                                    imgui.SameLine()
                                    if res.ok then imgui.TextColored(0.3,0.80,0.90,0.95,"-> "..res.formatted)
                                    else imgui.TextColored(0.95,0.35,0.25,0.95,"-> "..tostring(res.err)) end
                                end
                                if test.desc and #test.desc > 0 then
                                    imgui.Indent(dp(16))
                                    imgui.TextColored(0.50,0.54,0.62,0.85, test.desc)
                                    imgui.Unindent(dp(16))
                                end
                                ::continue::
                            end
                            imgui.Unindent(dp(10)); imgui.Spacing()
                        end
                    end
                end
                imgui.EndChild()
            end
            imgui.End()
        end
    )
end

-- ═══ Chat Commands ═══

local function registerCommands()
    if type(sampRegisterChatCommand) ~= "function" then return end
    sampRegisterChatCommand("samptest", function(param)
        param = param and param:gsub("^%s*(.-)%s*$", "%1") or ""
        if param == "" or param == "gui" then
            if showWindow then showWindow[0] = not showWindow[0]
                sendChatMessage(string.format("{00FF88}[Test]{FFFFFF} GUI %s", showWindow[0] and "OPENED" or "CLOSED")) end
        elseif param == "run" then runAllTests()
        elseif param == "dump" then dumpAllValues()
        elseif param:sub(1,6) == "player" then
            local pid = tonumber(param:sub(7)) or getTargetPlayer()
            if targetPlayerId then targetPlayerId[0] = pid end
            sendChatMessage(string.format("{00FF88}[Test]{FFFFFF} Testing player %d...", pid)); runCategory(2)
        elseif param:sub(1,3) == "veh" then
            local vid = tonumber(param:sub(4)) or getTargetVehicle()
            if targetVehicleId then targetVehicleId[0] = vid end
            sendChatMessage(string.format("{00FF88}[Test]{FFFFFF} Testing vehicle %d...", vid)); runCategory(3)
        elseif param == "help" then
            sendChatMessage("{00FF88}--- SAMP API Testing Tool ---")
            sendChatMessage("{FFFFFF}/samptest          - Toggle GUI")
            sendChatMessage("{FFFFFF}/samptest run      - Run all tests")
            sendChatMessage("{FFFFFF}/samptest dump     - Full diagnostic dump")
            sendChatMessage("{FFFFFF}/samptest player N - Test player N")
            sendChatMessage("{FFFFFF}/samptest veh N    - Test vehicle N")
        else sendChatMessage("{FF8800}[Test]{FFFFFF} Unknown. Use '/samptest help'") end
    end)
    addLog("Chat command '/samptest' registered")
end

-- ═══ Lifecycle ═══

function main()
    if type(isSampLoaded) == "function" and type(wait) == "function" then
        while not isSampLoaded() do wait(200) end
    end
    registerCommands()
    addLog("SAMP API Testing Tool v2 initialized")
    runAllTests()
    if type(wait) == "function" then
        while true do
            wait(250)
            if liveMonitorEnabled and liveMonitorEnabled[0] then
                runLiveUpdate()
            end
        end
    end
end

if type(wait) ~= "function" then main() end

return { runAllTests=runAllTests, runCategory=runCategory, dumpAllValues=dumpAllValues, getResults=function() return allTestResults end }

SCRIPT_NAME = "VVS No Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Time accumulators
local timeAccumulator

-- Session start variables
local waitingToStartTimerOn
local waitingToTeleport

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message)
end

local function initializeSSStates()
    timeAccumulator = 0
    waitingToStartTimerOn = 0
    waitingToStart = false
    waitingToTeleport = false
   
end

local function initializeSCScript()
    writeLog("SC: Safety Car Script Initialized")

    if ac.tryToTeleportToPits() then
        ac.tryToOpenRaceMenu(nil)
        ac.disableQuickMenuPitstop(true)

    else
        writeLog("SC: Teleport to pits failed. Retrying...")
        waitingToTeleport = true
    end

end

function script.update(dt)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt
    ac.debug("NOSC: timeAccumulator", timeAccumulator)
   

    -- Session start sanity checks - if we are in a wait state and we have gone more than 1 second then reissue the command and reset the 1s timer
    if waitingToTeleport then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            if ac.tryToTeleportToPits() then
                waitingToTeleport = false
                writeLog("NOSC: Backup Teleportation to pit successful")
            end
        end
    end

end

ac.onSessionStart(function(sessionIndex, restarted)
    initializeSSStates()
    initializeSCScript()
    writeLog("SC: No Safety Car Script Initialized on Session Start")
end)

initializeSSStates()
initializeSCScript()

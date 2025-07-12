SCRIPT_NAME = "VVS No Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Time accumulators
local timeAccumulator

-- Session start variables
local waitingToInitTimer
local waitingToInit

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message)
end

local function initializeSSStates()
    timeAccumulator = 0
    waitingToInitTimer = 0
    waitingToInit = false
   
end

local function initializeSCScript()
    writeLog("SC: Safety Car Script Initialized")

    if ac.tryToTeleportToPits() then
        writeLog("SC: Teleport to pits successful")
        if ac.tryToOpenRaceMenu(nil) then
            writeLog("SC: Race Menu opened")
            if ac.disableQuickMenuPitstop(true) then
                writeLog("SC: menu disabled")
            else
                writeLog("SC: Disable menu failed. Retrying...")
                waitingToInit = true
            end
        else
            writeLog("SC: Race Menu failed to open. Retrying...")
            waitingToInit = true
        end
    else
        writeLog("SC: Teleport to pits failed. Retrying...")
        waitingToInit = true
    end

    waitingToInit = false
end

function script.update(dt)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt
    ac.debug("NOSC: timeAccumulator", timeAccumulator)
   

    -- Session start sanity checks - if we are in a wait state and we have gone more than 1 second then reissue the command and reset the 1s timer
    if waitingToInit then
        if timeAccumulator - waitingToInitTimer >= 5 then
            if ac.tryToOpenRaceMenu(nil) then
                writeLog("SC: Race Menu opened")
                if ac.tryToOpenRaceMenu(nil) then
                    writeLog("SC: Race Menu opened")
                    if ac.disableQuickMenuPitstop(true) then
                        writeLog("SC: menu disabled")
                        waitingToInit = false
                    else
                        waitingToInit = false
                        writeLog("SC: Disable menu failed. Retrying...")
                        waitingToInitTimer = timeAccumulator
                    end
                else
                    writeLog("SC: Race Menu failed to open. Retrying...")
                    waitingToInitTimer = timeAccumulator
                end
            else
                writeLog("SC: Teleport to pits failed. Retrying...")
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

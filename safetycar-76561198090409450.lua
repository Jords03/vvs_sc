SCRIPT_NAME = "VVS Safety Car Mark2"
SCRIPT_SHORT_NAME = "VVSSC2"
SCRIPT_VERSION = "0.0.1.01"
SCRIPT_VERSION_CODE = 00001

--local adminNames = {"Jon Astrop", "Dominic Fovargue", "Nigel Walters"}
--local safetyCarName = "Safety Car"
local adminNames = {"Jon Astrop", "Dominic Fovargue"}
local safetyCarName = "Nigel Walters"


local SC_CALLIN_THRESHOLD_START = 0.5
local SC_CALLIN_THRESHOLD_END = 0.75
local sim
local currentSession
local timeAccumulator

--latch variables
local waitingToInitialize = true

--shared data structure for real car data
local sharedData = ac.connect({
    ac.StructItem.key('vvs.car_tracker'),
    raceHasStarted = ac.StructItem.boolean(),
    activeCarsCount = ac.StructItem.int16(),
    safetyCarCallout = ac.StructItem.boolean(),
    carsArray = ac.StructItem.array(ac.StructItem.struct({
        carId = ac.StructItem.int16(),
        splinePosition = ac.StructItem.double(),
        distanceDriven = ac.StructItem.double(),
        isRetired = ac.StructItem.boolean()
      }),50)
    }, true, ac.SharedNamespace.Shared)

--utility function to write log messages
local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. SCRIPT_VERSION .. " | SCSS: " .. message)
end

--we will use scState to track the current state of the SC
--for rolling starts it will go: inactive -> waitingForRollingStart -> rolling -> rollingComingIn -> rollingInPitLane -> inactive
--for normal SC callouts it will go: inactive -> calledLeavingPits -> onTrackWaitingForLeader -> onTrackWaitingForPack -> onTrackComingIn -> calledInPitlane -> inactive
local scState = "inactive"
local safetyCar
local adminCars={}

--get the id of the SC
local function getSafetyCar()
    local safetyCarID = ac.getCarByDriverName(safetyCarName)
    if safetyCarID then
        safetyCar = ac.getCar(safetyCarID)
    else
        writeLog("ERROR Safety Car not found during initialization")
    end
    return nil
end

--populate table of admin car IDs
local function getAdminCars()
    for i,v in ipairs(adminNames) do
        local adminCarID = ac.getCarByDriverName(v)
        if adminCarID then
            table.insert(adminCars,adminCarID)
        else
            writeLog("ERROR Admin car not found during initialization")
        end
    end
    
    return nil
end

--verify we are initialised and have the SC identifier
local function ensureSimAndSafetyCar()
    if not sim or not safetyCar then
        writeLog("ERROR sim or safetyCar is nil")
        return false
    end
    return true
end

--set SC to given values
local function setSCValues(autopilotOn, scTopSpeed, pitStopRequest, lightsOn, throttleLimit, aggression)
    writeLog("Setting Safety car values...")
    physics.setCarAutopilot(autopilotOn, false)
    physics.setAIPitStopRequest(safetyCar.index, pitStopRequest)
    physics.setAITopSpeed(safetyCar.index, scTopSpeed)
    ac.setExtraSwitch(0, lightsOn)
    ac.setExtraSwitch(1, lightsOn)
    physics.setAIThrottleLimit(safetyCar.index, throttleLimit)
    physics.setAIAggression(safetyCar.index, aggression)
    writeLog("...Safety car values set - autoPilot: " .. tostring(autopilotOn) .. " | topSpeed: " .. tostring(scTopSpeed) .. " | pitStopReq: " .. tostring(pitStopRequest) .. " | lights: " .. tostring(lightsOn) .. " | throttleLimit: " .. tostring(throttleLimit) .. " | aggression: " + tostring(aggression))
end

--(re)init all variables
local function initialize()
    timeAccumulator = 0
    -- Get states
    sim = ac.getSim()
    currentSession = ac.getSession(sim.currentSessionIndex)
    getSafetyCar()
    getAdminCars()

    --init SC car control state
    setSCValues(false, 10, false, false, 0.65, 0.8)

    -- Set track length dependent thresholds
    local trackLength = sim.trackLengthM
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
        SC_CALLIN_THRESHOLD_END = 1 - (750 / trackLength)
        writeLog("SC: Longer track (" .. tostring(trackLength) .. "), thresholds set to - start: " .. tostring(SC_CALLIN_THRESHOLD_START) .. " | end: " .. tostring(SC_CALLIN_THRESHOLD_END))
    end

    scState = "inactive"
    waitingToInitialize = true
end

--called every frame
function script.update(dt)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt

    --log out session duration
    if currentSession then    
        writeLog("Session Duration: " .. tostring(currentSession.durationMinutes))
    end

    --init routine - teleport to pits, open race menu, start car
    if waitingToInitialize then
        if timeAccumulator > 1 then
            if ac.tryToTeleportToPits() then
                if ac.tryToOpenRaceMenu(nil) then
                    if ac.tryToStart() then
                        waitingToInitialize = false
                        writeLog("Safety Car Initialisation successful")
                    else
                        writeLog("WARNING: try to start failed")
                        return
                    end
                else
                    writeLog("WARNING: try to open race menu failed")
                    return
                end
            else
                writeLog("WARNING: try to teleport failed")
                return
            end
        end
    end
end

ac.onSessionStart(function(sessionIndex, restarted)
    writeLog("Safety Car Script Initializing")
    initialize()
    writeLog("Safety Car Script Initialized on Session Start")
end)

initialize()


SCRIPT_NAME = "VVS Safety Car Mark2"
SCRIPT_SHORT_NAME = "VVSSC2"
SCRIPT_VERSION = "0.0.1.012"
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
local waitTimer = 0

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
local scLapCountWhenCalledIn = -1

--message send retry stuff
local waitForSuccessfulSendTimer = -1
local lastMessage = ""

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

--send SC message and retry if fails
local function sendMessageWithRetry(message)
    if ac.sendChatMessage(message) then
        waitForSuccessfulSendTimer = -1
        lastMessage = ""
    else
        waitForSuccessfulSendTimer = timeAccumulator
        lastMessage = message
    end
end


--jump SC to start line to rectify stuck issues
local function jumpSCToStartLine()
    writeLog("Jumping SC to start line to rectify borking")

    local scTrackPos = 0

    local function normalize_position(C, L, R)
        if C <= L then
            return -1 + (C / L)  -- Map to -1 to 0
        else
            return 0 + ((C - L) / R)  -- Map to 0 to +1
        end
    end
    
    -- Get track sides and calculate total track width
    local scTrackSides = ac.getTrackAISplineSides(scTrackPos)
    local leftDistance = scTrackSides.x
    local rightDistance = scTrackSides.y
    local trackCenter = (leftDistance + rightDistance) / 2
    local normalizedTrackCenter = normalize_position(trackCenter, leftDistance, rightDistance)

    -- Calculate world coordinates
    local scTrackProgressWorld = ac.trackCoordinateToWorld(vec3(normalizedTrackCenter, 0, scTrackPos))

    local trackProgress = ac.worldCoordinateToTrackProgress(scTrackProgressWorld)
    local worldDirection = (ac.trackProgressToWorldCoordinate(trackProgress - 1 / sim.trackLengthM) - ac.trackProgressToWorldCoordinate(trackProgress)):normalize()

    -- Set the safety car position and orientation
    physics.setCarPosition(safetyCar.index, scTrackProgressWorld, worldDirection)

end

local scInactiveState = {
    autopilotOn = false,
    scTopSpeed = 10,
    pitStopRequest = false,
    lightsOn = false,
    throttleLimit = 0.65,
    aggression = 0.8
}

local scWaitingToRollingState = {
    autopilotOn = false,
    scTopSpeed = 10,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.65,
    aggression = 0.8
}

local scRollingState = {
    autopilotOn = true,
    scTopSpeed = 100,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scRollingComingInState = {
    autopilotOn = true,
    scTopSpeed = 180,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scRollingInPitLaneState = {
    autopilotOn = true,
    scTopSpeed = 25,
    pitStopRequest = true,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}

--set SC to given values
local function setSCValues(state)
    writeLog("Setting Safety car values...")

    local autopilotOn = state.autopilotOn
    local scTopSpeed = state.scTopSpeed
    local pitStopRequest = state.pitStopRequest
    local lightsOn = state.lightsOn
    local throttleLimit = state.throttleLimit
    local aggression = state.aggression

    physics.setCarAutopilot(autopilotOn, false)
    physics.setAIPitStopRequest(safetyCar.index, pitStopRequest)
    physics.setAITopSpeed(safetyCar.index, scTopSpeed)
    ac.setExtraSwitch(0, lightsOn)
    ac.setExtraSwitch(1, lightsOn)
    physics.setAIThrottleLimit(safetyCar.index, throttleLimit)
    physics.setAIAggression(safetyCar.index, aggression)
    writeLog("...Safety car values set - autoPilot: " .. tostring(autopilotOn) .. " | topSpeed: " .. tostring(scTopSpeed) .. " | pitStopReq: " .. tostring(pitStopRequest) .. " | lights: " .. tostring(lightsOn) .. " | throttleLimit: " .. tostring(throttleLimit) .. " | aggression: " .. tostring(aggression))
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
    setSCValues(scInactiveState)

    -- Set track length dependent thresholds
    local trackLength = sim.trackLengthM
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
        SC_CALLIN_THRESHOLD_END = 1 - (750 / trackLength)
        writeLog("SC: Longer track (" .. tostring(trackLength) .. "), thresholds set to - start: " .. tostring(SC_CALLIN_THRESHOLD_START) .. " | end: " .. tostring(SC_CALLIN_THRESHOLD_END))
    end

    --log out session duration
    if currentSession then    
        writeLog("Session Duration: " .. tostring(currentSession.durationMinutes))
    end

    scState = "inactive"
    waitingToInitialize = true

    waitForSuccessfulSendTimer = -1
    lastMessage = ""
end

--called every frame
function script.update(dt)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt

    --message resend
    if waitForSuccessfulSendTimer ~= -1 then
        if timeAccumulator - waitForSuccessfulSendTimer > 1 then
            writeLog("MESSAGE SEND FAILED - TRYING AGAIN")
            sendMessageWithRetry(lastMessage)
        end
    end

    --init routine - teleport to pits, open race menu, start car
    if waitingToInitialize then
        if timeAccumulator > 1 then
            if ac.tryToTeleportToPits() then
                if ac.tryToOpenRaceMenu(nil) then
                    if ac.tryToStart() then
                        waitingToInitialize = false
                        waitTimer = timeAccumulator
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

    --don't do anything for first 2 seconds after initialisation
    if timeAccumulator-waitTimer < 2 then
        return
    end

    --test harness to kick off rolling start
    --for rolling starts it will go: inactive -> waitingForRollingStart -> rolling -> rollingComingIn -> rollingInPitLane -> inactive
    if scState == "inactive" then
        jumpSCToStartLine()
        writeLog("SC State Transitioning from " .. scState .. " to waitingForRollingStart")
        scState = "waitingForRollingStart"
        setSCValues(scWaitingToRollingState)
        sendMessageWithRetry("SC: Safety Car rolling start")

        --test harness
        waitTimer = timeAccumulator
        
        return
    end

    --test harness - 2 secs after start jump start the rolling start
    if scState == "waitingForRollingStart" then
        if timeAccumulator-waitTimer < 2 then
            return
        end

        writeLog("SC State Transitioning from " .. scState .. " to rolling")
        scState = "rolling"
        setSCValues(scRollingState)

        return
    end

    --test harness - 10 secs after start call it in
    if scState == "rolling" then
        local scSplinePos = safetyCar.splinePosition
        if scSplinePos > SC_CALLIN_THRESHOLD_START and scSplinePos <= SC_CALLIN_THRESHOLD_END then
            writeLog("SC State Transitioning from " .. scState .. " to rollingComingIn")
            scState = "rollingComingIn"
            setSCValues(scRollingComingInState)
            sendMessageWithRetry("SC: Safety Car in this lap")
            scLapCountWhenCalledIn = safetyCar.lapCount
            writeLog("SC Lap count at call in is: " .. tostring(scLapCountWhenCalledIn))
            return
        else
            return
        end
    end

    --if SC coming in then wait until it enters the pit lane and send the clear message
    if scState == "rollingComingIn" then

        if scLapCountWhenCalledIn < safetyCar.lapCount then
                writeLog("Safety Car has not pitted when it should have!")
                writeLog("SC Missed pit lane - teleporting attempt")
                if ac.tryToTeleportToPits() then
                    writeLog("SC reset in pits successful")
                    writeLog("SC State Transitioning from " .. scState .. " to inactive")
                    scState = "inactiveX"
                    setSCValues(scInactiveState)
                    sendMessageWithRetry("SC: Safety Car is clear")
                    return
                else
                    writeLog("SC reset in pits failed")
                    return
                end
            end
        end

        if safetyCar.isInPitlane then 
            writeLog("SC State Transitioning from " .. scState .. " to rollingInPitLane")
            scState = "rollingInPitLane"
            setSCValues(scRollingInPitLaneState)
            sendMessageWithRetry("SC: Safety Car is clear")
            return
        else
            return
        end
    end

    --if SC has made it to the pit box then set as inactive
    if scState == "rollingInPitLane" then

        --sanity check, is SC speed has dropped to zero then deal with it
         if safetyCar.speedMs < 0.1 and not safetyCar.isInPit then
            writeLog("Safety Car has stopped unexpectedly!")
            writeLog("SC STOP - teleporting attempt")
            if ac.tryToTeleportToPits() then
                writeLog("SC reset in pits successful")
            else
                writeLog("SC reset in pits failed")
            end
        end

        if safetyCar.isInPit then
            writeLog("SC State Transitioning from " .. scState .. " to inactive")
            scState = "inactiveX"
            setSCValues(scInactiveState)
            return
        else
            return
        end
    end


end

ac.onSessionStart(function(sessionIndex, restarted)
    writeLog("Safety Car Script Initializing")
    initialize()
    writeLog("Safety Car Script Initialized on Session Start")
end)

initialize()


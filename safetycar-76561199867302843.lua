SCRIPT_NAME = "VVS Safety Car Mark2"
SCRIPT_SHORT_NAME = "VVSSC2"
SCRIPT_VERSION = "0.0.1.16"
SCRIPT_VERSION_CODE = 00016

local adminNames = {"Jon Astrop", "Dominic Fovargue", "Nigel Walters"}
local safetyCarName = "Safety Car"
--for local testing by Nigel
--local adminNames = {"Jon Astrop", "Dominic Fovargue"}
--local safetyCarName = "Nigel Walters"


local SC_CALLIN_THRESHOLD_START = 0.5
local SC_CALLIN_THRESHOLD_END = 0.75
local sim
local currentSession
local timeAccumulator
local startupWaitTimer = 0
local halfSecWaitTimer = 0
local halfSecStateCheckWaitTimer = 0
local scCalledLeavingPitsTimer = 0
--spline positions for easy lookup
local trustableSplinePostionsById = {}

--latch variables
local waitingToInitialize = true
local waitingToSendClearMessageBeforeInitialization = false

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
--for rolling starts it will go: inactive -> waitingForRollingStart -> rolling -> comingIn -> backToPitLane -> inactive
--for normal SC callouts it will go: inactive -> calledLeavingPits -> onTrackWaitingForLeader -> onTrackWaitingForCallIn -> comingIn -> backToPitLane -> inactive
local scState = "inactive"
local safetyCar
local adminCars={}
local scLapCountWhenCalledIn = -1
local scLapCountWhenCalledOut = -1

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

--utility function to check if a value is in a table
local function tableContains(testTable, value)
    for i = 1,#testTable do
      if (testTable[i] == value) then
        return true
      end
    end
    return false
  end

--Jump SC to strart line for rolling start
local function jumpSCtoStart()
    writeLog("Jumping SC to start for rolling start")
    local scMetersAhead = 25
    local scTrackPos = scMetersAhead / sim.trackLengthM

    --get spline pos of lead car
    local leadCarPosition = 99
    local leadCarSplinePos = -1

    for i, car in ac.iterateCars.ordered() do
        if car ~= safetyCar then
            local leaderboardPosition = ac.getCarLeaderboardPosition(car.index)
            if leaderboardPosition < leadCarPosition then
                leadCarPosition = leaderboardPosition
                leadCarSplinePos = car.splinePosition
            end
        end
    end
    --add that to the 25m offset for the SC car jump to position
    scTrackPos = scTrackPos + leadCarSplinePos
    --if this has sent it above 1 (i.e. if lead car is at spline 0.99x then normalise back to between 0 and 1)
    if scTrackPos >= 1 then
        scTrackPos = scTrackPos -1
    end

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
    autopilotOn = true,
    scTopSpeed = 100,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
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

local scComingInState = {
    autopilotOn = true,
    scTopSpeed = 180,
    pitStopRequest = true,
    lightsOn = false,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scBackToPitLaneState = {
    autopilotOn = true,
    scTopSpeed = 25,
    pitStopRequest = true,
    lightsOn = false,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scCalledLeavingPitsState = {
    autopilotOn = true,
    scTopSpeed = 60,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scOnTrackWaitingForLeaderState = {
    autopilotOn = true,
    scTopSpeed = 30,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}

local scOnTrackWaitingForCallInState = {
    autopilotOn = true,
    scTopSpeed = 100,
    pitStopRequest = false,
    lightsOn = true,
    throttleLimit = 0.5,
    aggression = 0.8
}


--set SC to given values
local function setSCValues(state, logValues)
    if logValues then
        writeLog("Setting Safety car values...")
    end

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

    --DOES NOT WORK
    --physics.disableCarCollisions(safetyCar.index, true, false)
    if logValues then
         writeLog("...Safety car values set - autoPilot: " .. tostring(autopilotOn) .. " | topSpeed: " .. tostring(scTopSpeed) .. " | pitStopReq: " .. tostring(pitStopRequest) .. " | lights: " .. tostring(lightsOn) .. " | throttleLimit: " .. tostring(throttleLimit) .. " | aggression: " .. tostring(aggression))
    end
end

--(re)init all variables
local function initialize()

    writeLog("Safety Car Script Initializing")

    timeAccumulator = 0
    scCalledLeavingPitsTimer = 0
    halfSecWaitTimer = 0
    halfSecStateCheckWaitTimer = 0
    startupWaitTimer = 0
    -- Get states
    sim = ac.getSim()
    currentSession = ac.getSession(sim.currentSessionIndex)
    getSafetyCar()
    getAdminCars()

    --init SC car control state
    setSCValues(scInactiveState, true)

    -- Set track length dependent thresholds
    local trackLength = sim.trackLengthM
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
        SC_CALLIN_THRESHOLD_END = 1 - (750 / trackLength)
        writeLog("Longer track (" .. tostring(trackLength) .. "), thresholds set to - start: " .. tostring(SC_CALLIN_THRESHOLD_START) .. " | end: " .. tostring(SC_CALLIN_THRESHOLD_END))
    end

    --log out session duration
    if currentSession then    
        writeLog("Session Duration: " .. tostring(currentSession.durationMinutes))
    end

    scState = "inactive"
    waitingToInitialize = true
    waitingToSendClearMessageBeforeInitialization = false

    waitForSuccessfulSendTimer = -1
    lastMessage = ""

    trustableSplinePostionsById = {}

    writeLog("Safety Car Script Initialized on Session Start")
end


-- For deciding if race is near complete
-- Calculates the average best lap time of up to three drivers on the leaderboard.
local function calculateAverageBestLapTime(session)
    if not (session and session.leaderboard and #session.leaderboard > 0) then
        writeLog("No drivers in the leaderboard to calculate the average.")
        return nil
    end

    local totalBestLapTimeMs = 0
    local driverCount = math.min(3, #session.leaderboard)

    for i = 0, driverCount - 1 do
        local entry = session.leaderboard[i]
        totalBestLapTimeMs = totalBestLapTimeMs + entry.bestLapTimeMs
    end

    local averageBestLapTimeMs = totalBestLapTimeMs / driverCount
    return averageBestLapTimeMs
end

-- For deciding if race is near complete
-- Calculates the session length and the time the SC should be active for
local function isTooLateForSC(lapsThreshold)
    if not currentSession then return false end

    local averageBestLapTime = calculateAverageBestLapTime(currentSession) or 0
    local sessionLength = 0

    if currentSession.isTimedRace then
        sessionLength = currentSession.durationMinutes * 60000
    else
        sessionLength = currentSession.laps * averageBestLapTime
    end
    if currentSession.hasAdditionalLap then
        sessionLength = sessionLength + averageBestLapTime
    end

    local scActiveTime = sessionLength - (averageBestLapTime * lapsThreshold)
    local csTime = sim.sessionTimeLeft * -1

    writeLog("Time check (Min Laps - " .. lapsThreshold .. "): AverageLaptime is - " .. averageBestLapTime .. ", Active Tiem Thresh is - " .. scActiveTime .. ", Session time is " .. csTime )

    if csTime > scActiveTime and scActiveTime > 0 then
        return true
    else
        return false
    end
end


--call SC out
--for normal SC callouts it will go: inactive -> calledLeavingPits -> onTrackWaitingForLeader -> onTrackWaitingForCallIn -> comingIn -> backToPitLane -> inactive
local function callSafetyCar()
    writeLog("Safety Car is being called")
    if not ensureSimAndSafetyCar() then 
        writeLog("ERROR Safety Car Broken!!")
        return
    end

    if scState ~= "inactive" then 
        writeLog("WARNING Cannot be called as not currently inactive")
        return
    end

    --session time check - parameter is the laps left needed
    if isTooLateForSC(4) then
        writeLog("WARNING Cannot be called as too late in session")
        return
    end


    writeLog("SC State Transitioning from " .. scState .. " to calledLeavingPits")
    scState = "calledLeavingPits"
    setSCValues(scCalledLeavingPitsState, true)
    scCalledLeavingPitsTimer = timeAccumulator

end

-- Calculate the normalized distance between two cars in forward direction ahead
local function calculateDistanceToSC(carPosition, car2Position)
    if carPosition > car2Position then
        car2Position = car2Position + 1
    end
    return car2Position - carPosition  -- Always a value between 0 and 1
end

-- Check if the Safety Car can come in based on the number of cars and their positions
local function canSafetyCarComeIn()

    writeLog("Call in check")

    --session time check - parameter is the laps left needed 2
    if isTooLateForSC(2) then
        writeLog("Safety Car is heading to pits as its too late in the session")
        return true
    end

    --if we are at the end then call it in whatever
    if sim.timeRaceEnded or sim.leaderLastLap then
        writeLog("Safety Car is heading to pits at end of session")
        return true
    end

    --if the SC has done more than 2 laps then call it in
    if safetyCar.lapCount - scLapCountWhenCalledOut >= 2 then
        writeLog("Safety Car is heading to pits as its been out for too many laps")
        return true
    end

    --track and build an array of active cars - to be active you must be going at over 10KMH
    --not be in the pits or the pit lane, and not be retired, and not be the SC 

    --array to build of active cars and array counter
    local activeCarCount = 0
    local activeCarArray = {}

    --step through all cars
    for i, car in ac.iterateCars.ordered() do
        --ignore SC
        if car ~= safetyCar then
            --10KMH check
            if car.speedKmh <= 10 then
                writeLog(car:driverName() .. " is too slow to be counted (under 10KMH)")
            else
                --pitlane check
                if car.isInPitlane or car.isInPit then
                    writeLog(car:driverName() .. " is in pitlane")
                else
                    --retired check
                    if car.isRetired then
                        writeLog(car:driverName() .. " is retired")
                    else
                        activeCarArray[activeCarCount] = car
                        activeCarCount = activeCarCount + 1
                    end
                end
            end
        end
    end
    writeLog("Active cars: " .. activeCarCount)

    --check if all active cars are within threshold - SC can only come in if ALL active cars are within the threshold
    local distanceThresholdMeters = (activeCarCount + 3) * 28
    --step across the acrive cars array and do the checks
    for pos=0,activeCarCount-1,1 do
        car = activeCarArray[pos]
        local distanceToSC = calculateDistanceToSC(trustableSplinePostionsById[car.index], trustableSplinePostionsById[safetyCar.index])
        local distanceMeters = distanceToSC * sim.trackLengthM
        if distanceMeters > distanceThresholdMeters then
            writeLog(car:driverName() .. " is too far behind, SC cannot come in")
            return false
        end
    end

    writeLog("All cars are within threshold, SC can come in")
    return true
end


-- Listen to chat messages calling SC deployment or manual SC control
local function processChatMessage(message, senderCarIndex)
    if senderCarIndex == safetyCar.index or (adminCars and tableContains(adminCars,senderCarIndex)) then
        if message == "SC scon" then
            writeLog("SC scon received | " .. "CarID: " .. senderCarIndex .. " | Name: " .. ac.getCar(senderCarIndex):driverName())
            callSafetyCar()
        elseif message == "SC kill" then
            writeLog("SC Killed - reinitializing")
            initialize()
        elseif message == "SC rolling" then
            --only do this if the race has not started yet
            if sharedData.raceHasStarted then
                writeLog("WARNING Rolling start called but race has already started, ignoring")
            else
                jumpSCtoStart()
                writeLog("SC State Transitioning from " .. scState .. " to waitingForRollingStart")
                scState = "waitingForRollingStart"
                setSCValues(scWaitingToRollingState, true)
                sendMessageWithRetry("SC: Safety Car rolling start")
            end
        elseif message == "SC teston" then
            writeLog("Safety Car Test On")
            sendMessageWithRetry("SC: Test On")
        elseif message == "SC testoff" then
            writeLog("Safety Car Test Off")
            sendMessageWithRetry("SC: Test Off")
        end
    end
    return true
end

--triggered when a message is received
ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    if string.startsWith(message, "SC") then
        writeLog("Chat msg received: " .. message .. " | Car ID: " .. senderCarIndex)
        return processChatMessage(message, senderCarIndex)
    else
        return true
    end
end)


--check no one is too near the SF line to let the SC jump out
local function checkNoOneNearSF()

    local scTrackPosMax = 1 - (400 / sim.trackLengthM)
    local scTrackPosMin = 50 / sim.trackLengthM

    for i, car in ac.iterateCars.ordered() do
        if car ~= safetyCar then
            if trustableSplinePostionsById[car.index] < scTrackPosMin or trustableSplinePostionsById[car.index] > scTrackPosMax then
                return false
            end
        end
    end

    return true
end

--refresh the spline list by car id
local function refreshSplineList()
    local trustableValues = sharedData.carsArray
    local activeCars = sharedData.activeCarsCount

    for pos=1,activeCars,1 do
        trustableSplinePostionsById[trustableValues[pos].carId] = trustableValues[pos].splinePosition
    end
end



-- Get the race leader behind the SC
local function getLeadingCarBehindSC()
    local leadingCarNotInPit = nil
    local distanceMeters = nil

    local trustableValues = sharedData.carsArray
    local activeCars = sharedData.activeCarsCount
    ac.debug("SC active cars:", activeCars)
    for pos=1,activeCars,1 do
        local car = ac.getCar(trustableValues[pos].carId)
        if car ~= nil then
            if not (car.isInPit or car.isInPitlane or car == safetyCar or trustableValues[pos].isRetired) then
                leadingCarNotInPit = car
                ac.debug("SC: Leading Car Behind SC: ", car:driverName())
                break
            end
        end
    end

    if leadingCarNotInPit then
        ac.debug("SC no lead car:", false)
        local scSplinePos = trustableSplinePostionsById[safetyCar.index]
        local carSplinePos = trustableSplinePostionsById[leadingCarNotInPit.index]
        local distance = calculateDistanceToSC(carSplinePos, scSplinePos)

        distanceMeters = distance * sim.trackLengthM
        ac.debug("SC: LC distance to SC:", distanceMeters)
        ac.debug("SC: scSplinePos:", scSplinePos)
    else
        ac.debug("SC no lead car:", true)
    end

    return leadingCarNotInPit, distanceMeters
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
                        startupWaitTimer = timeAccumulator
                        writeLog("Safety Car Initialisation successful")
                    else
                        writeLog("WARNING: try to start failed")
                    end
                else
                    writeLog("WARNING: try to open race menu failed")
                end
            else
                writeLog("WARNING: try to teleport failed")
            end
        end
        return
    end

    --don't do anything for first 1 seconds after initialisation
    if timeAccumulator-startupWaitTimer < 1 then
        return
    end

     -- Things we do every 0.5 (shorter) seconds
    if timeAccumulator - halfSecWaitTimer >= 0.5 then
    
        --check if the SC has been called out
        if sharedData.safetyCarCallout then
            sharedData.safetyCarCallout = false
            callSafetyCar()
            writeLog("SC scon received from shared data")
        end

        --refresh the trustable spline lists
        refreshSplineList()

        halfSecWaitTimer = timeAccumulator
    end


    --for rolling starts it will go: inactive -> waitingForRollingStart -> rolling -> comingIn -> backToPitLane -> inactive
    --for normal SC callouts it will go: inactive -> calledLeavingPits -> onTrackWaitingForLeader -> onTrackWaitingForCallIn -> comingIn -> backToPitLane -> inactive

    --sanity check - if state is inactive, if car is on track or moving then something is horribly wrong - initialize it
    if scState == "inactive" then

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scInactiveState, false)

            if not safetyCar.isInPitlane then
                writeLog("ERROR: Safety car is inactive but not in the pit!")
                initialize()
                if safetyCar.speedMs > 0.1 then
                    writeLog("ERROR: Safety car is inactive but is moving!")
                    initialize()
                end
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    --SC is leaving the pits after a callout - check for pit exit
    if scState == "calledLeavingPits" then

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scCalledLeavingPitsState, false)

            --happy path - SC manages to leave the pits - this will also get invoked if it borks and is jumped out
            if not safetyCar.isInPitlane then
                writeLog("SC State Transitioning from " .. scState .. " to onTrackWaitingForLeader")
                scState = "onTrackWaitingForLeader"
                setSCValues(scOnTrackWaitingForLeaderState, true)
                sendMessageWithRetry("SC: Safety Car deployed")
                scLapCountWhenCalledOut = safetyCar.lapCount
                halfSecStateCheckWaitTimer = timeAccumulator
                return
            end

            --wait 1 second after the call out - if we aren't moving then we are borked so jump the SC to the start
            if timeAccumulator - scCalledLeavingPitsTimer > 1 then
                if safetyCar.speedMs < 0.2 then
                    writeLog("SC Borked, falling back to jump to track")
                    if checkNoOneNearSF() then
                        --jump the SC to the start finish line
                        writeLog("Track clear, jumping SC to start finish")
                        jumpSCToStartLine()
                    end
                end
            end

            --if we couldn't find a space, or somehow it's just not left the pits after 2 mins then abort
            if timeAccumulator - scCalledLeavingPitsTimer >= 120 then
                writeLog("Did not find a space to deploy borked SC after 2 minutes, aborting")
                writeLog("SC State Transitioning from " .. scState .. " to inactive")
                scState = "inactive"
                setSCValues(scInactiveState, true)
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    --sc is waiting for leader to catch up 
    if scState == "onTrackWaitingForLeader" then

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scOnTrackWaitingForLeaderState, false)
    
            local lc, lcDistance = getLeadingCarBehindSC()
            if lc then
                local lcSpeed = math.max(lc.speedKmh, 100)
                local scSpeedUpDistance = (lcSpeed * 120) / 100

                if lcDistance <= scSpeedUpDistance then
                    writeLog("Leader gap to Safety Car within threshold : " .. lcDistance .. "m @" .. lcSpeed)
                    writeLog("SC State Transitioning from " .. scState .. " to onTrackWaitingForCallIn")
                    scState = "onTrackWaitingForCallIn"
                    setSCValues(scOnTrackWaitingForCallInState, true)
                end
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    --sc is waiting for pack to catch up 
    if scState == "onTrackWaitingForCallIn" then

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scOnTrackWaitingForCallInState, false)

            local scSplinePos = safetyCar.splinePosition
            if scSplinePos > SC_CALLIN_THRESHOLD_START and scSplinePos <= SC_CALLIN_THRESHOLD_END then
                if canSafetyCarComeIn() then
                    writeLog("SC State Transitioning from " .. scState .. " to comingIn")
                    scState = "comingIn"
                    setSCValues(scComingInState, true)
                    scLapCountWhenCalledIn = safetyCar.lapCount
                    sendMessageWithRetry("SC: Safety Car in this lap")
                end
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    
    --that's the main loop for the SC done, next cover the rolling start main loop


    --Setting SC rolling start values 15 secs before race start
    if scState == "waitingForRollingStart" then

        if sim.timeToSessionStart <= 15000 then
            writeLog("SC State Transitioning from " .. scState .. " to rolling")
            scState = "rolling"
            setSCValues(scRollingState, true)
            sendMessageWithRetry("SC: Safety Car rolling start")
        end
        return
    end

    --SC is rolling round for the rolling start (or waiting for the green light for race start), once it gets within the threshold then call it back to pits
    if scState == "rolling" then

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scRollingState, false)

            local scSplinePos = safetyCar.splinePosition
            if scSplinePos > SC_CALLIN_THRESHOLD_START and scSplinePos <= SC_CALLIN_THRESHOLD_END then
                writeLog("SC State Transitioning from " .. scState .. " to comingIn")
                scState = "comingIn"
                setSCValues(scComingInState, true)
                sendMessageWithRetry("SC: Safety Car Rolling Start Coming In")
                scLapCountWhenCalledIn = safetyCar.lapCount
                writeLog("SC Lap count at call in is: " .. tostring(scLapCountWhenCalledIn))
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    --thats the rolling start stuff done, now deal with the end of the loops and the car coming back in to pits

    --if SC coming in then wait until it enters the pit lane and send the clear message
    if scState == "comingIn" then

        --check if we are still trying to send the clear message - once it's successfully sent then initialize
        if waitingToSendClearMessageBeforeInitialization then
            if waitForSuccessfulSendTimer == -1 then
                writeLog("SC State Transitioning from " .. scState .. " to inactive (via reinitialization)")
                initialize()
            end
        end

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scComingInState, false)

            if scLapCountWhenCalledIn < safetyCar.lapCount then
                writeLog("Safety Car has not pitted when it should have!")
                writeLog("SC Missed pit lane - teleporting attempt")
                if ac.tryToTeleportToPits() then
                    writeLog("SC reset in pits successful")
                    
                    sendMessageWithRetry("SC: Safety Car is clear")

                    --here we want to initialize to reset the SC - we can't do it immediately though as we don't know for sure
                    --that the clear message has successfully been sent - set this latch then on the next frames
                    --test for successful transmission and then initialize
                    waitingToSendClearMessageBeforeInitialization = true

                    halfSecStateCheckWaitTimer = timeAccumulator
                    return
                else
                    writeLog("SC reset in pits failed")
                    halfSecStateCheckWaitTimer = timeAccumulator
                    return
                end
            end

            if safetyCar.isInPitlane then 
                writeLog("SC State Transitioning from " .. scState .. " to backToPitLane")
                scState = "backToPitLane"
                setSCValues(scBackToPitLaneState, true)
                sendMessageWithRetry("SC: Safety Car is clear")
            end

           halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

    --if SC has made it to the pit box then set as inactive
    if scState == "backToPitLane" then

        --SC likes to crash as it enters its pit box, detect this based on the steering angle and just jump it to pits
        if safetyCar.speedKmh < 20 and (safetyCar.steer < 3 or safetyCar.steer > -3) and not safetyCar.isInPit then
            writeLog("SC PIT BOX HACK - teleporting attempt")
            if ac.tryToTeleportToPits() then
                writeLog("SC reset in pits successful")
            else
                writeLog("SC reset in pits failed")
            end
        end

        --only do this every 0.5 secs
        if timeAccumulator - halfSecStateCheckWaitTimer >= 0.5 then

            --reapply the current state to ensure it's set
            setSCValues(scBackToPitLaneState, false)

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

            --once we are back in the pit box (whether jumped there or driven there) then reinitialize
            if safetyCar.isInPit then
                writeLog("SC State Transitioning from " .. scState .. " to inactive (via a reinitializtion)")
                initialize()
            end

            halfSecStateCheckWaitTimer = timeAccumulator
        end
        return
    end

end

ac.onSessionStart(function(sessionIndex, restarted)
    initialize()
end)

initialize()


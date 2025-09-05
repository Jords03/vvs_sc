
SCRIPT_NAME = "VVS Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Edit this on per event basis?
local startBehindSC = false
-- Initialize rolling start boolean
local rollingStart = startBehindSC

-- Get states
local sim = ac.getSim()
local currentSession = ac.getSession(sim.currentSessionIndex)
local safetyCarName = "Safety Car"
local adminNames = {"Jon Astrop", "Dominic Fovargue", "Nigel Walters"}

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


local safetyCarID
local safetyCar
local adminCarID
local adminCars={}

-- Safety Car Speeds and thresholds
local trackLength
local safetyCarPitLaneSpeed
local safetyCarInitialSpeed
local safetyCarSpeed
local safetyCarInSpeed
local safetyCarPitInSpeed
local scLeadDistThresholdMin
local distanceThresholdMeters
local carSpacing
local inPitTimeLimit
local carsInPit
local activeCarCount
local activeCarArray
local retiredCars
local previousGapToSC
local carsNotGainingOnSC
local gainingTimeThreshold
local minConnectedCars
local normTrackCenter

-- Time accumulators
local timeHalfSec
local timeHalfSecAccumulator
local timeShort
local timeShortAccumulator
local timeAccumulator
local timeMedium
local timeMediumAccumulator
local timeLong
local timeLongAccumulator

-- Session start variables
local waitingToStartTimerOn
local waitingToStart
local waitingToRollingStart
local waitingToTeleport
local scActive
local scActiveTime
local scActiveCheckStartPercentage
local gotAvgSessionTimes
local checkClosestCarToSC

-- Check Thresholds
local scDisableWithLapsToGo
local SC_CALLIN_THRESHOLD_START
local SC_CALLIN_THRESHOLD_END

-- Base state variables
local scInPitLane
local scOnTrack
local scRequested
local scHeadingToPit
local scConditonsMet
local scManualCallIn
local checkLeaderPos
local underSCLapCount
local scPrevLapCount
local scMaxLapsOut
local raceLeader
local resetBrakeInPitHack
local resetBrakeInPitHackSuccess

--spline positions for easy lookup
local trustableSplinePostionsById = {}

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " |D " .. message)
end

local function getSafetyCar()
    safetyCarID = ac.getCarByDriverName(safetyCarName)
    if safetyCarID then
        safetyCar = ac.getCar(safetyCarID)
    else
        writeLog("SC: Safety Car not found during initialization")
    end
    return nil
end

local function getAdminCar()
    for i,v in ipairs(adminNames) do
        adminCarID = ac.getCarByDriverName(v)
        if adminCarID then
            table.insert(adminCars,adminCarID)
        else
            writeLog("SC: Admin car not found during initialization")
        end
    end
    
    return nil
end


local function ensureSimAndSafetyCar()
    if not sim or not safetyCar then
        writeLog("SC: sim or safetyCar is nil")
        return false
    end
    --[[
    if sim.raceSessionType ~= 3 then
        writeLog("SC: Not a race session = " .. sim.raceSessionType)
        return false
    end
    ]]
    --[[ if sim.connectedCars < (minConnectedCars + 1) then
        writeLog("SC: Not enough cars connected")
        return false
    end ]]

    return true
end

local function initializeSSStates()
    -- Get states
    sim = ac.getSim()
    currentSession = ac.getSession(sim.currentSessionIndex)
    getSafetyCar()
    getAdminCar()

    -- Safety Car Speeds and thresholds
    trackLength = sim.trackLengthM
    safetyCarPitLaneSpeed = 60
    safetyCarInitialSpeed = 30
    safetyCarSpeed = 100 -- Speed in km/h
    safetyCarInSpeed = 180
    safetyCarPitInSpeed = 25
    scLeadDistThresholdMin = 120 -- update to adjust to speed of leader
    distanceThresholdMeters = 500 -- replaced by N/connected cars calc
    carSpacing = 28 -- multiplier for distance behind SC N x carSpacing
    inPitTimeLimit = 120 -- seconds
    carsInPit = 0
    activeCarCount = 0
    activeCarArray = {}
    retiredCars = {}
    previousGapToSC = {}
    carsNotGainingOnSC = 0
    gainingTimeThreshold = 2
    minConnectedCars = 1

    -- Time accumulators
    timeHalfSec = 0.5 -- seconds
    timeHalfSecAccumulator = 0
    timeShort = 1.5
    timeShortAccumulator = 0
    timeAccumulator = 0
    timeMedium = 3
    timeMediumAccumulator = 0
    timeLong = 10
    timeLongAccumulator = 0

    -- Session start variables
    rollingStart = startBehindSC
    waitingToStartTimerOn = 0
    waitingToStart = false
    waitingToRollingStart = false
    waitingToTeleport = false
    scActive = true
    scActiveTime = 0
    scActiveCheckStartPercentage = 0.5
    gotAvgSessionTimes = false
    checkClosestCarToSC = false

    -- Check Thresholds
    scDisableWithLapsToGo = 2
    SC_CALLIN_THRESHOLD_START = 0.5
    SC_CALLIN_THRESHOLD_END = 0.75

    -- Base state variables
    scInPitLane = true
    scOnTrack = false
    scRequested = false
    scHeadingToPit = false
    scConditonsMet = false
    scManualCallIn = false
    rollingStart = startBehindSC
    checkLeaderPos = false
    underSCLapCount = 0
    scPrevLapCount = 0
    scMaxLapsOut = 2
    raceLeader = nil
    resetBrakeInPitHack = false
    resetBrakeInPitHackSuccess = false

    trustableSplinePostionsById = {}

end


local function setSCValues(scSpeed)    
    physics.setCarAutopilot(true, false)
    physics.setAIPitStopRequest(safetyCar.index, false)
    physics.setAIThrottleLimit(safetyCar.index, 0.65)
    physics.setAITopSpeed(safetyCar.index, scSpeed)
    physics.setAIAggression(safetyCar.index, 0.8)
    writeLog("SC: SC values set")
end

local resetSCValues = function()
    physics.setCarAutopilot(false, false)
    physics.setAIPitStopRequest(safetyCar.index, false)
    physics.setAIThrottleLimit(safetyCar.index, 0.65)
    physics.setAITopSpeed(safetyCar.index, safetyCarSpeed)
    physics.setAIAggression(safetyCar.index, 0.8)
    writeLog("SC: SC values reset")
end

local function setSCSpeedUpValue()
    physics.setAITopSpeed(safetyCar.index, safetyCarSpeed)
end

local function setSCRequestPit()
    physics.setCarAutopilot(true, false)
    physics.setAITopSpeed(safetyCar.index, safetyCarInSpeed)
    physics.setAIPitStopRequest(safetyCar.index, true)
end

local function setSCRollingValues()
    physics.setCarAutopilot(true, false)
    --physics.setAIPitStopRequest(safetyCar.index, true)
    physics.setAIThrottleLimit(safetyCar.index, 0.5)
    physics.setAITopSpeed(safetyCar.index, safetyCarSpeed)
    physics.setAIAggression(safetyCar.index, 0.8)
end

local function setPitInSpeed()
    physics.setAITopSpeed(safetyCar.index, safetyCarPitInSpeed)
    physics.setAIPitStopRequest(safetyCar.index, true)
    -- TODO: Hacky slowdown in pitlane
    writeLog("SC: Hacking brake in pit")
    resetBrakeInPitHack = true
end

local function setSCLights(state)
    if state == "on" then
        --[[ if scOnTrack then
            ac.setExtraSwitch(0, false)
            ac.setExtraSwitch(1, true)
        else
            ac.setExtraSwitch(0, true)
            ac.setExtraSwitch(1, false)
        end ]]
        ac.setExtraSwitch(0, true)
        ac.setExtraSwitch(1, true)
    elseif state == "off" then
        ac.setExtraSwitch(0, false)
        ac.setExtraSwitch(1, false)
    end
end

local function jumpSCtoStart()
    writeLog("SC: Jumping SC to start")
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

    local splineAhead = (scMetersAhead + 1) / sim.trackLengthM

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
    normTrackCenter = normalizedTrackCenter

    -- Calculate world coordinates
    local scTrackProgressWorld = ac.trackCoordinateToWorld(vec3(normalizedTrackCenter, 0, scTrackPos))
    local splineAheadWorld = ac.trackCoordinateToWorld(vec3(normalizedTrackCenter, 0, splineAhead))

    local trackProgress = ac.worldCoordinateToTrackProgress(scTrackProgressWorld)
    local worldDirection = (ac.trackProgressToWorldCoordinate(trackProgress - 1 / sim.trackLengthM) - ac.trackProgressToWorldCoordinate(trackProgress)):normalize()

    -- Set the safety car position and orientation
    --physics.setCarPosition(safetyCar.index, scTrackProgressWorld, splineAheadWorld)
    physics.setCarPosition(safetyCar.index, scTrackProgressWorld, worldDirection)

    --[[ 
    ac.debug("SC: Jump to", scTrackPos)
    ac.debug("SC: Jump to splineAheadWorld", splineAheadWorld)
    ac.debug("SC: Jump to scTrackProgressWorld", scTrackProgressWorld)
    ac.debug("SC: Jump to SplineAhead", splineAhead)
    ac.debug("SC: SplinePos", safetyCar.splinePosition)
    ac.debug("SC: scTrackSides", scTrackSides)
    ac.debug("SC: trackWidth", trackCenter)
    ac.debug("SC: normalizedTrackCenter", normalizedTrackCenter)
    ]]
end

local function initializeSCScript()
    writeLog("SC: Safety Car Script Initialized")

    physics.setCarAutopilot(false, false)

    scRequested = false
    scHeadingToPit = false
    rollingStart = false

    getAdminCar()

    if ac.tryToTeleportToPits() then
        ac.tryToOpenRaceMenu(nil)
        ac.disableQuickMenuPitstop(true)
        --Forcing a slight delay to allow for teleport for rolling starts
        waitingToStart = true

    else
        writeLog("SC: Teleport to pits failed. Retrying...")
        waitingToTeleport = true
    end

    -- Set track length dependent thresholds
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
        SC_CALLIN_THRESHOLD_END = 1 - (750 / trackLength)
    end
end

local function callSafetyCar()
    if not ensureSimAndSafetyCar() then return end
    if scActive and not rollingStart then
        if safetyCar.isInPitlane and not safetyCar.isInPit then
            writeLog("SC: Re-initialization while in pitlane")
            initializeSSStates()
            initializeSCScript()
        end
        writeLog("SC: Safety Car is being called")
        scRequested = true
        scHeadingToPit = false
        scOnTrack = false
        scInPitLane = true

        setSCValues(safetyCarPitLaneSpeed)
        setSCLights("on")
    else
        writeLog("SC: Safety Car cannot be deployed - too late in race")
    end
end

--XXXXXXJUMP
local function callSafetyCarWithJump()
    if not ensureSimAndSafetyCar() then return end
    if scActive and not rollingStart then
        if safetyCar.isInPitlane and not safetyCar.isInPit then
            writeLog("SC: Re-initialization while in pitlane")
            initializeSSStates()
            initializeSCScript()
        end
        writeLog("SC: Safety Car is being called")
        scRequested = true
        scHeadingToPit = false
        scOnTrack = false
        scInPitLane = true

        --jump the safety car
        writeLog("jumping safety car6")

        local carPosition = safetyCar.position
        
        writeLog("Car Pos: " .. carPosition.x .. "," .. carPosition.y .. "," .. carPosition.z)

        -- Calculate world coordinate
        local trackProgress = ac.worldCoordinateToTrackProgress(carPosition)
        local worldDirection = (ac.trackProgressToWorldCoordinate(trackProgress - 1 / sim.trackLengthM) - ac.trackProgressToWorldCoordinate(trackProgress)):normalize()

        local newPosition = vec3(carPosition.x + 7, carPosition.y + 0.2, carPosition.z - 30)
        
        writeLog("New World Dir: " .. worldDirection.x .. "," .. worldDirection.y .. "," .. worldDirection.z)
        
        --physics.setCarPosition(safetyCar.index, newPosition, worldDirection)
        jumpSCtoStart()
        physics.setCarPosition(safetyCar.index, carPosition, worldDirection)

        writeLog("safety car jumped")
        --physics.setCarPosition(safetyCar.index, safetyCar.position:add(-1,0,0), vec3(1,0,0))

        setSCValues(safetyCarPitLaneSpeed)
        setSCLights("on")
    else
        writeLog("SC: Safety Car cannot be deployed - too late in race")
    end
end

local function tableContains(testTable, value)
    for i = 1,#testTable do
      if (testTable[i] == value) then
        return true
      end
    end
    return false
  end

-- Listen to chat messages calling SC deployment or manual SC control
local function processChatMessage(message, senderCarIndex)
    if senderCarIndex == safetyCar.index or (adminCars and tableContains(adminCars,senderCarIndex)) then
        if message == "SC scon" then
            callSafetyCar()
            writeLog("SC: SC scon received | " .. "CarID: " .. senderCarIndex .. " | Name: " .. ac.getCar(senderCarIndex):driverName())
        --XXXXXXJUMP
        elseif message == "SC sconj" then
            callSafetyCarWithJump()
            writeLog("SC: SC sconj received | " .. "CarID: " .. senderCarIndex .. " | Name: " .. ac.getCar(senderCarIndex):driverName())
        elseif message == "SC jump" then
            jumpSCtoStart()
        elseif message == "SC scoff" then
            scManualCallIn = true
            --rollingStart = false
            scConditonsMet = true
            scHeadingToPit = true
            scRequested = false
            setSCRequestPit()
            setSCLights("off")
            writeLog("SC: Safety Car is manually called in")
        elseif message == "SC kill" then
            initializeSCScript()
        elseif message == "SC rolling" then
            jumpSCtoStart()
            rollingStart = true
            waitingToRollingStart = true
        end
    end
    return true
end

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    writeLog("SC: Chat Msg: " .. message .. " | Car ID: " .. senderCarIndex)
    return processChatMessage(message, senderCarIndex)
end)

-- Calculate the normalized distance between two cars in forward direction ahead
local function calculateDistanceToSC(carPosition, car2Position)
    if carPosition > car2Position then
        car2Position = car2Position + 1
    end
    return car2Position - carPosition  -- Always a value between 0 and 1
end

-- Update car statuses and gaps to SC
local function updateCarStatuses()
    local scSplinePos = trustableSplinePostionsById[safetyCar.index]

    ac.debug("SC: activeCarCount", activeCarCount)
    activeCarCount = 0
    carsInPit = 0
    carsNotGainingOnSC = 0
    activeCarArray = {}

    for i, car in ac.iterateCars.ordered() do
        if car ~= safetyCar then
            -- Update pit times or retirement status
            if car.speedKmh > 10 then
                if car.isInPitlane then
                    ac.debug("SC: " .. car:driverName() .. " is in pitlane", true)
                    carsInPit = carsInPit + 1
                else
                    ac.debug("SC: " .. car:driverName() .. " is on track", true)
                    activeCarArray[activeCarCount] = car
                    activeCarCount = activeCarCount + 1

                    -- Update car's gaps to SC
                    local carSplinePos = trustableSplinePostionsById[car.index]
                    local distanceToSC = calculateDistanceToSC(carSplinePos, scSplinePos)
                    local secondsAhead = distanceToSC * trackLength / math.max(safetyCar.speedMs, 0.1)
                    local previousSecondsAhead = previousGapToSC[car.index] or secondsAhead
                    local isGaining = secondsAhead < previousSecondsAhead or secondsAhead < 15

                    previousGapToSC[car.index] = secondsAhead
                    --TODO: this doesn't seem right in terms of secs ahead
                    writeLog("SC: " .. car:driverName() .. " | SecAhead: " .. math.floor(secondsAhead) .. " | isGaining: " .. tostring(isGaining))

                    if not isGaining and ((secondsAhead - previousSecondsAhead) > gainingTimeThreshold) then
                        carsNotGainingOnSC = carsNotGainingOnSC + 1
                    end
                end
            elseif car.isInPit or car.isInPitlane then
                if not sharedData.carsArray[car.index].isRetired then             
                    writeLog("SC: " .. car:driverName() .. " is retired")
                    carsInPit = carsInPit + 1
                end
            end
        end
    end
    writeLog("SC: Cars in pit: " .. carsInPit)
    writeLog("SC: Active cars: " .. activeCarCount)
    writeLog("SC: Cars not gaining on SC: " .. carsNotGainingOnSC)
end

-- Check if the Safety Car can come in based on the number of cars and their positions
local function canSafetyCarComeIn()

    updateCarStatuses()

    --local connectedCars = sim.connectedCars
    --local carsNotGainingCount = carsNotGainingOnSC and #carsNotGainingOnSC or 0
    --local N = connectedCars - retiredCarsCount - carsNotGainingCount - 1

    local N = activeCarCount - carsInPit - carsNotGainingOnSC
    local carsNearAndBehindSC = 0

    distanceThresholdMeters = (N + 3) * carSpacing

    ac.debug("SC: COMEIN? N (Cars) ", N)
    ac.debug("SC: COMEIN? Active Cars", activeCarCount)
    ac.debug("SC: COMEIN? Distance Threshold", distanceThresholdMeters)
    ac.debug("SC: COMEIN? Cars in Pit", carsInPit)
    ac.debug("SC: COMEIN? Cars Not Gaining", carsNotGainingOnSC)

    for pos=0,activeCarCount-1,1 do
        car = activeCarArray[pos]
        if carsNearAndBehindSC >= N then
            break
        end
        local distanceToSC = calculateDistanceToSC(trustableSplinePostionsById[car.index], trustableSplinePostionsById[safetyCar.index])
        local distanceMeters = distanceToSC * trackLength
        if car and distanceMeters < distanceThresholdMeters then
            carsNearAndBehindSC = carsNearAndBehindSC + 1
        end
    end
    --writeLog("SC: carsNearAndBehindSC = " .. carsNearAndBehindSC)
    ac.debug("SC: COMEIN? CarsNearAndBehindSC", carsNearAndBehindSC)
    local result = carsNearAndBehindSC >= N
    ac.debug("SC: COMEIN? SC can come in", result)
    --writeLog(result and "SC: Safety Car can come in this lap." or "SC: Not all cars are within threshold the Safety Car.")
    return result
end

-- For deciding if race is near complete
-- Calculates the average best lap time of up to three drivers on the leaderboard.
local function calculateAverageBestLapTime(session)
    if not (session and session.leaderboard and #session.leaderboard > 0) then
        writeLog("SC: No drivers in the leaderboard to calculate the average.")
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
-- Calculates the session length and the time the SC should be active for`2
local function sessionTimeCalcs()
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

    scActiveTime = sessionLength - (averageBestLapTime * scDisableWithLapsToGo)

    writeLog("SC: Average Best Lap Time: " .. averageBestLapTime)
    writeLog("SC: Session Length: " .. sessionLength)
end

-- Get the race leader behind the SC
local function getLeadingCarBehindSC()
    local leadingCarNotInPit = nil
    local distanceMeters = nil

    local trustableValues = sharedData.carsArray
    local activeCars = sharedData.activeCarsCount

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
        local scSplinePos = trustableSplinePostionsById[safetyCar.index]
        local carSplinePos = trustableSplinePostionsById[leadingCarNotInPit.index]
        local distance = calculateDistanceToSC(carSplinePos, scSplinePos)

        distanceMeters = distance * trackLength
        --ac.debug("SC: LC distance to SC:", distanceMeters)
        --ac.debug("SC: scSplinePos:", scSplinePos)
    end

    return leadingCarNotInPit, distanceMeters
end

--refresh the spline list by car id
local function refreshSplineList() 
    local trustableValues = sharedData.carsArray
    local activeCars = sharedData.activeCarsCount

    for pos=1,activeCars,1 do
        trustableSplinePostionsById[trustableValues[pos].carId] = trustableValues[pos].splinePosition
    end
end

function script.update(dt)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt
    ac.debug("SC: timeAccumulator", timeAccumulator)
   
    ac.debug("SC: z-sessionTimeLeft", sim.sessionTimeLeft * -1)
    --[[ ac.debug("SC: z-timeToSessionStart", sim.timeToSessionStart)
    ac.debug("SC: z-currentSessionTime",sim.currentSessionTime)
    
    ac.debug("SC: In pitlane", safetyCar.isInPitlane)
    ac.debug("SC: In pitbox", safetyCar.isInPit)
    ac.debug("SC: SplinePos", safetyCar.splinePosition)
    ac.debug("SC: onTrack", scOnTrack)
    ac.debug("SC: inPitLane", scInPitLane)
    ac.debug("SC: scRequested", scRequested)
    ac.debug("SC: scHeadingToPit", scHeadingToPit) 
    ac.debug("SC: checkClosestCarToSC", checkClosestCarToSC)
    --ac.debug("SC: scActive", scActive)
    ac.debug("SC: Rolling Start", rollingStart)
    ac.debug("SC: 1-steer", safetyCar.steer)
    ac.debug("SC: 1-resetBrakeInPitHack", resetBrakeInPitHack)
    ac.debug("SC: 1-resetBrakeInPitHackSuccess", resetBrakeInPitHackSuccess)
    ]]

    if currentSession then    
        ac.debug("SC: Session Duration", currentSession.durationMinutes)
    end

    -- Session start sanity checks - if we are in a wait state and we have gone more than 1 second then reissue the command and reset the 1s timer
    if waitingToTeleport then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            if ac.tryToTeleportToPits() then
                waitingToTeleport = false
                waitingToStart = true
                writeLog("SC: Backup Teleportation to pit successful")
            end
            waitingToStartTimerOn = timeAccumulator
        end
    end

    if waitingToStart then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            ac.tryToOpenRaceMenu(nil)
            if ac.tryToStart() then
                writeLog("SC: Backup teleportation to pit and start successful")
                waitingToStart = false
                if rollingStart and sim.raceSessionType == 3 then
                    jumpSCtoStart()
                    waitingToRollingStart = true
                else
                    scInPitLane = true
                    scOnTrack = false
                end
            end
            waitingToStartTimerOn = timeAccumulator
        end
    end

    --don't do anything for first 2 seconds while trying teleport
    if timeAccumulator < 2 then
        return
    end

    -- Setting SC rolling start values 30 secs before race start
    if waitingToRollingStart then
        if sim.timeToSessionStart <= 15000 then
            writeLog("SC: Set SC variables 15s to race start")
            setSCRollingValues()
            setSCLights("on")
            scRequested = true
            scConditonsMet = false
            scOnTrack = true
            scInPitLane = false
            scHeadingToPit = false
            waitingToRollingStart = false
            checkClosestCarToSC = true
            ac.sendChatMessage("SC: Safety Car rolling start")
            --physics.setAISplineOffset(safetyCar.index, normTrackCenter, true)
        end
    end

    -- stop if not enough cars connected
    -- if sim.connectedCars < (minConnectedCars + 1) then return end
    -- stop if not race session
    --if sim.raceSessionType ~= 3 then return end

    -- Safety Car is being requested
    if scRequested and not scOnTrack then        
        scInPitLane = safetyCar.isInPitlane or safetyCar.isInPit
        -- Runs for a single frame when the SC leaves the pits
        if not scInPitLane and not scOnTrack then
            writeLog("SC: Safety Car deployed")
            ac.sendChatMessage("SC: Safety Car deployed")
            scOnTrack = true
            scInPitLane = false
            checkClosestCarToSC = true
            scPrevLapCount = safetyCar.lapCount
            setSCValues(safetyCarInitialSpeed)
            setSCLights("on")
        end
    end

    if scManualCallIn then
        ac.sendChatMessage("SC: Safety Car in this lap")
        scManualCallIn = false
    end

    -- Things we do every 10 (long) seconds
    if timeAccumulator - timeLongAccumulator >= timeLong then
        if scActive and currentSession then
            --TODO: check this durationMinutes
            local csDuration = currentSession.durationMinutes * 60000
            --local csTime = sim.currentSessionTime
            local csTime = sim.sessionTimeLeft * -1
            local csMinActiveTime = csDuration * scActiveCheckStartPercentage
            if csTime > csMinActiveTime and not gotAvgSessionTimes then
                sessionTimeCalcs()
                gotAvgSessionTimes = true
            end
            if csTime > scActiveTime and scActiveTime > 0 then
                scActive = false
            end
            ac.debug("SC: SC Active", scActive)
        end

        local sessionLeader = ac.getCar(sharedData.carsArray[1].carId)
        if sessionLeader ~= nil then
            ac.debug("SC: carLeaderboard[1].car ", sessionLeader:driverName())
        end


        if sim.timeRaceEnded or sim.leaderLastLap then
            scConditonsMet = true
            scHeadingToPit = true
            scRequested = false
            setSCRequestPit()
            ac.sendChatMessage("SC: Safety Car is heading to pits at end of session")
        end

        ac.debug("timeLongAccumulator", timeLongAccumulator)
        timeLongAccumulator = timeAccumulator
    end

    -- Things we do every 5 (medium) seconds
    if timeAccumulator - timeMediumAccumulator >= timeMedium then
        -- Checks for retired cars and stragglers
        if scOnTrack and sim.timeToSessionStart < 0 then
            updateCarStatuses()
            -- SC conditions met, wait +- 5 seconds before heading to pits
            if scConditonsMet and not scHeadingToPit then
                scHeadingToPit = true
                scRequested = false
                setSCRequestPit()
                setSCLights("off")
                writeLog("SC: Safety Car is heading to pits")
            end
        end
        timeMediumAccumulator = timeAccumulator
    end

    if resetBrakeInPitHack then
        if safetyCar.steer < 3 or safetyCar.steer > -3 then
            physics.setCarAutopilot(false, false)
            physics.forceUserBrakesFor(1.25, 0.65)
            resetBrakeInPitHack = false
            resetBrakeInPitHackSuccess = true
        end
    end

    -- Things we do every 1 (short) seconds
    if timeAccumulator - timeShortAccumulator >= timeShort then
        -- Hacky force braking in pit
        if resetBrakeInPitHackSuccess then
            physics.setCarAutopilot(true, false)
            physics.setAITopSpeed(safetyCar.index, safetyCarPitInSpeed)
            physics.setAIPitStopRequest(safetyCar.index, true)
            resetBrakeInPitHackSuccess = false
        end
        -- Get the leader behind the SC not in pit and set SC speed up
        if checkClosestCarToSC then
            local lc, lcDistance = getLeadingCarBehindSC()
            if lc then
                local lcSpeed = math.max(lc.speedKmh, 100)
                local scSpeedUpDistance = (lcSpeed * scLeadDistThresholdMin) / 100

                ac.debug("SC: lc: ", lc:driverName())
                ac.debug("SC: lcDistance: ", lcDistance)
                ac.debug("SC: lcSpeed: ", lcSpeed)
                ac.debug("SC: scSpeedUpDistance: ", scSpeedUpDistance)

                if lcDistance <= scSpeedUpDistance then
                    writeLog("SC: Leader gap to Safety Car : " .. lcDistance .. "m @" .. lcSpeed)
                    setSCSpeedUpValue()
                    checkClosestCarToSC = false
                end
            end
        end
        timeShortAccumulator = timeAccumulator
    end

    -- Things we do every 0.5 (shorter) seconds
    if timeAccumulator - timeHalfSecAccumulator >= timeHalfSec then

        --check if the SC has been called out
        if sharedData.safetyCarCallout then
            sharedData.safetyCarCallout = false
            callSafetyCar()
            writeLog("SC: SC scon received from shared data")
        end

        refreshSplineList()
        if not scHeadingToPit then
            if scOnTrack and not scConditonsMet then
                local scSplinePos = trustableSplinePostionsById[safetyCar.index]
                -- TODO: Ask Nigel to if we can get PitLane Spline?
                if scSplinePos > SC_CALLIN_THRESHOLD_START and scSplinePos <= SC_CALLIN_THRESHOLD_END then
                    ac.debug("SC: Safety Car within threshold", true)
                    if canSafetyCarComeIn()
                    or rollingStart
                    or safetyCar.lapCount - scPrevLapCount >= scMaxLapsOut
                    then
                        scConditonsMet = true
                        ac.sendChatMessage("SC: Safety Car in this lap")
                        writeLog("SC: Conditions met for Safety Car to come in")
                        writeLog("SC: Safety Car in this lap")
                        -- See med timer for call in/heading to pit 
                    end
                else
                    ac.debug("SC: Safety Car within threshold", false)
                end
            end        
        end
        if scHeadingToPit and scOnTrack then
            if safetyCar.isInPitlane then
                scOnTrack = false
                ac.sendChatMessage("SC: Safety Car is clear")
                writeLog("SC: Safety Car is clear")
                setPitInSpeed()
                checkLeaderPos = true
                -- TODO: Is this needed - prob not anymore
                local lc, lcDistance = getLeadingCarBehindSC()
                if lc then
                    underSCLapCount = lc.lapCount
                    --checkLeaderPos = true
                    writeLog("SC: Leader on SC clear | " .. lc:driverName())
                end
            end
        end
        timeHalfSecAccumulator = timeAccumulator
    end

    if scHeadingToPit and safetyCar.isInPit then
        -- Reset SC once entering pit box
        physics.setCarAutopilot(false, false)
        if ac.tryToTeleportToPits() then
            if ac.tryToStart() then
                writeLog("SC: SC reset in pits successful")
            else
                writeLog("SC: SC reset in pits failed")
                waitingToStart = true
            end
        end

        scHeadingToPit = false
        scRequested = false
        scOnTrack = false
        scInPitLane = true
        scConditonsMet = false
        rollingStart = false
        --ac.sendChatMessage("SC: Safety Car has reset in pits")        
    end

    --use leader crossing sf to ensure rollingstart is not set
   
     if checkLeaderPos then
        local sessionLeader = ac.getCar(sharedData.carsArray[1].carId)
        if sessionLeader == safetyCar then
            sessionLeader = ac.getCar(sharedData.carsArray[2].carId)
        end

        -- TODO: Ask Nigel to check this
        if sessionLeader and underSCLapCount < sessionLeader.lapCount then
            checkLeaderPos = false
            writeLog("SC: Go Green - " .. sessionLeader:driverName() .. " | " .. sessionLeader.lapCount)
            rollingStart = false
        end
    end

end

ac.onSessionStart(function(sessionIndex, restarted)
    currentSession = ac.getSession(sessionIndex)
    initializeSSStates()
    initializeSCScript()
    writeLog("SC: Safety Car Script Initialized on Session Start")
end)

initializeSSStates()
initializeSCScript()

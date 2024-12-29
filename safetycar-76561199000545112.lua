
SCRIPT_NAME = "VVS Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Get states
local sim = ac.getSim()
local currentSession = ac.getSession(sim.currentSessionIndex)
local safetyCarName = "Safety Car"
local adminName = "Jon Astrop"
local startBehindSC = false

--shared data structure for real car data
local sharedData = ac.connect {
    ac.StructItem.key('vvs.car_tracker'),
    raceHasStarted = ac.StructItem.boolean(),
    activeCarsCount = ac.StructItem.int16(),
    carsArray = ac.StructItem.array(ac.StructItem.struct({
        carId = ac.StructItem.int16(),
        splinePosition = ac.StructItem.double(),
        distanceDriven = ac.StructItem.double(),
        isRetired = ac.StructItem.boolean()
    }), 50)
}

--#############################################################
--################# CAR TRACKER LOGIC #########################
--#############################################################

local trackLength = sim.trackLengthM

-- Time variables and heartbeats
local timeAccumulator = 0
local realDistanceCheckHeartbeat = 0.1
local realDistanceCheckTime = 0
local stateCheckHeartbeat = 0.5
local stateCheckTime = 0
local startCheckHeartBeat = 0.1
local startCheckTime = 0
local startDelayTime = 0
local sfCheckHeartBeat = 1
local sfCheckTime = 0

--latch for run once activities
local runOnceTable = {}

--is this a race
local isRace = false

-- Custom log file as the AC one gets overwritten
local logFile

--retired car list
local retiredCars = {}
--tracker of real distances
local realDistancesTracker = {}
--tracker for initial sf crossing
local hasCrossedSF = {}
--previous splines (udsed for sf crossing)
local prevSplines = {}
--previous distances (used for logging discrepancies)
local prevDistances = {}
--set once all cars have crossed SF to disable that check
local allCarsCrossed = false

local function openLogFiles()
    
    local logFilePath = "apps/lua/car_tracker/car_tracker_log.txt"
    local msg
    logFile, msg = io.open(logFilePath, "a")
    if not logFile then
        ac.log("Failed to open log file - " .. msg)
    else
        ac.log("Log file opened at " .. logFilePath)
    end
end

--utility function to convert milliseconds to minutes:seconds - used for logging
local function millisecondsToClock(milliseconds)
    local isNegative = false
    if milliseconds < 0 then
        isNegative = true
        milliseconds = milliseconds * -1
    end

    local mins = string.format("%02.f", math.floor(milliseconds/60000));
    local secs = string.format("%02.f", math.floor((milliseconds - mins*60000)/1000));
    local cs = string.format("%02.f", math.floor((milliseconds - (mins*60000) - (secs*1000))/10));

    if isNegative then
        return "-"..mins..":"..secs.."."..cs
    else
        return mins..":"..secs.."."..cs
    end

end

--utility function to log messages
local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    local runningTime = timeAccumulator
    local timeLeft = millisecondsToClock(sim.sessionTimeLeft)
    ac.log(timeStamp .. " | " .. timeLeft .. " | " .. runningTime .. " | CAR_TRACKER | " .. message) -- log to the default writeLog
    --log to custom file
    if logFile then    
        logFile:write("[" .. timeStamp .. " | " .. timeLeft .. " | " .. runningTime .. "] " .. message .. "\n")
        logFile:flush()
    end
end

--get the median recorded values from last 10 measurements
local function getRealValues(carIndex)
    local copyTable = {}
    for k,v in pairs(realDistancesTracker[carIndex]) do
        copyTable[k] = v
    end
    table.sort(copyTable, function (k1, k2) return k1.distanceDriven > k2.distanceDriven end )
    return copyTable[5]
end

--calc distance driven of car - log out anomalies
local function getDistance(car) 
    local splinePos = car.splinePosition
    local distanceDriven = (splinePos * trackLength) + (car.lapCount * trackLength)

    --deal with cars that haven't crossed the SF yet - given them a negative distance driven that approaches 0 as they get to the line
    --only applies to cars with lap count of 0
    if car.lapCount == 0 then
        --for cars that haven't yet crossed the start finish
        if hasCrossedSF[car.index] == nil then
            --sanity check that the spline is over 0.1 so we don't accidentally pick up someone that has just crossed the line
            if splinePos > 0.1 then
                distanceDriven = (1 - splinePos) * trackLength * -1
            end
        end
    end

    if prevDistances[car.index] == nil then
        prevDistances[car.index] = trackLength * -2
    end

    --log out discrepancies

    --don't worry about this if it's the first frame
    if prevDistances[car.index] ~= trackLength * -2 then
        --don't bother logging anything around the start finish line
        if splinePos>0.01 and splinePos<0.99 then
            --ignore finished and retired cars
            if not car.isRetired and retiredCars[car.index] == nil and not car.isRaceFinished then
                --have we jumped back?
                if distanceDriven >= prevDistances[car.index] - 50 then
                    --no, so check we haven't jumped too far ahead
                    if distanceDriven >= prevDistances[car.index] + 50 then          
                        writeLog("BLIP - JUMP AHEAD DETECTED! " .. car:driverName() .. "|" .. splinePos .. "|" .. trackLength .. "|" .. car.lapCount .. "|".. distanceDriven .. "|" .. prevDistances[car.index] )
                        for i,n in ipairs(realDistancesTracker[car.index]) do writeLog(i .. ": " .. n.splinePosition .. "|" .. n.distanceDriven .. "|" .. n.timeString) end
                    end
                else
                    --yes so log jump back
                    writeLog("BLIP - JUMP BACK DETECTED! " .. car:driverName() .. "|" .. splinePos .. "|" .. trackLength .. "|" .. car.lapCount .. "|".. distanceDriven .. "|" .. prevDistances[car.index] )
                    for i,n in ipairs(realDistancesTracker[car.index]) do writeLog(i .. ": " .. n.splinePosition .. "|" .. n.distanceDriven .. "|" .. n.timeString) end
                end
            end
        end
    end

      --store previous distance calc
      prevDistances[car.index] = distanceDriven

      return distanceDriven
end

--store the distances to enable the sanity checking + extra stuff useful for logging
local function storeRealDistances() 
    for i, car in ac.iterateCars.ordered() do
        table.remove(realDistancesTracker[car.index],1)
        table.insert(realDistancesTracker[car.index], {splinePosition=car.splinePosition, distanceDriven=getDistance(car), timeString=os.date("%Y-%m-%d %H:%M:%S") .. " | " .. millisecondsToClock(sim.sessionTimeLeft) .. " | " .. timeAccumulator})
        --for i,n in ipairs(realSplinesTracker[car.index]) do writeLog(i .. ": " .. n) end
    end
end

--init the real distances array
local function initRealDistances() 
    writeLog("Splines intitialised")
    for i, car in ac.iterateCars.ordered() do
        local distance = getDistance(car)
        realDistancesTracker[car.index] = {}
        for j=1,10 do
            table.insert(realDistancesTracker[car.index],{splinePosition=car.splinePosition, distanceDriven=distance, timeString=os.date("%Y-%m-%d %H:%M:%S") .. " | " .. millisecondsToClock(sim.sessionTimeLeft) .. " | " .. timeAccumulator})
        end
    end
    
end

--check for SF Cross
local function checkSFCrossing()
    --for efficiency, once all cars are crossed then don't run this
    if allCarsCrossed then return end
    --on the heartbeat
    if timeAccumulator - sfCheckTime  >= sfCheckHeartBeat then
        local anyFalse = false

        --iterate the list of cars
        for i, car in ac.iterateCars.ordered() do
            --ignore the safety car
            if car:driverName() ~= "Safety Car" then
                --if car has already crossed then we don't need to do the check
                if hasCrossedSF[car.index] == nil then
                    --first go we will have no stored splines
                    if prevSplines[car.index] == nil then
                        prevSplines[car.index] = car.splinePosition
						if car.splinePosition < 0.4 then
							writeLog("Car has started in front of sf " .. car:driverName() )
                            hasCrossedSF[car.index] = true
						end
                    else
                        --spline has gone from 0.9x to 0.0x
						--writeLog("spline check " .. car:driverName() .. "|" .. prevSplines[car.index] .. "|" .. car.splinePosition )
                        if prevSplines[car.index] > 0.9 and car.splinePosition < 0.1 then
							writeLog("Car has crossed sf " .. car:driverName() )
                            hasCrossedSF[car.index] = true
                        end
						prevSplines[car.index] = car.splinePosition
                    end
                    --check if any are false still
                    if hasCrossedSF[car.index] == nil then
                        anyFalse = true
                    end
                end
            end
        end
        --all cars have passed the check, disable it
        if not anyFalse then 
            allCarsCrossed = true 
            writeLog("All cars have crossed the SF for the first time - sfCheck now disabled")
        end
        sfCheckTime = timeAccumulator
    end
end

--store the real car data that can be used by the other apps
local function storeCarData()
    writeLog("Storing Car Data")
    local carPosList = {}

    for i, car in ac.iterateCars.ordered() do
        --get distance
        local realValues = getRealValues(car.index)
        local splinePos = realValues.splinePosition
        local distanceDriven = realValues.distanceDriven
        local isRetired = car.isRetired or retiredCars[car.index] ~= nil
        carPosList[#carPosList + 1] = {carId=car.index, distanceDriven=distanceDriven, splinePosition = splinePos, isRetired = isRetired}
    end

    --sort by distance driven
    table.sort(carPosList, function (k1, k2) return k1.distanceDriven > k2.distanceDriven end )

    --save values to shared memory
    sharedData.activeCarsCount = #carPosList
    writeLog("Active Cars Count: " .. sharedData.activeCarsCount)
    local storeCarsArray = {}
    --seems the shred mem thing wants to try to be zero based and it fucks everything up - stick some dummy vals in the 0 position to deal with that
    storeCarsArray[0] = {carId = 0, splinePosition = 0, 0, false}
    for pos=1, #carPosList, 1 do
        storeCarsArray[pos] = {carId = carPosList[pos].carId, splinePosition = carPosList[pos].splinePosition, distanceDriven = carPosList[pos].distanceDriven, isRetired = carPosList[pos].isRetired}
        writeLog("Car " .. storeCarsArray[pos].carId .. " | " .. storeCarsArray[pos].distanceDriven .. " | " .. storeCarsArray[pos].splinePosition .. " | " .. tostring(storeCarsArray[pos].isRetired))
    end
    sharedData.carsArray = storeCarsArray;
end

--Run once latch mechanism - on the first call each session for a given key this returns true, false thereafter
local function hasNotBeenRunThisSession(key)
    if runOnceTable[key] == nil then
        runOnceTable[key] = "1"
        return true
    else
        return false
    end
end

--#############################################################
--################# CAR TRACKER LOGIC END #####################
--#############################################################


local safetyCarID
local safetyCar
local adminCarID
local adminCar

-- Safety Car Speeds and thresholds
--local trackLength
local safetyCarPitLaneSpeed
local safetyCarInitialSpeed
local safetyCarSpeed
local safetyCarInSpeed
local scLeadDistThresholdMin
local distanceThresholdMeters
local carSpacing
local inPitTimeLimit
local carPitEntryTimes
--local retiredCars
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
--local timeAccumulator
local timeMedium
local timeMediumAccumulator
local timeLong
local timeLongAccumulator

-- Session start variables
local waitingToStartTimerOn
local waitingToStart
local waitingToStartBehindSC
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
local scManualCallin
local checkLeaderPos
local underSCLapCount
local raceLeader

--spline positions for easy lookup
local trustableSplinePostionsById = {}


local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message)
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
    adminCarID = ac.getCarByDriverName(adminName)
    if adminCarID then
        adminCar = ac.getCar(adminCarID)
    else
        writeLog("SC: Admin car not found during initialization")
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
    if sim.connectedCars < (minConnectedCars + 1) then
        writeLog("SC: Not enough cars connected")
        return false
    end

    return true
end

local function setSCValues(scSpeed)
    physics.setAIPitStopRequest(safetyCar.index, false)
    physics.setCarAutopilot(true, false)
    physics.setAITopSpeed(safetyCar.index, scSpeed)
    physics.setAIAggression(safetyCar.index, 1)
    writeLog("SC: SC values set")
end

local function setSCSpeedUpValue()
    physics.setAITopSpeed(safetyCar.index, safetyCarSpeed)
end

local function setSCRequestPit()
    physics.setAITopSpeed(safetyCar.index, safetyCarSpeed)
    physics.setAIPitStopRequest(safetyCar.index, true)
end

local function setSCLights(state)
    if state == "on" then
        if scOnTrack then
            ac.setExtraSwitch(0, false)
            ac.setExtraSwitch(1, true)
        else
            ac.setExtraSwitch(0, true)
            ac.setExtraSwitch(1, false)
        end
    elseif state == "off" then
        ac.setExtraSwitch(0, false)
        ac.setExtraSwitch(1, false)
    end
end

local function jumpSCtoStart()
    local scMetersAhead = 20
    local scTrackPos = scMetersAhead / sim.trackLengthM
    local splineAhead = (scMetersAhead + 1) / sim.trackLengthM

    local function normalize_position(P, L, R)
        if P <= L then
            return -1 + (P / L)  -- Map to -1 to 0
        else
            return 0 + ((P - L) / R)  -- Map to 0 to +1
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

    -- Set the safety car position and orientation
    physics.setCarPosition(safetyCar.index, scTrackProgressWorld, splineAheadWorld)

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
    scOnTrack = false
    scRequested = false
    scHeadingToPit = false

    getAdminCar()

    if startBehindSC then
        jumpSCtoStart()
        if not safetyCar.isInPit and not safetyCar.isInPitlane then
            waitingToStartBehindSC = true
            writeLog("SC: After jump to track, confirmed not in pit")
        end
    else 
        if ac.tryToTeleportToPits() then
            ac.tryToOpenRaceMenu(nil)
            ac.disableQuickMenuPitstop(true)
            if ac.tryToStart() then
                scInPitLane = true
                writeLog("SC: First teleportation to pit and start successful")
            else
                writeLog("SC: Start in pits failed. Retrying...")
                waitingToStart = true
            end
        else
            writeLog("SC: Teleport to pits failed. Retrying...")
            waitingToTeleport = true
        end
    end

    -- Set track length dependent thresholds
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
    end
    SC_CALLIN_THRESHOLD_END = SC_CALLIN_THRESHOLD_START + 0.25
    
end

local function callSafetyCar()
    if not ensureSimAndSafetyCar() then return end
    if scActive then
        writeLog("SC: Safety Car is being called")
        scRequested = true
        scHeadingToPit = false
        scOnTrack = false
        setSCValues(safetyCarPitLaneSpeed)
        setSCLights("on")
    else
        writeLog("SC: Safety Car cannot be deployed - too late in race")
    end
end

-- Listen to chat messages calling SC deployment or manual SC control
local function processChatMessage(message, senderCarIndex)
    if senderCarIndex == safetyCar.index or (adminCar and senderCarIndex == adminCar.index) then
        if message == "SC scon" then
            callSafetyCar()
            writeLog("SC: SC scon received | " .. "CarID: " .. senderCarIndex .. " | Name: " .. ac.getCar(senderCarIndex):driverName())
        elseif message == "SC scoff" then
            scManualCallin = true
            scConditonsMet = true
            scHeadingToPit = true
            scRequested = false
            setSCRequestPit()
            setSCLights("off")
            writeLog("SC: Safety Car is manually called in")
        elseif message == "SC: Kill Switch" then
            initializeSCScript()
        elseif message == "SC start" then
            jumpSCtoStart()
        end
    end
    return true
end

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    writeLog("SC: Chat Msg: " .. message .. " | Car ID: " .. senderCarIndex)
    return processChatMessage(message, senderCarIndex)
end)

-- Calculate the normalized distance behind the safety car
local function calculateDistanceBehind(carPosition, car2Position)
    local distance = (car2Position - carPosition) % 1
    return distance  -- Always a value between 0 and 1
end

-- Update car statuses and gaps to SC
local function updateCarStatuses()
    local scSplinePos = trustableSplinePostionsById[safetyCar.index]
    raceLeader = ac.getCar(sharedData.carsArray[1].carId)
    
    for i, car in ac.iterateCars.ordered() do
        if car ~= safetyCar then
            -- Update pit times or retirement status
            if car.isInPit then
                if not carPitEntryTimes[car.index] then
                    carPitEntryTimes[car.index] = timeAccumulator
                else
                    local pitTime = timeAccumulator - carPitEntryTimes[car.index]
                    if pitTime > inPitTimeLimit then
                        retiredCars[car.index] = true
                        writeLog("SC: " .. car:driverName() .. " retired; in pits for " .. pitTime .. " seconds")
                    end
                end
                if car.isRetired then
                    retiredCars[car.index] = true
                    writeLog("SC: " .. car:driverName() .. " isRretired")
                end
            else
                carPitEntryTimes[car.index] = nil
                retiredCars[car.index] = nil

                -- Update car's gaps to SC
                local carSplinePos = trustableSplinePostionsById[car.index]
                local distanceToSC = calculateDistanceBehind(carSplinePos, scSplinePos)
                local secondsAhead = distanceToSC * trackLength / safetyCar.speedMs
                local previousSecondsAhead = previousGapToSC[car.index] or secondsAhead
                local isGaining = secondsAhead < previousSecondsAhead or secondsAhead < 15

                previousGapToSC[car.index] = secondsAhead
                writeLog("SC: " .. car:driverName() .. " | SecAhead: " .. secondsAhead .. " | isGaining: " .. tostring(isGaining))
                
                if not isGaining and ((secondsAhead - previousSecondsAhead) > gainingTimeThreshold) then
                    if not carsNotGainingOnSC[car.index] then
                        carsNotGainingOnSC[car.index] = {notGaining = true, secondsAhead = secondsAhead}
                        writeLog("SC: CarStatus: " .. car:driverName() .. " is not gaining on SC | Gap is " .. secondsAhead .. " seconds")
                    end
                else
                    carsNotGainingOnSC[car.index] = nil
                end
            end
        end
    end
end

-- Check if the Safety Car can come in based on the number of cars and their positions
local function canSafetyCarComeIn()

    updateCarStatuses()

    local connectedCars = sim.connectedCars
    local retiredCarsCount = retiredCars and #retiredCars or 0
    local carsNotGainingCount = carsNotGainingOnSC and #carsNotGainingOnSC or 0  

    local N = connectedCars - retiredCarsCount - carsNotGainingCount - 1 -- -1 to exclude SC

    distanceThresholdMeters = (N + 3) * carSpacing

    writeLog("SC: N = " .. N)
    writeLog("SC: Connected Cars = " .. connectedCars)
    writeLog("SC: Distance Threshold = " .. distanceThresholdMeters)

    local carsNearAndBehindSC = 0

    for i, car in ac.iterateCars.ordered() do
        if carsNearAndBehindSC >= N then
            break
        end

        if not (retiredCars[car.index] or carsNotGainingOnSC[car.index] or car == safetyCar) then
            local distanceToSC = calculateDistanceBehind(trustableSplinePostionsById[car.index], trustableSplinePostionsById[safetyCar.index])
            local distanceMeters = distanceToSC * trackLength
            if car and distanceMeters < distanceThresholdMeters then
                carsNearAndBehindSC = carsNearAndBehindSC + 1
            end
        end
    end
    writeLog("SC: carsNearAndBehindSC = " .. carsNearAndBehindSC)
    local result = carsNearAndBehindSC >= N
    writeLog(result and "SC: Safety Car can come in this lap." or "SC: Not all cars are within threshold the Safety Car.")
    return result
end

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
    local sessionLeader = nil

    local trustableValues = sharedData.carsArray
    local activeCars = sharedData.activeCarsCount

    sessionLeader = ac.getCar(trustableValues[1].carId)
    if sessionLeader ~= nil then
        ac.debug("SC: SessionState Leader", sessionLeader:driverName())
    end

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
        local distance = calculateDistanceBehind(carSplinePos, scSplinePos)

        distanceMeters = distance * trackLength
        ac.debug("SC: LC distance to SC:", distanceMeters)
        ac.debug("SC: scSplinePos:", scSplinePos)
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
    ac.debug("SC: Session Time Left", sim.sessionTimeLeft)
    ac.debug("SC: In pitlane", safetyCar.isInPitlane)
    ac.debug("SC: In pitbox", safetyCar.isInPit)
    ac.debug("SC: SplinePos", safetyCar.splinePosition)
    ac.debug("SC: onTrack", scOnTrack)
    ac.debug("SC: inPitLane", scInPitLane)
    ac.debug("SC: scRequested", scRequested)
    ac.debug("SC: scHeadingToPit", scHeadingToPit)
    ac.debug("SC: scActive", scActive)
    ac.debug("SC: Start behind SC", startBehindSC)

    -- Session start sanity checks - if we are in a wait state and we have gone more than 1 second then reissue the command and reset the 1s timer
    if waitingToTeleport then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            if ac.tryToTeleportToPits() then
                waitingToTeleport = false
                waitingToStart = true
                writeLog("SC: Teleportation to pit successful")
            end
            waitingToStartTimerOn = timeAccumulator
        end
    end

    if waitingToStart then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            ac.tryToOpenRaceMenu(nil)
            if ac.tryToStart() then
                waitingToStart = false
                scInPitLane = true
                writeLog("SC: Teleportation to pit and start successful")
            end
            waitingToStartTimerOn = timeAccumulator
        end
    end

    if waitingToStartBehindSC then
        if timeAccumulator - waitingToStartTimerOn >= 3 then
            writeLog("SC: After delay on grid start")
            setSCValues(safetyCarSpeed)
            setSCLights("on")
            scRequested = true
            scOnTrack = true
            scInPitLane = false
            waitingToStartBehindSC = false
            --physics.setAISplineOffset(safetyCar.index, normTrackCenter, true)
        waitingToStartTimerOn = timeAccumulator
        end
    end

    --don't do anything for first 2 seconds while trying teleport
    if timeAccumulator < 2 then
        return
    end

    -- stop if not enough cars connected
    if sim.connectedCars < (minConnectedCars + 1) then return end

    --#############################################################
    --################# CAR TRACKER LOGIC START ###################
    --#############################################################
  
    --check for race start
    if timeAccumulator - startCheckTime  >= startCheckHeartBeat then
        startCheckTime = timeAccumulator
        if sim.timeToSessionStart < 250 and sim.timeToSessionStart > 50 then
            if hasNotBeenRunThisSession("racestartcountdown") then
                startDelayTime = timeAccumulator

                sharedData.raceHasStarted = true
                --initialise real distances array
                initRealDistances()

                --initial position capture
                storeCarData()
            end
        end
    end

    if startDelayTime == 0 then
        return
    end

    checkSFCrossing()

    if timeAccumulator - startDelayTime > 0.3 then
        if hasNotBeenRunThisSession("racestart") then
            startDelayTime = timeAccumulator
        end
    end

    --do nothing if the race start hasn't happened yet
    if runOnceTable["racestart"] == nil then
        return
    end

    --every frame check for jumped to pits
    ac.perfBegin("retirecheck")
    for i, car in ac.iterateCars.ordered() do
        if car.justJumped then
            retiredCars[car.index] = true
            writeLog("RETIREMENT - " .. car:driverName() .. " - has jumped to pits")
        end
    end
    ac.perfEnd("retirecheck")

    --every realSplineCheckHeartbeat seconds store the current splines of the cars
    if timeAccumulator - realDistanceCheckTime  >= realDistanceCheckHeartbeat and runOnceTable["racestart"] ~= nil then
        realDistanceCheckTime = timeAccumulator
        storeRealDistances()
    end

    --every stateCheckHeartbeat seconds check the race state for changes - only do this after the race start
    if timeAccumulator - stateCheckTime  >= stateCheckHeartbeat and runOnceTable["racestart"] ~= nil then
        stateCheckTime = timeAccumulator

        --iterate the cars and check if their position has changed
        storeCarData()

    end

    --#############################################################
    --################# CAR TRACKER LOGIC END  ####################
    --#############################################################

    -- Safety Car is being requested
    if scRequested then
        if not scOnTrack then
            scInPitLane = safetyCar.isInPitlane or safetyCar.isInPit
            -- Runs for a single frame when the SC leaves the pits
            if not scInPitLane and not scOnTrack then
                writeLog("SC: Safety Car has left pits")
                ac.sendChatMessage("SC: Safety Car has left pits")
                scOnTrack = true
                scInPitLane = false
                checkClosestCarToSC = true
                setSCValues(safetyCarInitialSpeed)
                setSCLights("on")
            end
        end
    end

    if scManualCallin then
        ac.sendChatMessage("SC: Safety Car is heading to pits")
        scManualCallin = false
    end

    -- Things we do every 10 (long) seconds
    if timeAccumulator - timeLongAccumulator >= timeLong then
        if scActive then
            local csDuration = currentSession.durationMinutes * 60000
            local csTime = sim.currentSessionTime
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
        if scOnTrack then
            updateCarStatuses()
        end
        timeMediumAccumulator = timeAccumulator
    end

    -- Things we do every 1 (short) seconds
    if timeAccumulator - timeShortAccumulator >= timeShort then
        -- Get the leader behind the SC and set SC speed up
        if checkClosestCarToSC then
            local lc, lcDistance = getLeadingCarBehindSC()
            if lc then
                local lcSpeed = math.max(lc.speedKmh, 100)
                local scSpeedUpDistance = (lcSpeed * scLeadDistThresholdMin) / 100

                ac.debug("SC: lc: ", lc:driverName())
                ac.debug("SC: lcDistance: ", lcDistance)
                ac.debug("SC: lcSpeed: ", lcSpeed)
                ac.debug("SC: scSpeedUpDistance: ", scSpeedUpDistance)

                if (lcDistance <= scSpeedUpDistance) and not (lc.isInPit or lc.isInPitlane) then
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
        refreshSplineList()
        if not scHeadingToPit then
            if scOnTrack then
                local scSplinePos = trustableSplinePostionsById[safetyCar.index]
                if scSplinePos > SC_CALLIN_THRESHOLD_START and scSplinePos <= SC_CALLIN_THRESHOLD_END then
                    writeLog("SC: Safety Car is within threshold")
                    if canSafetyCarComeIn() then
                        scConditonsMet = true
                        scHeadingToPit = true
                        scRequested = false
                        setSCRequestPit()
                        setSCLights("off")
                        ac.sendChatMessage("SC: Safety Car is heading to pits")
                        --ac.sendChatMessage("SC: Conditions met for Safety Car to come in")
                        writeLog("SC: Conditions met for Safety Car to come in")
                        writeLog("SC: Safety Car is heading to pits")
                    end
                end
            end
        end
        if scHeadingToPit and scOnTrack then
            if safetyCar.isInPitlane then
                scOnTrack = false
                ac.sendChatMessage("SC: Safety Car is entering pit lane")
                writeLog("SC: Safety Car is entering pit lane")

                local lc, lcDistance = getLeadingCarBehindSC()
                if lc then
                    underSCLapCount = lc.lapCount
                    checkLeaderPos = true
                    writeLog("SC: Leader on Pit Entry" .. lc:driverName())
                end
            end
        end
        timeHalfSecAccumulator = timeAccumulator
    end

    if scHeadingToPit and safetyCar.isInPit then
        -- Reset SC once entering pit box
        physics.setCarAutopilot(false, false)
        if ac.tryToTeleportToPits() then
            ac.tryToStart()
        end
        scHeadingToPit = false
        scRequested = false
        scOnTrack = false
        scInPitLane = true
        scConditonsMet = false
        --ac.sendChatMessage("SC: Safety Car has reset in pits")
        writeLog("SC: Safety Car has reset in pits")
    end

    if checkLeaderPos then
        local sessionLeader = ac.getCar(sharedData.carsArray[1].carId)
        if underSCLapCount < sessionLeader.lapCount then
            local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
            ac.sendChatMessage("SC: Go Green | " .. timeStamp)
            checkLeaderPos = false
            writeLog("SC: Go Green - " .. sessionLeader:driverName())
            writeLog("SC: Leader Lap Count - GO Green" .. sessionLeader.lapCount)
        end
    end

    ac.debug("SC: Safety Car In Pit Lane", scInPitLane)
    ac.debug("SC: Safety Car Requested", scRequested)
    ac.debug("SC: Safety Car Heading to Pit", scHeadingToPit)
    ac.debug("SC: Safety Car On Track", scOnTrack)

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
    safetyCarInSpeed = 999 -- flat out
    scLeadDistThresholdMin = 150 -- update to adjust to speed of leader
    distanceThresholdMeters = 500 -- replaced by N/connected cars calc
    carSpacing = 40 -- multiplier for distance behind SC N x carSpacing
    inPitTimeLimit = 120 -- seconds
    carPitEntryTimes = {}
    retiredCars = {}
    previousGapToSC = {}
    carsNotGainingOnSC = {}
    gainingTimeThreshold = 2
    minConnectedCars = 1

    -- Time accumulators
    timeHalfSec = 0.5 -- seconds
    timeHalfSecAccumulator = 0
    timeShort = 1.5
    timeShortAccumulator = 0
    timeAccumulator = 0
    timeMedium = 5
    timeMediumAccumulator = 0
    timeLong = 10
    timeLongAccumulator = 0

    -- Session start variables
    waitingToStartTimerOn = 0
    waitingToStart = false
    waitingToStartBehindSC = false
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
    scManualCallin = false
    checkLeaderPos = false
    underSCLapCount = 0
    raceLeader = nil

    trustableSplinePostionsById = {}
    
end

--#############################################################
--################# CAR TRACKER LOGIC #########################
--#############################################################

local function processSessionStart(sessionIndex)
    timeAccumulator = 0
    stateCheckTime = 0
    startCheckTime = 0
    startDelayTime = 0
    runOnceTable = {}
    sfCheckTime = 0
    allCarsCrossed = false
    hasCrossedSF={}
    prevSplines = {}
    prevDistances = {}
    realDistanceCheckTime = 0
    realDistancesTracker = {}
    retiredCars = {}
    sharedData.raceHasStarted = false

    if ac.getSession(sessionIndex).type == ac.SessionType.Race or ac.isInReplayMode() then
        isRace = true
    else
        isRace = false
    end
    openLogFiles()
    writeLog("SC: Car tracker Initialized on Session Start - session type is: " .. ac.getSession(sessionIndex).type .. " session is replay: " .. tostring(ac.isInReplayMode()))
end
--#############################################################
--################# CAR TRACKER LOGIC END #####################
--#############################################################

ac.onSessionStart(function(sessionIndex, restarted)
    currentSession = ac.getSession(sessionIndex)
    initializeSSStates()
    initializeSCScript()
    processSessionStart(sessionIndex)
    writeLog("SC: Safety Car Script Initialized on Session Start")
end)

initializeSSStates()
initializeSCScript()
processSessionStart(0)
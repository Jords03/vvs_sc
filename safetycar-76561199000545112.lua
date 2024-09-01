
SCRIPT_NAME = "VVS Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Get states
local sim = ac.getSim()
local currentSession = ac.getSession(sim.currentSessionIndex)
local safetyCarName = "Safety Car"
local adminName = "Jon Astrop"

local safetyCarID
local safetyCar
local adminCarID
local adminCar

-- Safety Car Speeds and thresholds
local trackLength
local safetyCarPitLaneSpeed
local safetyCarInitialSpeed
local safetyCarSpeed
local safetyCarInSpeed
local scLeadDistThresholdMin
local distanceThresholdMeters
local carSpacing
local inPitTimeLimit
local carPitEntryTimes
local retiredCars
local previousGapToSC
local carsNotGainingOnSC
local gainingTimeThreshold
local minConnectedCars

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

-- Leaderboard variables
local carLeaderboard
local prevDistances
local hasCrossedSF
local prevSplines 
local sfCheckHeartBeat
local sfCheckTime
local allCarsCrossed

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

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message)
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

local function initializeSCScript()
    writeLog("SC: Safety Car Script Initialized")
    initializeSSStates()
    physics.setCarAutopilot(false, false)
    scOnTrack = false
    scRequested = false
    scHeadingToPit = false

    getAdminCar()

    if ac.tryToTeleportToPits() then
        ac.tryToOpenRaceMenu(nil)
        if ac.tryToStart() then
            scInPitLane = true
            writeLog("SC: Teleportation to pit and start successful")
        else
            writeLog("SC: Start failed. Retrying...")
            waitingToStart = true
        end
    else
        writeLog("SC: Teleport failed. Retrying...")
        waitingToTeleport = true
    end

    -- Set track length dependent thresholds
    if trackLength >= 3500 then
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
    end
    SC_CALLIN_THRESHOLD_END = SC_CALLIN_THRESHOLD_START + 0.25
    
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
        end
    end
    return true
end

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    writeLog("SC: Chat Msg: " .. message .. " | Car ID: " .. senderCarIndex)
    return processChatMessage(message, senderCarIndex)
end)

local function checkSFCrossing()
    if allCarsCrossed then return end

    if timeAccumulator - sfCheckTime  >= sfCheckHeartBeat then
        local anyFalse = false

        for i, car in ac.iterateCars.ordered() do
            --first go we will have no stored splines
            if prevSplines[car.index] == nil then
                prevSplines[car.index] = car.splinePosition
            else
                --spline has gone from 0.9x to 0.0x
                if prevSplines[car.index] > 0.9 and car.splinePosition < 0.1 then
                    hasCrossedSF[car.index] = true
                end
            end
            --check if any are false still
            if hasCrossedSF[car.index] == nil then
                anyFalse = true
            end
        end
        --all cars have passed the check, disable it
        if not anyFalse then allCarsCrossed = true end
        sfCheckTime = timeAccumulator
    end
end

local function getLeaderboard()
    --ac.log("get leaderboard")
    local carPosList = {}
    for i, car in ac.iterateCars.ordered() do
        if car == safetyCar then
            break
        end

        --get distance
        local distanceDriven = (car.splinePosition * trackLength) + (car.lapCount * trackLength)
        
        if prevDistances[car.index] == nil then
            prevDistances[car.index] = trackLength * -2
        end

        --deal with cars that haven't crossed the SF yet - given them a negative distance driven that approaches 0 as they get to the line
        --only applies to cars with lap count of 0
        if car.lapCount == 0 then
            --for cars that haven't yet crossed the start finish
            if hasCrossedSF[car.index] == nil then
                --sanity check that the spline is over 0.1 so we don't accidentally pick up someone that has just crossed the line
                if car.splinePosition > 0.1 then
                    distanceDriven = (1 - car.splinePosition) * trackLength * -1
                end
            end
        end

        --writeLog(car.splinePosition .. "|" .. trackLength .. "|" .. car.lapCount .. "|".. distanceDriven .. "|" .. prevDistances[car.index] )
        if not car.isInPit and car.speedKmh > 3 then
            -- sanity check - if it's less than the previous distance then discard and go with previous measurement
            if distanceDriven >= prevDistances[car.index] then
                prevDistances[car.index] = distanceDriven
            else
                writeLog("SANITY CHECK FAILED! " .. car:driverName() .. car.splinePosition .. "|" .. trackLength .. "|" .. car.lapCount .. "|".. distanceDriven .. "|" .. prevDistances[car.index] )
                distanceDriven = prevDistances[car.index]
            end
        end

        carPosList[#carPosList + 1] = {car=car, distanceDriven=distanceDriven}
    end
    table.sort(carPosList, function (k1, k2) return k1.distanceDriven > k2.distanceDriven end )
    --[[for pos=1, #carPosList, 1 do
        writeLog(carPosList[pos].car:driverName() .. " - in position " .. pos ..  " - distanceDriven " .. carPosList[pos].distanceDriven .. " - lap count " .. carPosList[pos].car.lapCount)
    end]]
    return carPosList
end

-- Calculate the normalized distance behind the safety car
local function calculateDistanceBehind(carPosition, car2Position)
    local distance = (car2Position - carPosition) % 1
    return distance  -- Always a value between 0 and 1
end

-- Update car statuses and gaps to SC
local function updateCarStatuses()
    local scSplinePos = safetyCar.splinePosition
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
                local carSplinePos = car.splinePosition
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

                if car.racePosition == 1 then
                    --writeLog("SC: CarStatus: Lead car : " .. car:driverName() )
                    raceLeader = car
                end
            end
        end
    end
end

-- Check if the Safety Car can come in based on the number of cars and their positions
local function canSafetyCarComeIn()

    updateCarStatuses()

    local connectedCars = sim.connectedCars
    local retiredCarsCount = #retiredCars
    local carsNotGainingCount = #carsNotGainingOnSC

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

        if not (retiredCars[car.index] or carsNotGainingOnSC[car.index] or car ~= safetyCar) then
            local distanceToSC = calculateDistanceBehind(car.splinePosition, safetyCar.splinePosition)
            local distanceMeters = distanceToSC * trackLength
            if car and distanceMeters < distanceThresholdMeters then
                carsNearAndBehindSC = carsNearAndBehindSC + 1
            end
        end
    end

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

    carLeaderboard = getLeaderboard()
    if carLeaderboard[1] then 
        sessionLeader = carLeaderboard[1].car

        ac.debug("SC: SessionState Leader", sessionLeader:driverName())

        for i = 1, #carLeaderboard, 1 do
            local car = carLeaderboard[i].car
            if not (car.isInPit or car.isInPitlane or car == safteyCar) then
                leadingCarNotInPit = car
                ac.debug("SC: Leading Car Behind SC: ", car:driverName())
                break
            end
        end

        if leadingCarNotInPit then
            local scSplinePos = safetyCar.splinePosition
            local carSplinePos = leadingCarNotInPit.splinePosition
            local distance = calculateDistanceBehind(carSplinePos, scSplinePos)

            distanceMeters = distance * trackLength
            ac.debug("SC: LC distance to SC:", distanceMeters)
            ac.debug("SC: scSplinePos:", scSplinePos)
        end
    end

    return leadingCarNotInPit, distanceMeters
end

function script.update(dt)
    if sim.connectedCars < (minConnectedCars + 1) then return end

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt
    ac.debug("SC: timeAccumulator", timeAccumulator)
    ac.debug("SC: In pitlane", safetyCar.isInPitlane)
    ac.debug("SC: In pitbox", safetyCar.isInPit)

    checkSFCrossing()

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

        if carLeaderboard[1] then
            ac.debug("SC: carLeaderboard[1].car ", carLeaderboard[1].car:driverName())
            -- Update leaderboards
            carLeaderboard = getLeaderboard()
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
        if allCarsCrossed and scOnTrack then
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
        if not scHeadingToPit then
            if scOnTrack then
                local scSplinePos = safetyCar.splinePosition
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
                carLeaderboard = getLeaderboard()
                if carLeaderboard[1] then
                    raceLeader = carLeaderboard[1].car
                    underSCLapCount = raceLeader.lapCount
                    checkLeaderPos = true
                end
                writeLog("SC: Leader on Pit Entry" .. raceLeader:driverName())
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
        if underSCLapCount < raceLeader.lapCount then
            local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
            ac.sendChatMessage("SC: Go Green | " .. timeStamp)
            checkLeaderPos = false
            writeLog("SC: Go Green")
            writeLog("SC: Leader Lap Count - GO Green" .. raceLeader.lapCount)
        end
    end

    ac.debug("SC: Safety Car In Pit Lane", scInPitLane)
    ac.debug("SC: Safety Car Requested", scRequested)
    ac.debug("SC: Safety Car Heading to Pit", scHeadingToPit)
    ac.debug("SC: Safety Car On Track", scOnTrack)

end

function initializeSSStates()
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

    -- Leaderboard variables
    carLeaderboard = {}
    prevDistances = {}
    hasCrossedSF = {}
    prevSplines = {}
    sfCheckHeartBeat = 1
    sfCheckTime = 0
    allCarsCrossed = false

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
end

ac.onSessionStart(function(sessionIndex, restarted)
    currentSession = ac.getSession(sessionIndex)
    initializeSCScript()
    writeLog("SC: Safety Car Script Initialized on Session Start")
end)

initializeSCScript()

SCRIPT_NAME = "VVS Safety Car"
SCRIPT_SHORT_NAME = "VVSSC"
SCRIPT_VERSION = "0.0.0.1"
SCRIPT_VERSION_CODE = 00001

-- Get states
local sim = ac.getSim()
local safetyCarID = ac.getCarByDriverName("Safety Car")
local safetyCar = ac.getCar(safetyCarID)
local currentSession = ac.getSession(sim.currentSessionIndex)
local adminName = "Jon Astrop"
local adminCar

-- Load support scripts | Do we want to show flags on stream?
-- require('sc_flags')

-- Safety Car Speeds and thresholds
local trackLength = sim.trackLengthM
local safetyCarPitLaneSpeed = 60
local safetyCarInitialSpeed = 25
local safetyCarSpeed = 120 -- Speed in km/h
local safetyCarInSpeed = 999 -- flat out
local scLeadDistThresholdMin = 200 -- update to adjust to speed of leader
local distanceThresholdMeters = 500 -- replaced by N/connected cars calc
local carSpacing = 35 -- multiplier for distance behind SC N x carSpacing
local inPitTimeLimit = 60 -- seconds
local carPitEntryTimes = {}
local retiredCars = {}
local previousGapToSC = {}
local carsNotGainingOnSC = {}
local gainingTimeThreshold = 3

-- Time accumulators
local timeHalfSec = 0.5 -- seconds
local timeHalfSecAccumulator = 0
local timeShort = 1.5
local timeShortAccumulator = 0
local timeAccumulator = 0
local timeMedium = 5
local timeMediumAccumulator = 0
local timeLong = 10
local timeLongAccumulator = 0

-- Session start variables
local waitingToStartTimerOn = 0
local waitingToStart = false
local scActive = true
local scActiveTime = 0
local scActiveCheckStartPercentage = 0.5
local gotAvgSessionTimes = false
local checkClosestCarToSC = false

-- Check Thresholds
local scDisableWithLapsToGo = 2
local SC_CALLIN_THRESHOLD_START = 0.5
local SC_CALLIN_THRESHOLD_END = 0.75

-- Base state variables
local scInPitLane = false
local scOnTrack = false
local scRequested = false
local scHeadingToPit = false
local scConditonsMet = false
local checkLeaderPos = false
local underSCLapCount = 0
local raceLeader = nil


-- Custom log file as the AC one gets overwritten | io does not work with online scripts
local logFile

local function openLogFile()
    --[[
    --local configPath = ac.getFolder(ac.FolderID.Root).."extension/lua/online/AC_RP_SafetyCar/"
    --local logFilePath = configPath .. "safety_car_log.txt"
    local logFilePath = "extension/lua/online/AC_RP_SafetyCar/safety_car_log.txt"
    --logFile, msg = io.open(logFilePath, "a")
    if not logFile then
        ac.log("SC: Failed to open log file - " .. msg)
    else
        ac.log("SC: Log file opened at " .. logFilePath)
    end
    ]]
end

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    if logFile then        
        logFile:write("[" .. timeStamp .. "] " .. message .. "\n")
        logFile:flush()
    end
    ac.log(timeStamp .. " | " .. message) 
end

local function ensureSimAndSafetyCar()
    if not sim or not safetyCar then
        writeLog("SC: sim or safetyCar is nil.")
        return false
    end
    return true
end

local function initializeSCScript()
    -- TODO: This should apparently be called on script reload, need to figure out params etc.
    -- ac.onRelease(callback, nil)
    
    writeLog("SC: Safety Car Script Initialized")
    openLogFile()
    physics.setCarAutopilot(false, false)
    scOnTrack = false
    scRequested = false
    scHeadingToPit = false

    if ac.getCarByDriverName(adminName) then
        local adminCarID = ac.getCarByDriverName(adminName)
        adminCar = ac.getCar(adminCarID)
    end

    if ac.tryToTeleportToPits() then
        ac.tryToStart()
        scInPitLane = true
    else
        writeLog("SC: Teleportation to pits failed. Retrying...")
        waitingToStart = true
    end

    -- Set track length dependent thresholds
    if trackLength <= 3500 then
        SC_CALLIN_THRESHOLD_START = 0.50
    else
        SC_CALLIN_THRESHOLD_START = 1 - (1750 / trackLength)
    end
    SC_CALLIN_THRESHOLD_END = SC_CALLIN_THRESHOLD_START + 0.1
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
    physics.setAIPitStopRequest(safetyCar.index, true)
    --physics.setAITopSpeed(safetyCar.index, safetyCarInSpeed)
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
    if scActive then
        writeLog("SC: Safety Car is being called")
        scRequested = true
        scHeadingToPit = false
        scOnTrack = false
        setSCValues(safetyCarPitLaneSpeed)
        setSCLights("on")
        writeLog("SC: Safety Car has been deployed - scon")
    else
        writeLog("SC: Safety Car cannot be deployed - too late in race")
    end
end

-- Listen to chat messages calling SC deployment or manual SC control
local function processChatMessage(message)
    if senderCarIndex == safetyCar.index or senderCarIndex == adminCar.index then
        if message == "SC scon" then
            callSafetyCar()
        elseif message == "SC scoff" then
            scHeadingToPit = true
            setSCRequestPit()
            setSCLights("off")
            writeLog("SC: Safety Car is manually called in - SC heading to pits")
        elseif message == "SC: Kill Switch" then
            initializeSCScript()
        end
    end
    return true
end

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    return processChatMessage(message, senderCarIndex)
end)

local function getLeaderboard()
    local carPosList = {}
    
    for i, car in ac.iterateCars.ordered() do
        local lapCount = car.lapCount or 0 -- Default to 0 if lapCount is nil or invalid
        local carPosition = (car.splinePosition * trackLength) + (lapCount * trackLength)
        carPosList[#carPosList + 1] = {car = car, pos = carPosition}
    end
    
    table.sort(carPosList, function(k1, k2)
        return k1.pos > k2.pos
    end)
    
    return carPosList
end

-- Update car statuses and gaps to SC
local function updateCarStatuses()
    local scSplinePos = safetyCar.splinePosition
    for i, car in ac.iterateCars.ordered() do
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
        else
            carPitEntryTimes[car.index] = nil
            retiredCars[car.index] = nil

            -- Update cars gaps to SC
            local carSplinePos = car.splinePosition
            local distanceToSC = carSplinePos - scSplinePos
            if distanceToSC < 0 then
                distanceToSC = 1 + distanceToSC
            end

            local secondsAhead = distanceToSC * trackLength / safetyCar.speedMs
            local previousSecondsAhead = previousGapToSC[car.index] or secondsAhead
            local isGaining = secondsAhead < previousSecondsAhead

            previousGapToSC[car.index] = secondsAhead
            
            if not isGaining and secondsAhead > gainingTimeThreshold then
                carsNotGainingOnSC[car.index] = {notGaining = true, secondsAhead = secondsAhead}
            else
                carsNotGainingOnSC[car.index] = nil
            end

            if car.racePosition == 1 then
                writeLog("SC: CarStatus: Lead car : " .. car:driverName() )
                raceLeader = car
            end
        end
    end
end


-- Check if a car is within threshold of the Safety Car
local function isNearSC(carPosition, safetyCarPosition, distanceThreshold)
    local distance = safetyCarPosition - carPosition
        if distance < 0 then
            distance = 1 + distance
        end
    local distanceMeters = distance * trackLength

    return distanceMeters <= distanceThreshold
end

-- Check if the Safety Car can come in based on the number of cars and their positions
local function canSafetyCarComeIn()
    if not ensureSimAndSafetyCar() then return false end
    
    updateCarStatuses()

    local connectedCars = sim.connectedCars
    local retiredCarsCount = #retiredCars
    local carsNotGainingCount = #carsNotGainingOnSC

    local N = connectedCars - retiredCarsCount - carsNotGainingCount - 1 -- -1 to exclude SC

    distanceThresholdMeters = N * carSpacing

    writeLog("SC: N = " .. N)
    writeLog("SC: Connected Cars = " .. connectedCars)
    writeLog("SC: Distance Threshold = " .. distanceThresholdMeters)

    local carsNearAndBehindSC = 0

    for i, car in ac.iterateCars.ordered() do
        if carsNearAndBehindSC >= N then
            break
        end

        if not (retiredCars[car.index]) then
            -- We don't add cars still active but in pits less than pit time limit
            if not (car.isInPitlane or car.isInPit) then
                if car and isNearSC(car.splinePosition, safetyCar.splinePosition, distanceThresholdMeters) then
                    carsNearAndBehindSC = carsNearAndBehindSC + 1
                end
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

-- Calculates the session length and the time the SC should be active for
local function sessionTimeCalcs()
    if not currentSession then return false end

    local averageBestLapTime = calculateAverageBestLapTime(currentSession)
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
    
    local carLeaderboard = getLeaderboard()
    local sessionLeader = carLeaderboard[1].car

    writeLog("SC: SessionState Leader " .. sessionLeader.carIndex .. " | " .. sessionLeader:driverName())

    for i, entry in ipairs(carLeaderboard) do
        local car = entry.car
        if not (car.isInPit or car.isInPitlane) then
            leadingCarNotInPit = car
            writeLog("SC: Get Leading Car Behind SC: " .. car:driverName())
            break
        end
    end

    if leadingCarNotInPit then
        local scSplinePos = safetyCar.splinePosition
        local carSplinePos = leadingCarNotInPit.splinePosition
        local distance = scSplinePos - carSplinePos

        if distance < 0 then
            distance = 1 + distance
        end
        distanceMeters = distance * trackLength
        ac.debug("SC: Leading car distance to SC:", distanceMeters)
    end

    return leadingCarNotInPit, distanceMeters
end

function script.update(dt)

    if not ensureSimAndSafetyCar() then return false end

    ac.debug("SC: In pitlane", safetyCar.isInPitlane)
    ac.debug("SC: In pitbox", safetyCar.isInPit)

    -- Total time passed - used for controlling delayed stuff
    timeAccumulator = timeAccumulator + dt
    ac.debug("SC: timeAccumulator", timeAccumulator)

    -- Session start sanity checks - if we are in a wait state and we have gone more than 1 second then reissue the command and reset the 1s timer
    if waitingToStart then
        if timeAccumulator - waitingToStartTimerOn >= 1 then
            if ac.tryToTeleportToPits() then
                if ac.tryToStart() then
                    waitingToStart = false
                    scInPitLane = true
                    writeLog("SC: Teleportation to pit and start successful")
                end
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
                checkClosestCarToSC = true
                setSCValues(safetyCarInitialSpeed)
                setSCLights("on")
            end
        end
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
        end
        
        local carLeaderboard = getLeaderboard()
        local sessionLeader = carLeaderboard[1].car
        
        if sessionLeader.isRaceFinished then
            scConditonsMet = true
            scHeadingToPit = true
            scRequested = false
            setSCRequestPit()
            setSCLights("off")
            ac.sendChatMessage("SC: Safety Car is heading to pits after session")
        end
        ac.debug("timeLongAccumulator", timeLongAccumulator)
        timeLongAccumulator = timeAccumulator
    end

    -- Things we do every 5 (medium) seconds
    if timeAccumulator - timeMediumAccumulator >= timeMedium then
        -- Checks for retired cars and stragglers
        updateCarStatuses()
        timeMediumAccumulator = timeAccumulator
    end

    -- Things we do every 1 (short) seconds
    if timeAccumulator - timeShortAccumulator >= timeShort then
        -- Get the leader behind the SC and set SC speed up
        if checkClosestCarToSC then
            local scSplinePos = safetyCar.splinePosition
            local scMetersPos = scSplinePos * trackLength
            local lc, lcDistance = getLeadingCarBehindSC()
            local lcGapMeters = scMetersPos - lcDistance
            ac.debug("SC: Safety Car Position on track: ", scSplinePos)
            
            local lcSpeed = lc.speedMs --speed range from 100 - 300?
            local scSpeedUpDistance = (lcSpeed * scLeadDistThresholdMin) / 100

            if lcGapMeters <= scSpeedUpDistance then
                writeLog("SC: Leader gap to Safety Car : " .. lcDistance .. "m @" .. lcSpeed)
                setSCSpeedUpValue()
                checkClosestCarToSC = false
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
                    if sim.connectedCars > 1 and canSafetyCarComeIn() then
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
            local scEnteringPitlane = safetyCar.isInPitlane
            if scEnteringPitlane then
                scOnTrack = false
                ac.sendChatMessage("SC: Safety Car is entering pit lane")
                writeLog("SC: Safety Car is entering pit lane")   
                checkLeaderPos = true
                local carLeaderboard = getLeaderboard()
                raceLeader = carLeaderboard[1].car
                underSCLapCount = raceLeader.lapCount
                writeLog("SC: Leader Lap Count" .. underSCLapCount)
            end
        end
        timeHalfSecAccumulator = timeAccumulator
    end

    if scHeadingToPit and safetyCar.isInPit then
        -- Reset SC once entering pit box
        physics.setCarAutopilot(false, false)
        ac.tryToTeleportToPits()
        scHeadingToPit = false
        scRequested = false
        scOnTrack = false
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

    --ac.debug("SC: Safety Car In Pit Lane", scInPitLane)
    --ac.debug("SC: Safety Car Requested", scRequested)
    --ac.debug("SC: Safety Car Heading to Pit", scHeadingToPit)
    --ac.debug("SC: Safety Car On Track", scOnTrack)

end

ac.onSessionStart(function(sessionIndex, restarted)
    initializeSCScript()
    currentSession = ac.getSession(sessionIndex)
    writeLog("SC: Safety Car Script Initialized on Session Start")
end)

ac.onRelease(initializeSCScript)

initializeSCScript()

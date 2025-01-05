local debug

-- Get states
local sim = ac.getSim()
local currentSession = ac.getSession(sim.currentSessionIndex)
local driverCar = ac.getCar(0)
--XXX
local safetyCarName = "Safety Car"
--local safetyCarName = "VVS SafetyCar" --this is the old skin ui name, have renamed
local safetyCar = nil
local adminCarName = "Jon Astrop"
local adminCar = nil
local trackLength = sim.trackLengthM

--shared data structure for sc flags settings
local scFlagsValues = ac.connect({
    ac.StructItem.key('vvs.sc_flags_pos'),
    posVec2 = ac.StructItem.vec2(),
    settingsOpen = ac.StructItem.boolean()
}, true, ac.SharedNamespace.Shared)

-- Safety Car state variables
local scState = {
    deployed = "DEPLOYED",
    returning = "ENDING",
    enteringPit = "CLEAR",
    inPit = "IN PITBOX",
    getReady = "GET READY",
    rollingStart = "ROLLING START",
    off = "",
    settings = "SETTINGS"
}

local scHeadingTextState = {
    sc = "SAFETY CAR",
    green = "GREEN FLAG"
}

local scRollingTextState = {
    start = "FOLLOW IN SINGLE FILE",
    ending = "WATCH FOR GREEN FLAG",
    maintain = "MAINTAIN YOUR SPEED",
    off = ""
}

local scLeaderTextState = {
    leader = "YOU ARE RACE LEADER",
    maintain = "MAINTAIN YOUR SPEED",
    goAnyTime = "GO AT ANY TIME",
    watch = "GET READY",
    off = ""
}

local scHelperTextState = {
    catchSC = "CATCH THE SAFETY CAR",
    catchPack = "CATCH THE CAR AHEAD",
    closeGap = "TOO FAR - CLOSE GAP",
    erratic = "DON'T DRIVE ERRATICALLY",
    passSafetyCar = "PASS SAFETY CAR - CATCH PACK",
    noOvertake = "NO OVERTAKING",
    off = ""
}

-- Initialize variables
local flagColor = rgbm.colors.gray
local showFlags = false
local scFlagSettings = scFlagsValues.settingsOpen
local goGreen = false
local scOnTrack = false
local rollingStart = false
local scCleared = false
local headingToPits = false
local conditionsMet = false
local getCarLapCounts = false
local checkGoGreen = false
local carLapCounts = {}
local raceLeaderCar = nil
local prevRaceLeaderCar = nil
local leaderChangedLastBeat = false
local driverCarSpeed = 0
local rollingStartPenalties = {}

-- Text variables
local speedLimit = 100
local headFontSize = 22
local fontsize = 28
local helperFontsize = 16
local scHeadingText = scHeadingTextState.sc
local scHeadingTextBG = rgbm.colors.black
local scHeadingTextColor = rgbm.colors.yellow
local scTextColor = rgbm.colors.white
local scHelperTextColor = rgbm.colors.red
local scLeaderTextColor = rgbm.colors.orange
local scStatusText = ""
local scLeaderText = ""
local scHelperText = ""

-- Timer variables
local timeAccumulator = 0
local checkStatesAccumulator = 0
local erraticCheckAccumulator = 0
local timeToDisplayTextAccumulator = 0
local timeToDisplayGreenAccumulator = 0
local leaderCheckTime = 0

-- Time duration variables
local miniCheckInterval = 0.1
local medCheckInterval = 0.3
local checkStatesInterval = 60
local timeToDisplaySCText = 2
local timeToDisplayGreen = 5
local erraticTimer = 0
local erraticDisplayDuration = 1.5

-- Audio variables
local scGoGreenAudio
local scClearAudio
local scInThisLapAudio
local scDeployedAudio
local audioSCClearEvent
local audioSCGoGreenEvent
local audioSCInThisLapEvent
local audioSCDeployedEvent

-- Window variables
local flagWindowPos
local flagWindowSize = vec2(300, 180)
local defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
local defaultFlagWindowPosY = (sim.windowHeight/4) - (flagWindowSize.y/2)

if scFlagsValues.posVec2 == vec2(0.0) or nil then
    scFlagsValues.posVec2 = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
    flagWindowPos = scFlagsValues.posVec2
else
    flagWindowPos = scFlagsValues.posVec2
end

-- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
local previousDriverCarState = nil
local previousHelperTextState = nil
local previousMinus1HelpertextState = nil
local distanceThreshold = 16
local distanceThresholdMultiplier = 2.5
local distanceEndingThreshold = 250


-- Combined threshold values for detecting erratic behavior
local erraticThresholds = {
    suddenSpeedChange = 8,    -- km/h
    suddenSteer = 30,         -- degrees
    highAngularVelocity = 0.70   -- rad/s, for swerving detection
}

-- Get states from nill checks and late connections
local function getStates()
    sim = sim or ac.getSim()
    if sim then
        currentSession = currentSession or ac.getSession(sim.currentSessionIndex)
    end
    driverCar = ac.getCar(0)

    local safetyCarID = ac.getCarByDriverName(safetyCarName)
    if safetyCarID then
        ac.log("SC identified as:" .. safetyCarID)
        safetyCar = ac.getCar(safetyCarID)
    end

    local adminCarID = ac.getCarByDriverName(adminCarName)
    if adminCarID then
        adminCar = ac.getCar(adminCarID)
    end
end

local function reInitailizeVars()
    -- Initialize variables
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    scOnTrack = false
    rollingStart = false
    scCleared = false
    headingToPits = false
    conditionsMet = false
    getCarLapCounts = false
    checkGoGreen = false
    carLapCounts = {}
    raceLeaderCar = nil
    prevRaceLeaderCar = nil
    leaderChangedLastBeat = false
    driverCarSpeed = 0
    rollingStartPenalties = {}

    -- Text variables
    scHeadingText = scHeadingTextState.sc
    scHeadingTextBG = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.white
    scHelperTextColor = rgbm.colors.red
    scLeaderTextColor = rgbm.colors.orange
    scStatusText = ""
    scLeaderText = ""
    scHelperText = ""

    --- Timer variables
    timeAccumulator = 0
    checkStatesAccumulator = 0
    erraticCheckAccumulator = 0
    timeToDisplayTextAccumulator = 0
    timeToDisplayGreenAccumulator = 0
    erraticTimer = 0
    leaderCheckTime = 0

    -- Window variables
    flagWindowSize = vec2(300, 180)
    defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
    defaultFlagWindowPosY = (sim.windowHeight/7)
    if scFlagsValues.posVec2 == vec2(0.0) or nil then
        scFlagsValues.posVec2 = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
        flagWindowPos = scFlagsValues.posVec2
    else
        flagWindowPos = scFlagsValues.posVec2
    end
    scFlagSettings = scFlagsValues.settingsOpen

    -- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
    previousDriverCarState = nil
    previousHelperTextState = nil
    previousMinus1HelpertextState = nil

end

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message) -- Also log to the default writeLog
end
--[[ 
local function setDebugConditions()
    setRollingStartConditions()
end ]]

local function repositionFlags()
    flagWindowPos = scFlagsValues.posVec2
end

local function initializeSCFlagScript()
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    scOnTrack = false
    rollingStart = false
    debug = false
    getStates()
    reInitailizeVars()
end

-- Define the callback function
local function logAudioCallback(err, folder)

    -- NEW SOUNDS With Crewchief audio
    scDeployedAudio = folder .. "/sc_safetycarisout.wav"
    scInThisLapAudio = folder .. "/sc_safetycarinthislap.wav"
    scClearAudio = folder .. "/sc_safetycarisclear.wav"
    scGoGreenAudio = folder .. "/sc_greengreengreen.wav"

    -- LOCAL FILES - NEW SOUNDS With Crewchief audio
    --scDeployedAudio = "sc_safetycarisout.wav"
    --scInThisLapAudio = "sc_safetycarinthislap.wav"
    --scClearAudio = "sc_safetycarisclear.wav"
    --scGoGreenAudio = "sc_greengreengreen.wav"

    scDeployedAudio = {
        filename = scDeployedAudio,
        stream = { name = 'scDeployedStream', size = 1024 },
        use3D = false,
        useOcclusion = false,
        loop = false,
        insideConeAngle = 360,
        outsideConeAngle = 360,
        outsideVolume = 1.0,
        minDistance = 1,
        maxDistance = 10000,
        dopplerEffect = 1.0,
        ac.AudioDSP[ac.AudioDSP.Normalize],
    }
        
    scInThisLapAudio = {
        filename = scInThisLapAudio,
        stream = { name = 'scInThisLapStream', size = 1024 },
        use3D = false,
        useOcclusion = false,
        loop = false,
        insideConeAngle = 360,
        outsideConeAngle = 360,
        outsideVolume = 1.0,
        minDistance = 1,
        maxDistance = 10000,
        dopplerEffect = 1.0,
        ac.AudioDSP[ac.AudioDSP.Normalize],
    }

    scClearAudio = {
        filename = scClearAudio,
        stream = { name = 'scClearStream', size = 1024 },
        use3D = false,
        useOcclusion = false,
        loop = false,
        insideConeAngle = 360,
        outsideConeAngle = 360,
        outsideVolume = 1.0,
        minDistance = 1,
        maxDistance = 10000,
        dopplerEffect = 1.0,
        ac.AudioDSP[ac.AudioDSP.Normalize],
    }

    scGoGreenAudio = {
        filename = scGoGreenAudio,
        stream = { name = 'scGoGreenStream', size = 1024 },
        use3D = false,
        useOcclusion = false,
        loop = false,
        insideConeAngle = 360,
        outsideConeAngle = 360,
        outsideVolume = 1.0,
        minDistance = 1,
        maxDistance = 10000,
        dopplerEffect = 1.0,
        ac.AudioDSP[ac.AudioDSP.Normalize],
    }

    audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
    audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
    audioSCClearEvent = ac.AudioEvent.fromFile(scClearAudio, false)
    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)

end

-- Call web.loadRemoteAssets with the URL and the logging callback
web.loadRemoteAssets("https://raw.githubusercontent.com/Jords03/vvs_sc/main/sc_wav_files_001.zip", logAudioCallback)

local function setRollingStartConditions()
    flagColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scStatusText = scState.rollingStart
    scHeadingText = scHeadingTextState.sc
    showFlags = true
    rollingStart = true
    scOnTrack = true
    conditionsMet = false
    headingToPits = false
    scCleared = false
    goGreen = false
end

local function scDeployed()
    writeLog("SC: Recieved - Safety Car deployed")
    flagColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scStatusText = scState.deployed
    scHeadingText = scHeadingTextState.sc
    --scLeaderText = scLeaderTextState.leader
    headingToPits = false
    conditionsMet = false
    rollingStart = false
    scCleared = false
    showFlags = true
    goGreen = false
    scOnTrack = true
    audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
    audioSCDeployedEvent.volume = 5
    audioSCDeployedEvent:start()    
end

local function scInThisLap()
    writeLog("SC: Recieved - Safety Car in this lap")
    flagColor = rgbm(0.6, 0.6, 0, 1)
    scStatusText = scState.returning
    scTextColor = rgbm.colors.black
    scLeaderText = scLeaderTextState.maintain
    --TODO: For rolling start only?
    --scHelperText = scHelperTextState.noOvertake
    headingToPits = true
    scCleared = false
    conditionsMet = true
    getCarLapCounts = true
    showFlags = true
    goGreen = false
    scOnTrack = true
    audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
    audioSCInThisLapEvent.volume = 5
    audioSCInThisLapEvent:start()
    timeToDisplayTextAccumulator = timeAccumulator
end

local function scIsClear()
    writeLog("SC: Recieved - Safety Car is clear")
    flagColor = rgbm(0.4, 0.4, 0.4, 1)
    scStatusText = scState.enteringPit
    scTextColor = rgbm.colors.yellow
    scLeaderText = scLeaderTextState.goAnyTime
    scHelperText = scHelperTextState.noOvertake
    showFlags = true
    scCleared = true
    scOnTrack = false
    checkGoGreen = true
    goGreen = false
    audioSCClearEvent = ac.AudioEvent.fromFile(scClearAudio, false)
    audioSCClearEvent.volume = 5
    audioSCClearEvent:start()
    timeToDisplayTextAccumulator = timeAccumulator
end

local function setConditionsLateJoin()
-- TODO: Catch late joiners to grid if rolling start message already sent?
    -- this needs testing/checking
    if sim.raceSessionType == 3 and safetyCar and safetyCar.isConnected  then
        ac.log("SC: Safety Car is connected")
        if not (safetyCar.isInPit or safetyCar.isInPitlane) then
            scOnTrack = true
            if safetyCar.splinePosition < 0.1 and safetyCar.speedMs < 0.5 then
                ac.log("SC: Safety Car is on track close to start/finish")
                setRollingStartConditions()
            else
                ac.log("SC: Safety Car is on track but not stationary")
            end
        end
    end
end

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    if string.startsWith(message, "SC:") then
        if not safetyCar then
            getStates()
        end
        if (senderCarIndex == safetyCar.index or senderCarIndex == adminCar.index) then
            writeLog("SC: chatmsg: " .. message)
            if message == "SC: Safety Car rolling start" then
                writeLog("SC: Recieved - Safety Car rolling start")
                setRollingStartConditions()
            elseif message == "SC: Safety Car deployed" then
                scDeployed()
            elseif message == "SC: Safety Car in this lap" then
                scInThisLap()
            elseif message == "SC: Safety Car is clear" then
                scIsClear()
            elseif message == "SC: Safety Car has reset in pits" then
                writeLog("SC: Recieved - Safety Car has reset in pits")
                --flagColor = rgbm.colors.gray
                --showFlags = true
                --UNUSED
            elseif string.startsWith(message, "SC: Go Green") then
                writeLog("SC: Recieved - Go Green")
                -- Unused -> we track leader on client side for accuracy
            elseif message == "SC kill" then
                initializeSCFlagScript()
                writeLog("SC: Recieved - SC kill")
            end
        end
    end
    if string.startsWith(message, "SC: INFO") then
        table.insert(rollingStartPenalties, message)

        ac.log("SC: Info message: " .. message)
    end
    return true
end)

--XXX 
-- ################################################################
-- SINGLE PLAYER TESTING WITH LIMITED AI CAR CONTROL
-- Set the field to use slower cars than SC and try have SC at front
-- Requires track surfaces.ini to have extended physics entry for apps
-- [_SCRIPTING_PHYSICS]
-- ALLOW_APPS = 1 ; Allow Lua apps to access physics API
--[[ 
local btnSCRoll = ac.ControlButton('app.sc_flags/scroll', ui.KeyIndex.R)
btnSCRoll:onPressed(function()
    writeLog("SC: Recieved - Safety Car rolling start")
    setRollingStartConditions()
    for i, car in ac.iterateCars.ordered() do
        if car ~= driverCar then
            physics.setAIThrottleLimit(car.index, 0.5)
            physics.setAITopSpeed(car.index, 100)
            physics.setAIAggression(car.index, 0.6)
            physics.setAISplineAbsoluteOffset(car.index, 0, true)
        end
    end
end)

local btnSCOn = ac.ControlButton('app.sc_flags/scon', ui.KeyIndex.A)
btnSCOn:onPressed(function()
    scDeployed()
    for i, car in ac.iterateCars.ordered() do
        if car ~= driverCar then
            physics.setAICaution(car.index, 10)
            physics.setAIThrottleLimit(car.index, 0.5)
            physics.setAITopSpeed(car.index, 100)
            physics.setAIAggression(car.index, 0.6)
            physics.setAISplineAbsoluteOffset(car.index, 0, true)
        end
    end
end)

local btnSCPits = ac.ControlButton('app.sc_flags/scpits', ui.KeyIndex.S)
btnSCPits:onPressed(function()
    scInThisLap()
    for i, car in ac.iterateCars.ordered() do
        if car ~= driverCar then
            physics.setAICaution(car.index, 5)
            physics.setAIThrottleLimit(car.index, 0.5)
            physics.setAITopSpeed(car.index, 100)
            physics.setAIAggression(car.index, 0.6)
        end
        if car == safetyCar then
            physics.setAIPitStopRequest(car.index, true)
            physics.setAITopSpeed(car.index, 120)
            physics.setAILookaheadGasBrake(car.index, 15)
        end
    end
end)

local btnSCOff = ac.ControlButton('app.sc_flags/scoff', ui.KeyIndex.D)
btnSCOff:onPressed(function()
    scIsClear()
    if rollingStart then
        for i, car in ac.iterateCars.ordered() do
            if car ~= driverCar then
                physics.setAIThrottleLimit(car.index, 1)
                physics.setAITopSpeed(car.index, 100)
                physics.setAIAggression(car.index, 0.9)
                physics.setAISplineOffset(car.index, 0, false)
            end
        end
    else
        for i, car in ac.iterateCars.ordered() do
            if car ~= driverCar then
                --physics.setCarAutopilot(true, false)
                physics.setAIThrottleLimit(car.index, 1)
                physics.setAITopSpeed(car.index, 100)
                physics.setAIAggression(car.index, 0.9)
                physics.setAISplineOffset(car.index, 0, false)
            end
            if car == safetyCar then
                --physics.setAINoInput(car.index, true, false)
                physics.setAITopSpeed(car.index, 10)
            end
        end
    end
end)
 ]]
-- ################################################################

-- Calculate the normalized distance behind the safety car
local function calculateDistanceTo(carPosition, otherPosition)
    if carPosition > otherPosition then
        otherPosition = otherPosition + 1
    end
    return otherPosition - carPosition  -- Always a value between 0 and 1
end

-- Function to detect erratic driving behavior and check distance
local function detectErraticAndPos(dt)

    local car = driverCar
    if not car then return end

    driverCarSpeed = math.floor(car.speedKmh * 10) / 10

    local carAhead = nil
    local tooFar = false
    local catchSC = false
    local passSafetyCar = false
    local distanceToSC = 0
    local carDistance = 0

    -- Calculate the distance behind the safety car
    local distanceBehindSC = calculateDistanceTo(car.splinePosition, safetyCar.splinePosition)
    distanceToSC = distanceBehindSC * trackLength --for debugging only

    -- Find the next car ahead on track
    local minDistanceAhead = 1  -- Initialize with maximum possible spline position difference
    for i, otherCar in ac.iterateCars.ordered() do
        if otherCar ~= safetyCar and otherCar ~= car and otherCar.isConnected and not (otherCar.isInPitlane or otherCar.isInPit) then
            local distanceAhead = calculateDistanceTo(car.splinePosition, otherCar.splinePosition)
            if distanceAhead > 0 and distanceAhead < minDistanceAhead then
                minDistanceAhead = distanceAhead
                carAhead = otherCar
            end
        end
    end

    --writeLog("Car ahead is: " .. carAhead:driverName() .. " and is " .. minDistanceAhead * trackLength .. " ahead")

    -- if leader then car ahead is the safety car
    if car == raceLeaderCar then
        carAhead = safetyCar
        minDistanceAhead = distanceBehindSC
    elseif raceLeaderCar ~= nil then
        local distanceBehindLeader = calculateDistanceTo(car.splinePosition, raceLeaderCar.splinePosition)
        local betweenLeaderAndSafetyCar = (distanceBehindLeader >= distanceBehindSC)
        if betweenLeaderAndSafetyCar then
            passSafetyCar = true
        end
    end
    -- Calculate the distance to the car ahead
    if carAhead then
        carDistance = minDistanceAhead * trackLength
        --ac.debug("SC Flags: minDistanceAhead", minDistanceAhead)
        tooFar = carDistance > distanceThreshold

        if (carDistance > (distanceThreshold * distanceThresholdMultiplier)) then
            catchSC = true
        end
    end

    if previousDriverCarState then
        -- Calculate speed, steering, and angular velocity changes
        local speedChange = math.abs(car.speedKmh - previousDriverCarState.speedKmh)
        local steerChange = math.abs(car.steer - previousDriverCarState.steer)
        local angularVelocityChange = math.abs(car.angularVelocity.y)

        -- Check if any condition for erratic driving is met
        local isErratic = (
            speedChange > erraticThresholds.suddenSpeedChange or
            steerChange > erraticThresholds.suddenSteer or
            angularVelocityChange > erraticThresholds.highAngularVelocity
        )

        -- Handle erratic check timer using dt
        if isErratic then
            erraticTimer = erraticDisplayDuration
        elseif erraticTimer > 0 then
            erraticTimer = erraticTimer - miniCheckInterval
        end

        -- Determine if the erratic state should still be displayed
        local erraticActive = erraticTimer > 0

        -- Prioritize conditions
        local newHelperTextState = scHelperTextState.noOvertake

        if car == raceLeaderCar then
            scLeaderText = scLeaderTextState.leader
        end

        if scCleared then
            newHelperTextState = scHelperTextState.noOvertake
        elseif passSafetyCar then
            newHelperTextState = scHelperTextState.passSafetyCar
        elseif catchSC and scStatusText ~= scState.returning then
            if car == raceLeaderCar then
                newHelperTextState = scHelperTextState.catchSC .. " - " .. math.floor(carDistance) .. "m"
            else
                newHelperTextState = scHelperTextState.catchPack .. " - " .. math.floor(carDistance) .. "m"
            end
        -- TODO: Commenting out erratic as it seemed to sensitive
        --elseif erraticActive then  -- Use the timer-controlled state instead of direct isErratic
        --  newHelperTextState = scHelperTextState.erratic
        elseif tooFar then
            newHelperTextState = scHelperTextState.closeGap .. " - " .. math.floor(carDistance) .. "m"
        end

        if newHelperTextState ~= previousHelperTextState then
            --writeLog("state change")
            if car == raceLeaderCar and scStatusText == scState.returning then
                -- Replaced with UI elements
                --scLeaderText = scLeaderTextState.maintain
                --scHelperText = math.floor(car.speedKmh) .. " km/h"
                scLeaderText = scLeaderTextState.off
                scHelperText = scHelperTextState.off
                previousHelperTextState = newHelperTextState
            elseif car == raceLeaderCar and scStatusText == scState.enteringPit then
                scLeaderText = scLeaderTextState.goAnyTime
            else
                -- sanitise pass and closegap messages - if we are switching to one of these, then wait a beat and only do it if we still have the same outcome
                if previousMinus1HelpertextState == nil then
                    --prev minus 1 is nil so this is the first beat that we changed, if this is one that we need to sanitise then just store it
                    if newHelperTextState == scHelperTextState.catchSC or newHelperTextState == scHelperTextState.closeGap or newHelperTextState == scHelperTextState.catchPack  then
                        previousMinus1HelpertextState = newHelperTextState
                    else
                        --it isn't one we care about sanitising to just store prev and set this one
                        previousHelperTextState = newHelperTextState
                        scHelperText = newHelperTextState
                        --writeLog("dont care: " .. scHelperText)
                    end
                else -- prev minus 1 is not nil so this is a second beat to check
                    --sanity check that we have the same result on next beat
                    if previousMinus1HelpertextState == newHelperTextState then
                        --we do so set the values and continue
                        scHelperText = newHelperTextState
                        --writeLog("do care: " .. scHelperText)
                        previousMinus1HelpertextState = nil
                        previousHelperTextState = newHelperTextState
                    else
                        --sanity check failed, this is a different condition than last time - just reset the prev minus 1 check
                        previousMinus1HelpertextState = nil
                    end
                end
            end
        end

        ac.debug("SC Flags: Inside Pos Check", dt)
        ac.debug("SC Flags: Inside Pos Check catchSC", catchSC)

        -- Debugging output
        --[[ ac.debug("SC Flags: newHelperTextState", newHelperTextState)
        ac.debug("SC Flags: previousHelperTextState", previousHelperTextState)
        ac.debug("SC Flags: DT", dt)
        ac.debug("SC Flags: 1-Driver", car:driverName())
        if raceLeaderCar then
            ac.debug("SC Flags: 2-RaceLeaderCar", raceLeaderCar:driverName())
        end
        ac.debug("SC Flags: 3-distanceToSC", distanceToSC)
        ac.debug("SC Flags: 4-carDistance", carDistance)
        ac.debug("SC Flags: catchSC", catchSC)
        ac.debug("SC Flags: isErratic", isErratic)
        ac.debug("SC Flags: erraticActive", erraticActive)
        ac.debug("SC Flags: tooFar", tooFar)
        ac.debug("SC Flags: prevState", true)
        ac.debug("SC Flags: showFlags", showFlags) ]]
    else
        --ac.debug("SC Flags: prevState", false)
        scHelperText = scHelperTextState.noOvertake
    end

    -- Update previous driver car state for the next frame
    previousDriverCarState = {
        speedKmh = car.speedKmh,
        steer = car.steer,
        angularVelocity = car.angularVelocity
    }
end


local function textSize(text_size, fontsize)
    local calcTextSize = ui.measureDWriteText(text_size, fontsize)
    return calcTextSize
end

local function uiFlags(dt)
    if showFlags or scFlagsValues.settingsOpen or debug then       

        ui.beginTransparentWindow("SC Flags", flagWindowPos, flagWindowSize, true, false)        

        local availableSpaceY = ui.availableSpaceY()
        local sectionGridAvailableSpaceY = ui.availableSpaceY() / 4
        
        local scHeadingTextBoxStart = vec2(0,0)
        local scHeadingTextBoxEnd = vec2(ui.availableSpaceX(), ui.availableSpaceY() / 4)
        local scFlagBoxStart = vec2(scHeadingTextBoxStart.x, sectionGridAvailableSpaceY)
        local scFlagBoxEnd = scFlagBoxStart + vec2(scHeadingTextBoxEnd.x, sectionGridAvailableSpaceY*2)
        
        local scHeadingRectSize = scHeadingTextBoxEnd - scHeadingTextBoxStart
        local scFlagBoxSize = scFlagBoxEnd - scFlagBoxStart

        local scHeadingRectCenter = scHeadingTextBoxStart + (scHeadingRectSize / 2)
        local scFlagBoxCenter = scFlagBoxStart + (scFlagBoxSize / 2)
        local scHelperTextCenter = vec2(ui.availableSpaceX()/2, (sectionGridAvailableSpaceY*3)+(sectionGridAvailableSpaceY/3))

        local scHeadingTextSize = textSize(scHeadingText, headFontSize)
        local scStatusTextSize = textSize(scStatusText, fontsize)
        local scLeaderTextSize = textSize(scLeaderText, helperFontsize)
        local scHelperTextSize = textSize(scHelperText, helperFontsize)

        local scHeadingTextStart = scHeadingRectCenter - (scHeadingTextSize / 2)
        local scStatusTextStart = scFlagBoxCenter - (scStatusTextSize / 2)
        local scLeaderTextStart = scHelperTextCenter - (scLeaderTextSize / 2)
        local scHelperTextStart = scHelperTextCenter - (scHelperTextSize / 2)
        ui.pushDWriteFont("RealPenalty")

        if (not rollingStart or not conditionsMet)
        and (not (driverCar == raceLeaderCar and conditionsMet) or scCleared)
        or goGreen
        or debug
        then
            --Draw main flag box for everyone
            
            ui.drawRectFilled(scHeadingTextBoxStart, scHeadingTextBoxEnd, scHeadingTextBG, 5, ui.CornerFlags.Top)
            ui.dwriteDrawText(scHeadingText, headFontSize, scHeadingTextStart, scHeadingTextColor)

            ui.drawRectFilled(scFlagBoxStart, scFlagBoxEnd, flagColor, 5, ui.CornerFlags.Bottom)
            ui.dwriteDrawText(scStatusText, fontsize, scStatusTextStart, scTextColor)

            if driverCar ~= safetyCar and sim.sessionTimeLeft < 0 then
                if driverCar == raceLeaderCar
                and (not rollingStart or (not conditionsMet or scCleared))
                or debug
                then
                    -- Leader only text
                    ui.dwriteDrawText(scLeaderText, helperFontsize, scLeaderTextStart, scLeaderTextColor)
                    scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 2)
                end
                if not (driverCar == raceLeaderCar and (scCleared or conditionsMet)) then
                    -- All driver helper text
                    ui.dwriteDrawText(scHelperText, helperFontsize, scHelperTextStart, scHelperTextColor)
                end
            end
        end

        if driverCar ~= safetyCar then
            if (rollingStart and conditionsMet)
            or (conditionsMet and driverCar == raceLeaderCar and not scCleared)
            or debug
            then
                ac.debug("SC Flags: Inside Rolling Start", scStatusText)
                local speedLimitSignSize = 40
                local speedLimitSignBorder = 12
                local speedLimitTotalWidth = speedLimitSignSize*2 + speedLimitSignBorder
                local speedSignXOffset = 250
                local speedSignYOffset = 25
                local speedLimitSignStart = vec2(speedLimitSignSize + speedLimitSignBorder / 2, speedLimitSignSize + speedLimitSignBorder / 2)
                speedLimitSignStart.x = speedLimitSignStart.x + flagWindowPos.x
                local speedLimitSignBoxSize = speedLimitSignStart * 2 + vec2(speedLimitSignBorder / 2, speedLimitSignBorder / 2)
                local speedLimitSignPosLeft = vec2(scFlagBoxCenter.x-speedSignXOffset-speedLimitTotalWidth/2, flagWindowPos.y + speedSignYOffset)
                local speedLimitSignPosRight = vec2(scFlagBoxCenter.x+speedSignXOffset-speedLimitTotalWidth/2, flagWindowPos.y + speedSignYOffset)
                local speedLimitFontSize = 32
                local speedLimitText = tostring(speedLimit)

                ui.beginTransparentWindow("SC Flags SpeedLimit Left", speedLimitSignPosLeft, speedLimitSignBoxSize, true, false)
                ui.drawCircle(speedLimitSignStart, speedLimitSignSize, rgbm(1, 0, 0, 1), 48, 12)
                ui.drawCircleFilled(speedLimitSignStart, speedLimitSignSize, rgbm(1, 1, 1, 1), 48)
                ui.dwriteTextAligned(speedLimitText, speedLimitFontSize, ui.Alignment.Center, ui.Alignment.Center, speedLimitSignBoxSize, false, rgbm(0, 0, 0, 1))
                ui.endTransparentWindow()

                ui.beginTransparentWindow("SC Flags SpeedLimit Right", speedLimitSignPosRight, speedLimitSignBoxSize, true, false)
                ui.drawCircle(speedLimitSignStart, speedLimitSignSize, rgbm(1, 0, 0, 1), 48, 12)
                ui.drawCircleFilled(speedLimitSignStart, speedLimitSignSize, rgbm(1, 1, 1, 1), 48)
                ui.dwriteTextAligned(speedLimitText, speedLimitFontSize, ui.Alignment.Center, ui.Alignment.Center, speedLimitSignBoxSize, false, rgbm(0, 0, 0, 1))
                ui.endTransparentWindow()

                -- ### SPEED INDICATOR ###
                --local carSpeed = math.floor(driverCar.speedKmh * 10) / 10
                local carSpeed = driverCarSpeed

                --local speedIndicatorPos = vec2(flagWindowPos.x, flagWindowPos.y+flagWindowSize.y+10)
                local speedIndicatorPos = vec2(flagWindowPos.x, flagWindowPos.y + speedSignYOffset)
                local speedIndicatorBarHeight = 26
                local speedIndicatorValueHeight = 32
                local speedIndicatorValueGap = 6
                local speedIndicatorValueYOffset = 63
                local speedIndicatorBoxSize = vec2(flagWindowSize.x, speedIndicatorBarHeight * 2 + speedIndicatorValueGap + speedIndicatorValueHeight) -- * number of rects
                ui.beginTransparentWindow("SC Flags Speed Indicator", speedIndicatorPos, speedIndicatorBoxSize, true, false)

                local speedIndicatorFontSize = 22
                local speedHelperFontSize = 18
                local speedRatio = speedIndicatorBoxSize.x / speedLimit
                local speedIndicatorValue = carSpeed * speedRatio
                --local speedIndicatorEnd = vec2(speedIndicatorValue, speedIndicatorBarHeight * 2 + speedIndicatorValueHeight)
                local speedIndicatorEnd = vec2(speedIndicatorValue, speedIndicatorBoxSize.y)
                local isOverLimit = carSpeed > speedLimit
                local speedToString = tostring(carSpeed)
                local rectColor = isOverLimit and rgbm(0.8, 0, 0, 1) or rgbm(0, 0.8, 0, 1)
                local speedHelperText = scLeaderTextState.watch
                if rollingStart then
                    speedHelperText = scRollingTextState.ending
                end

                ui.drawRectFilled( vec2(0, 0), vec2(speedIndicatorBoxSize.x, speedIndicatorBarHeight), rgbm(0.8, 0.8, 0, 1), 0, ui.CornerFlags.None )
                ui.dwriteTextAligned( speedHelperText, speedHelperFontSize, ui.Alignment.Center, ui.Alignment.End, vec2(ui.availableSpaceX(), speedIndicatorBarHeight-2), false, rgbm(0, 0, 0, 1))
                
                ui.drawRectFilled( vec2(0, speedIndicatorBarHeight), vec2(speedIndicatorBoxSize.x, speedIndicatorBarHeight*2), rgbm(0.15, 0.15, 0.3, 1), 0, ui.CornerFlags.None )
                ui.dwriteTextAligned( scRollingTextState.maintain, speedHelperFontSize-2, ui.Alignment.Center, ui.Alignment.End, vec2(ui.availableSpaceX(), speedIndicatorBarHeight-10), false, rgbm(0.7, 0.7, 0.7, 1))
                
                ui.drawRectFilled( vec2(0, speedIndicatorBarHeight*2 + speedIndicatorValueGap), speedIndicatorEnd, rectColor, 0, ui.CornerFlags.None )
                --ui.drawRectFilled( vec2(0, speedIndicatorBoxSize.y), vec2(speedIndicatorBoxSize.x, speedIndicatorBoxSize.y/2), rectColor, 0, ui.CornerFlags.None )
                ui.dwriteDrawText(speedToString, speedIndicatorFontSize, vec2(20, speedIndicatorValueYOffset), rgbm(0, 0, 0, 1))
                --ui.dwriteTextAligned( speedToString, speedIndicatorFontSize, ui.Alignment.Start, ui.Alignment.Center, vec2(60, speedIndicatorBoxSize.y/3), false, rgbm(0, 0, 0, 1))
                --ui.dwriteDrawText("KMH", speedIndicatorFontSize, vec2(64, 41), rgbm(0, 0, 0, 1))
                if isOverLimit or debug then
                    ui.dwriteDrawText("TOO FAST!", speedIndicatorFontSize, vec2(flagWindowSize.x/2+10, speedIndicatorValueYOffset), rgbm(0, 0, 0, 1))
                end
                ui.endTransparentWindow()
            end

            --TODO: unfinished
            -- Penalties Display
            --[[ local penaltyStartPos = vec2(flagWindowPos.x + 700, flagWindowPos.y)
            local penaltyBoxSize = vec2(300, 300)
            local penaltyFontSize = 16
            local lineSpacing = 15
            ui.pushDWriteFont("RealPenalty")
            ui.beginTransparentWindow("SC Flags Penalties", penaltyStartPos, penaltyBoxSize, true, false)
            for i, penaltyMessage in ipairs(rollingStartPenalties) do
                local posOffset = vec2(0, (i - 1) * lineSpacing) -- Calculate position for each line
                ui.dwriteDrawText(penaltyMessage, penaltyFontSize, posOffset, rgbm(1, 0, 0, 1)) -- Display penalty in red color
            end
            ui.endTransparentWindow() ]]
            -- Penalties Display End
        end
        
        ui.endTransparentWindow()
    end
end

function script.drawUI()
    uiFlags()
end

function script.update(dt)

    --accumulate total time
    timeAccumulator = timeAccumulator + dt
    ac.debug("Time Accumulator", timeAccumulator)

    ac.debug("SC Flags: 1-rollingStart", rollingStart)
    ac.debug("SC Flags: 3-conditionsMet", conditionsMet)
    ac.debug("SC Flags: 4-scOnTrack", scOnTrack)
    ac.debug("SC Flags: 5-scClear", scCleared)
    if driverCar then
        ac.debug("SC Flags: 6-driverCar", driverCar:driverName())
    end
    if raceLeaderCar then
        ac.debug("SC Flags: 7-leaderboard #1", raceLeaderCar:driverName())
    end
    if safetyCar then
        ac.debug("SC Flags: 8-safetyCar", safetyCar:driverName())
    end
    ac.debug("SC Flags: 9-showFlags", showFlags)
    ac.debug("SC Flags: flagWindowPos", flagWindowPos)
    ac.debug("SC Flags: directMessageAvailable", sim.directMessagingAvailable)
    

    --don't do anything for first 2 seconds
    if timeAccumulator < 2 then
        return
    end

    -- If the Safety Car is not present, return
    if not safetyCar then return end

    if scFlagsValues.settingsOpen then
        repositionFlags()
    end

    if showFlags or debug then        

        if timeAccumulator - checkStatesAccumulator >= checkStatesInterval then
            --repositionFlags()
            -- Check if all states exist; if not, re-initialize them
            if not sim or not currentSession or not driverCar or not safetyCar or not adminCar then
                getStates()
            end
            checkStatesAccumulator = timeAccumulator
        end

        if safetyCar.justJumped then
            writeLog("SC: Safety Car has just jumped")
            showFlags = false
        end
    
        --[[ ac.debug("SC FLags: Time Accumulator", timeAccumulator)
        ac.debug("SC FLags: showFlags", showFlags)
        ac.debug("SC FLags: goGreen", goGreen)
        ac.debug("SC FLags: scState", scStatusText)
        ac.debug("SC FLags: flagWindowPos", flagWindowPos)
        ac.debug("SC Flags: scStatusText", scStatusText) ]]

        if scOnTrack or conditionsMet then
            -- Determine the race leader
            if timeAccumulator - leaderCheckTime >= medCheckInterval then
                
                local index = 0
                local acReportedLeaderCar = ac.getCar.leaderboard(index)
                local fallbackCar = nil  -- will store the first non-safety-car we find

                while acReportedLeaderCar ~= nil do
                    if acReportedLeaderCar ~= safetyCar then
                        if fallbackCar == nil then
                            fallbackCar = acReportedLeaderCar
                        end
                        -- If it is not in the pit lane, then it’s our leader.
                        if not (acReportedLeaderCar.isInPit or acReportedLeaderCar.isInPitlane) then
                            break
                        end
                    end
                    -- Move on to the next car in the leaderboard.
                    index = index + 1
                    acReportedLeaderCar = ac.getCar.leaderboard(index)
                    
                end
                -- If we exited the loop with no valid leader (because acReportedLeaderCar is nil
                -- or every non-safety-car was in pit/pitlane), fall back to the first non-safety-car found.
                if acReportedLeaderCar == nil then
                    acReportedLeaderCar = fallbackCar
                end

                --first beat so we just have to trust it
                if raceLeaderCar == nil then
                    raceLeaderCar = acReportedLeaderCar
                    --writeLog("Race leader is: " .. raceLeaderCar:driverName())
                else
                    --not first beat, did leader car change last beat? 
                    if leaderChangedLastBeat == true then
                        --it did, and is it still reporting the same leader?
                        if prevRaceLeaderCar == acReportedLeaderCar then
                            --it is so all good, we can trust it
                            raceLeaderCar = acReportedLeaderCar
                            --writeLog("Race leader is: " .. raceLeaderCar:driverName())
                            leaderChangedLastBeat = false
                        else
                            --it changed again, we can't trust this
                            prevRaceLeaderCar = acReportedLeaderCar
                        end
                    else
                        --leader did not change last beat, has it changed this beat?
                        if acReportedLeaderCar ~= raceLeaderCar then
                            --it has, so store the current value for a beat
                            leaderChangedLastBeat = true
                            prevRaceLeaderCar = acReportedLeaderCar
                        end
                    end
                end
                leaderCheckTime = timeAccumulator
            end

            -- Check positions and helper text
            if timeAccumulator - erraticCheckAccumulator >= miniCheckInterval then
                detectErraticAndPos(dt)
                --ac.debug("SC Flags: Erratic Running", erraticCheckAccumulator)
                erraticCheckAccumulator = timeAccumulator
            end
        end
        
        if scCleared and scOnTrack then
            writeLog("SC: Status - Entering Pit")
            scHelperText = scHelperTextState.noOvertake
            if timeAccumulator - timeToDisplayTextAccumulator >= timeToDisplaySCText then
                scStatusText = scState.off
                flagColor = rgbm(0.3, 0.3, 0.3, 1)
                scTextColor = rgbm(1, 0.27, 0.02, 1)
                scOnTrack = false
                writeLog("SC: Status - Get Ready")
                timeToDisplayTextAccumulator = timeAccumulator
            end
        end

        -- Show flags for 5 seconds
        if goGreen then
            if timeAccumulator - timeToDisplayGreenAccumulator >= timeToDisplayGreen then
                showFlags = false
                scOnTrack = false
                goGreen = false
                scCleared = false
                writeLog("SC: Gone green - Flags off")
                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end
        --[[ 
        --######################
        -- Go green individually
        if getCarLapCounts then
            carLapCounts[driverCar.index] = driverCar.lapCount or 0
            writeLog("Got lap count: " .. driverCar.lapCount)
            getCarLapCounts = false
            checkGoGreen = true
        end

        if checkGoGreen then
            if driverCar.lapCount > (carLapCounts[driverCar.index] or 0) then
                writeLog("SC: Driver Car ID: " .. driverCar:driverName() .. " crossed start finish")
                flagColor = rgbm(0, 225, 0, 1)
                scHeadingTextColor = rgbm(0, 225, 0, 1)
                scHeadingText = scHeadingTextState.green
                scStatusText = scState.off
                scLeaderText = scLeaderTextState.off

                showFlags = true
                goGreen = true
                checkGoGreen = false

                audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)
                audioSCGoGreenEvent.volume = 5
                audioSCGoGreenEvent:start()

                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end
        -- Go green individually end
        --######################
        ]]

        
        --######################
        -- Go green same time
        if getCarLapCounts then
            for i, car in ac.iterateCars.leaderboard() do
                -- Edge case - ignore straglers who might be behind Start Finish but ahead of SC when it clears
                -- TODO: Not sure about this
                if car.splinePosition > safetyCar.splinePosition then
                    carLapCounts[car.index] = 9999
                else
                    carLapCounts[car.index] = car.lapCount or 0
                end
                writeLog("SC: Car ID: " .. car.index .. " on lap " .. car.lapCount)
            end
            --checkGoGreen = true
            getCarLapCounts = false
        end

        if checkGoGreen then
            if raceLeaderCar ~=nil and raceLeaderCar.lapCount > carLapCounts[raceLeaderCar.index] then
                writeLog("SC: Leader Car ID: " .. raceLeaderCar:driverName() .. " crossed start finish")
                flagColor = rgbm(0,225,0,1)
                scHeadingTextColor = rgbm(0,225,0,1)
                scHeadingText = scHeadingTextState.green
                scStatusText = scState.off
                scLeaderText = scLeaderTextState.off
                scHelperText = scHelperTextState.off

                if rollingStart then
                    -- Penalize speeding
                    --TODO: Add UI text element
                    local penalty = 0
                    if driverCarSpeed > 160 then penalty = 180
                    elseif driverCarSpeed > 140 then penalty = 60
                    elseif driverCarSpeed > 120 then penalty = 45
                    elseif driverCarSpeed > 110 then penalty = 15
                    elseif driverCarSpeed > 102 then penalty = 5
                    end
                    if penalty > 0 then
                        ac.sendChatMessage("SC: INFO | " .. driverCar:driverName() .. " - PENALTY " .. penalty .. "s")
                        writeLog("SC: INFO | " .. driverCar:driverName() .. " - PENALTY " .. penalty .. "s")
                    end
                end

                audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)
                audioSCGoGreenEvent.volume = 5
                audioSCGoGreenEvent:start()

                showFlags = true
                goGreen = true
                checkGoGreen = false
                rollingStart = false
                conditionsMet = false

                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end
        -- Go green same time end
        --######################
    end
end

ac.onSessionStart(function(sessionIndex, restarted)
    initializeSCFlagScript()
    --setConditionsLateJoin()
    currentSession = ac.getSession(sessionIndex)
end)

function script.reset()
    initializeSCFlagScript()
    writeLog("SC: Flag Script Reset")
end

--ac.onRelease(initializeSCFlagScript)
ac.onRelease(function()
    initializeSCFlagScript()
    writeLog("SC: Flag Script Released/Reload")
end)

initializeSCFlagScript()
--setConditionsLateJoin()
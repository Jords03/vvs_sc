-- Get states
local sim = ac.getSim()
local currentSession = ac.getSession(sim.currentSessionIndex)
local driverCar = ac.getCar(0)
--XXX
local safetyCarName = "Safety Car"
--local safetyCarName = "VVS SafetyCar"
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
    off = ""
}

local scLeaderTextState = {
    leader = "YOU ARE RACE LEADER",
    maintain = "MAINTAIN YOUR SPEED",
    goAnyTime = "GO AT ANY TIME",
    off = ""
}

local scHelperTextState = {
    catchSC = "CATCH THE SAFETY CAR",
    catchPack = "CATCH THE PACK",
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
local scEnterPits = false
local headingToPits = false
local getCarLapCounts = false
local checkGoGreen = false
local carLapCounts = {}
local raceLeaderCar = nil
local prevRaceLeaderCar = nil
local leaderChangedLastBeat = false

-- Text variables
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

-- Time variables
local timeAccumulator = 0
local checkStatesAccumulator = 0
local erraticCheckAccumulator = 0
local timeToDisplayTextAccumulator = 0
local timeToDisplayGreenAccumulator = 0
local leaderCheckTime = 0

local miniCheckInterval = 0.1
local medCheckInterval = 0.3
local checkStatesInterval = 60
local timeToDisplaySCText = 2
local timeToDisplayGreen = 5
local erraticTimer = 0
local erraticDisplayDuration = 2

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
local defaultFlagWindowPosY = (sim.windowHeight/8) - (flagWindowSize.y/2)
--[[ 
local flagWindowPosX = ac.load("SCFlagsWindowPosX")
local flagWindowPosY = ac.load("SCFlagsWindowPosY")
 ]]

-- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
local previousDriverCarState = nil
local previousHelperTextState = nil
local previousMinus1HelpertextState = nil
local distanceThreshold = 28
local distanceEndingThreshold = 250



-- Combined threshold values for detecting erratic behavior
local erraticThresholds = {
    suddenSpeedChange = 5,    -- km/h
    suddenSteer = 20,         -- degrees
    highAngularVelocity = 0.85   -- rad/s, for swerving detection
}

local function reInitailizeVars ()
    -- Initialize variables
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    scOnTrack = false
    scEnterPits = false
    headingToPits = false
    getCarLapCounts = false
    checkGoGreen = false
    carLapCounts = {}
    raceLeaderCar = nil
    prevRaceLeaderCar = nil
    leaderChangedLastBeat = false

    -- Text variables
    headFontSize = 22
    fontsize = 28
    helperFontsize = 16
    scHeadingText = scHeadingTextState.sc
    scHeadingTextBG = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.white
    scHelperTextColor = rgbm.colors.red
    scLeaderTextColor = rgbm.colors.orange
    scStatusText = ""
    scLeaderText = ""
    scHelperText = ""

    --- Time variables
    timeAccumulator = 0
    checkStatesAccumulator = 0
    erraticCheckAccumulator = 0
    timeToDisplayTextAccumulator = 0
    timeToDisplayGreenAccumulator = 0
    checkStatesInterval = 60
    timeToDisplaySCText = 2
    timeToDisplayGreen = 6
    erraticTimer = 0
    erraticDisplayDuration = 2
    leaderCheckTime = 0

    -- Window variables
    flagWindowSize = vec2(300, 180)
    defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
    defaultFlagWindowPosY = (sim.windowHeight/8) - (flagWindowSize.y/2)
    --flagWindowPosX = ac.load("SCFlagsWindowPosX")
    --flagWindowPosY = ac.load("SCFlagsWindowPosY")
    flagWindowPos = scFlagsValues.posVec2 or vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
    scFlagSettings = scFlagsValues.settingsOpen

    -- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
    previousDriverCarState = nil
    previousHelperTextState = nil
    previousMinus1HelpertextState = nil
    distanceThreshold = 28

end

--[[ if not (flagWindowPosX and flagWindowPosY) then
    flagWindowPos = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
end 
if scFlagsValues.posVec2 ~= nil then
    ac.log("PosVector is " .. scFlagsValues.posVec2.x .. "|" .. scFlagsValues.posVec2.y )
end
if scFlagsValues.posVec2 == nil or vec2(0,0) then
    scFlagsValues.posVec2 = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
end
]]

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message) -- Also log to the default writeLog
end


local function repositionFlags()
    --[[ flagWindowPosX = ac.load("SCFlagsWindowPosX")
    flagWindowPosY = ac.load("SCFlagsWindowPosY")
    flagWindowPos = vec2(tonumber(flagWindowPosX), tonumber(flagWindowPosY)) ]]
    flagWindowPos = scFlagsValues.posVec2
end

local function initializeSCFlagScript()
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    getStates()
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
web.loadRemoteAssets("https://raw.githubusercontent.com/Jords03/vvs_sc/main/sc_wav_files_01.zip", logAudioCallback)

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    if not safetyCar then
        getStates()
    end

    if string.startsWith(message, "SC:") and (senderCarIndex == safetyCar.index or senderCarIndex == adminCar.index) then
        writeLog("SC: chatmsg: " .. message)

        if message == "SC: Safety Car rolling start" then
            writeLog("SC: Recieved - Safety Car rolling start")
            --[[ 
            flagColor = rgbm.colors.yellow
            scTextColor = rgbm.colors.black
            scHeadingTextColor = rgbm.colors.yellow
            scStatusText = scState.deployed
            scHeadingText = scHeadingTextState.sc
            --scLeaderText = scLeaderTextState.leader
            headingToPits = false
            showFlags = true
            goGreen = false
            scOnTrack = true
            audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
            audioSCDeployedEvent.volume = 5
            audioSCDeployedEvent:start() 
            ]]
        elseif message == "SC: Safety Car deployed" then
            writeLog("SC: Recieved - Safety Car deployed")
            flagColor = rgbm.colors.yellow
            scTextColor = rgbm.colors.black
            scHeadingTextColor = rgbm.colors.yellow
            scStatusText = scState.deployed
            scHeadingText = scHeadingTextState.sc
            --scLeaderText = scLeaderTextState.leader
            headingToPits = false
            showFlags = true
            goGreen = false
            scOnTrack = true
            audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
            audioSCDeployedEvent.volume = 5
            audioSCDeployedEvent:start()
        elseif message == "SC: Safety Car in this lap" then
            writeLog("SC: Recieved - Safety Car in this lap")
            flagColor = rgbm(0.6, 0.6, 0, 1)
            scStatusText = scState.returning
            scTextColor = rgbm.colors.black
            scLeaderText = scLeaderTextState.maintain
            headingToPits = true
            showFlags = true
            goGreen = false
            scOnTrack = true
            audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
            audioSCInThisLapEvent.volume = 5
            audioSCInThisLapEvent:start()
            timeToDisplayTextAccumulator = timeAccumulator
        elseif message == "SC: Safety Car is clear" then
            writeLog("SC: Recieved - Safety Car is clear")
            flagColor = rgbm(0.4, 0.4, 0.4, 1)
            scStatusText = scState.enteringPit
            scTextColor = rgbm.colors.yellow
            scLeaderText = scLeaderTextState.goAnyTime
            showFlags = true
            scEnterPits = true
            scOnTrack = false
            goGreen = false
            getCarLapCounts = true
            --checkGoGreen = true
            audioSCClearEvent = ac.AudioEvent.fromFile(scClearAudio, false)
            audioSCClearEvent.volume = 5
            audioSCClearEvent:start()
            timeToDisplayTextAccumulator = timeAccumulator
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
        end
    end
    return true
end)

--XXX
--[[ 
local btnSCOn = ac.ControlButton('app.sc_flags/scon', ui.KeyIndex.A)
btnSCOn:onPressed(function()
    writeLog("SC: Recieved - Safety Car deployed")
    flagColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scStatusText = scState.deployed
    scHeadingText = scHeadingTextState.sc
    --scLeaderText = scLeaderTextState.leader
    headingToPits = false
    showFlags = true
    goGreen = false
    scOnTrack = true
    audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
    audioSCDeployedEvent.volume = 5
    audioSCDeployedEvent:start()
end)

local btnSCPits = ac.ControlButton('app.sc_flags/scpits', ui.KeyIndex.S)
btnSCPits:onPressed(function()
    writeLog("SC: Recieved - Safety Car in this lap")
    flagColor = rgbm(0.6, 0.6, 0, 1)
    scStatusText = scState.returning
    scTextColor = rgbm.colors.black
    scLeaderText = scLeaderTextState.maintain
    headingToPits = true
    showFlags = true
    goGreen = false
    scOnTrack = true
    audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
    audioSCInThisLapEvent.volume = 5
    audioSCInThisLapEvent:start()
    timeToDisplayTextAccumulator = timeAccumulator
end)

local btnSCOff = ac.ControlButton('app.sc_flags/scoff', ui.KeyIndex.D)
btnSCOff:onPressed(function()
    writeLog("SC: Recieved - Safety Car is clear")
    flagColor = rgbm(0.4, 0.4, 0.4, 1)
    scStatusText = scState.enteringPit
    scTextColor = rgbm.colors.yellow
    scLeaderText = scLeaderTextState.goAnyTime
    showFlags = true
    scEnterPits = true
    scOnTrack = false
    goGreen = false
    getCarLapCounts = true
    --checkGoGreen = true
    audioSCClearEvent = ac.AudioEvent.fromFile(scClearAudio, false)
    audioSCClearEvent.volume = 5
    audioSCClearEvent:start()
    timeToDisplayTextAccumulator = timeAccumulator
end)
 ]]

-- Calculate the normalized distance behind the safety car
local function calculateDistanceBehind(carPosition, otherPosition)
    if carPosition > otherPosition then
        otherPosition = otherPosition + 1
    end
    return otherPosition - carPosition  -- Always a value between 0 and 1
end

-- Function to detect erratic driving behavior and check distance
local function detectErraticAndPos(dt)

    local car = driverCar
    if not car then return end

    local carAhead = nil
    local tooFar = false
    local catchSC = false
    local passSafetyCar = false
    local distanceToSC = 0
    local carDistance = 0

    -- Calculate the distance behind the safety car
    local distanceBehindSC = calculateDistanceBehind(car.splinePosition, safetyCar.splinePosition)
    distanceToSC = distanceBehindSC * trackLength --for debugging only

    -- Find the next car ahead on track
    local minDistanceAhead = 1  -- Initialize with maximum possible spline position difference
    for i, otherCar in ac.iterateCars.ordered() do
        if otherCar ~= safetyCar and otherCar ~= car and otherCar.isConnected and not (otherCar.isInPitlane or otherCar.isInPit) then
            local distanceAhead = calculateDistanceBehind(car.splinePosition, otherCar.splinePosition)
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
        local distanceBehindLeader = calculateDistanceBehind(car.splinePosition, raceLeaderCar.splinePosition)
        local betweenLeaderAndSafetyCar = (distanceBehindLeader >= distanceBehindSC)
        if betweenLeaderAndSafetyCar then
            passSafetyCar = true
            --writeLog("Bewtween leader and safety car")
        end
    end
    -- Calculate the distance to the car ahead
    if carAhead then
        carDistance = minDistanceAhead * trackLength
        ac.debug("SC Flags: minDistanceAhead", minDistanceAhead)
        tooFar = carDistance > distanceThreshold
        
        if (carDistance > (distanceThreshold * 2.5)) then
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
        
        if passSafetyCar then
            newHelperTextState = scHelperTextState.passSafetyCar
        elseif catchSC and scStatusText ~= scState.returning then
            if car == raceLeaderCar then
                scLeaderText = scLeaderTextState.leader
                newHelperTextState = scHelperTextState.catchSC .. " - " .. math.floor(carDistance) .. "m"
            else
                newHelperTextState = scHelperTextState.catchPack .. " - " .. math.floor(carDistance) .. "m"
            end
        elseif erraticActive then  -- Use the timer-controlled state instead of direct isErratic
            newHelperTextState = scHelperTextState.erratic
        elseif tooFar then
            newHelperTextState = scHelperTextState.closeGap .. " - " .. math.floor(carDistance) .. "m"
        end

        if newHelperTextState ~= previousHelperTextState then
            --writeLog("state change")
            if car == raceLeaderCar and scStatusText == scState.returning then
                scLeaderText = scLeaderTextState.maintain
                scHelperText = math.floor(car.speedKmh) .. " km/h"
                previousHelperTextState = newHelperTextState
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

        -- Debugging output
        ac.debug("SC Flags: newHelperTextState", newHelperTextState)
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
        ac.debug("SC Flags: showFlags", showFlags)
    else
        ac.debug("SC Flags: prevState", false)
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
    if showFlags or scFlagsValues.settingsOpen then
        
        ui.beginTransparentWindow("SC Flags", flagWindowPos, flagWindowSize, true, false)

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
        ui.drawRectFilled(scHeadingTextBoxStart, scHeadingTextBoxEnd, scHeadingTextBG, 5, ui.CornerFlags.Top)
        ui.dwriteDrawText(scHeadingText, headFontSize, scHeadingTextStart, scHeadingTextColor)

        ui.drawRectFilled(scFlagBoxStart, scFlagBoxEnd, flagColor, 5, ui.CornerFlags.Bottom)
        ui.dwriteDrawText(scStatusText, fontsize, scStatusTextStart, scTextColor)
        
        if driverCar ~= safetyCar then
            if raceLeaderCar then
                if driverCar == raceLeaderCar then
                    ui.dwriteDrawText(scLeaderText, helperFontsize, scLeaderTextStart, scLeaderTextColor)
                    scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 2)
                end
            elseif scFlagSettings then
                ui.dwriteDrawText(scLeaderText, helperFontsize, scLeaderTextStart, scLeaderTextColor)
                scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 2)
            end
            ui.dwriteDrawText(scHelperText, helperFontsize, scHelperTextStart, scHelperTextColor)
        end
        ui.endTransparentWindow()

        if scStatusText == scState.returning then
            local speedLimitSignSize = 40
            local speedLimitSignBorder = 12
            local speedSignXOffset = 125
            local speedLimitSignStart = vec2(speedLimitSignSize + speedLimitSignBorder / 2, speedLimitSignSize + speedLimitSignBorder / 2)
            local speedLimitSignBoxSize = speedLimitSignStart * 2 + vec2(speedLimitSignBorder / 2, speedLimitSignBorder / 2)
            local speedLimitSignPosLeft = vec2(ui.windowPos().x - speedSignXOffset, ui.windowPos().y + scFlagBoxCenter.y - speedLimitSignSize)
            local speedLimitSignPosRight = vec2(ui.windowPos().x + ui.availableSpaceX() + speedSignXOffset - speedLimitSignStart.x*2, ui.windowPos().y + scFlagBoxCenter.y - speedLimitSignSize)
            local speedLimit = "100"
            local speedLimitFontSize = 32

            ui.beginTransparentWindow("SC Flags SpeedLimit Left", speedLimitSignPosLeft, speedLimitSignBoxSize, true, false)
            ui.drawCircle(speedLimitSignStart, speedLimitSignSize, rgbm(1, 0, 0, 1), 48, 12)
            ui.drawCircleFilled(speedLimitSignStart, speedLimitSignSize, rgbm(1, 1, 1, 1), 48)
            ui.dwriteTextAligned(speedLimit, speedLimitFontSize, ui.Alignment.Center, ui.Alignment.Center, speedLimitSignBoxSize, false, rgbm(0, 0, 0, 1))
            ui.endTransparentWindow()

            ui.beginTransparentWindow("SC Flags SpeedLimit Right", speedLimitSignPosRight, speedLimitSignBoxSize, true, false)
            ui.drawCircle(speedLimitSignStart, speedLimitSignSize, rgbm(1, 0, 0, 1), 48, 12)
            ui.drawCircleFilled(speedLimitSignStart, speedLimitSignSize, rgbm(1, 1, 1, 1), 48)
            ui.dwriteTextAligned(speedLimit, speedLimitFontSize, ui.Alignment.Center, ui.Alignment.Center, speedLimitSignBoxSize, false, rgbm(0, 0, 0, 1))
            ui.endTransparentWindow()
        end
    end
end

function script.drawUI()
    uiFlags()
end

function script.update(dt)

    --accumulate total time
    timeAccumulator = timeAccumulator + dt
    ac.debug("Time Accumulator", timeAccumulator)

    --don't do anything for first 2 seconds
    if timeAccumulator < 2 then
        return
    end

    -- If the Safety Car is not present, return
    if not safetyCar then return end

    if scFlagsValues.settingsOpen then
        repositionFlags()
    end

    if showFlags then

        ac.debug("SC Flags: scOnTrack", scOnTrack)

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
        
        if driverCar then
            ac.debug("SC Flags: driverCar", driverCar:driverName())
        end
        if raceLeaderCar then
            ac.debug("SC Flags: leaderboard #1", raceLeaderCar:driverName())
        end
        
        ac.debug("SC FLags: Time Accumulator", timeAccumulator)
        ac.debug("SC FLags: showFlags", showFlags)
        ac.debug("SC FLags: goGreen", goGreen)
        ac.debug("SC FLags: scState", scStatusText)
        ac.debug("SC FLags: flagWindowPos", flagWindowPos)
        ac.debug("SC Flags: scStatusText", scStatusText)


        if scOnTrack then
            -- Determine the race leader
            if timeAccumulator - leaderCheckTime >= medCheckInterval then
                
                -- TODO: Check performance of this while loop
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

                --[[ 
                local acReportedLeaderCar = ac.getCar.leaderboard(0)
                if acReportedLeaderCar == safetyCar then
                    acReportedLeaderCar = ac.getCar.leaderboard(1)
                end 
                ]]
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

            if timeAccumulator - erraticCheckAccumulator >= miniCheckInterval then
                detectErraticAndPos(dt)
                ac.debug("SC Flags: Erratic Running", erraticCheckAccumulator)
                erraticCheckAccumulator = timeAccumulator
            end
        end
        
        if scEnterPits then
            scHelperText = scHelperTextState.off
            if timeAccumulator - timeToDisplayTextAccumulator >= timeToDisplaySCText then
                scStatusText = scState.off
                flagColor = rgbm(0.3, 0.3, 0.3, 1)
                scTextColor = rgbm(1, 0.27, 0.02, 1)
                scEnterPits = false
                scOnTrack = false
                writeLog("SC: Status - Get Ready")
                timeToDisplayTextAccumulator = timeAccumulator
            end
        end

        if goGreen then
            if timeAccumulator - timeToDisplayGreenAccumulator >= timeToDisplayGreen then
                showFlags = false
                scOnTrack = false
                goGreen = false
                writeLog("SC: Gone green - Flags off")
                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end
        
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

        --[[ 
        --######################
        -- Go green same time
        if getCarLapCounts then
            for i, car in ac.iterateCars.leaderboard() do
                if car.splinePosition > safetyCar.splinePosition then
                    carLapCounts[car.index] = 9999
                else
                    carLapCounts[car.index] = car.lapCount or 0
                end
                writeLog("SC: Car ID: " .. car.index .. " on lap " .. car.lapCount)
            end
            checkGoGreen = true
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

                showFlags = true
                goGreen = true
                
                audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)
                audioSCGoGreenEvent.volume = 5
                audioSCGoGreenEvent:start()

                checkGoGreen = false
                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end
        -- Go green same time end
        --######################
        ]]
    end
end

ac.onSessionStart(function(sessionIndex, restarted)
    reInitailizeVars()
    initializeSCFlagScript()
    currentSession = ac.getSession(sessionIndex)
    writeLog("SC: Flag Script Initialized on Session Start")
end)

ac.onRelease(initializeSCFlagScript)

reInitailizeVars()
initializeSCFlagScript()
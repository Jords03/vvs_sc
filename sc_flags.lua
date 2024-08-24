-- Get states
local sim = ac.getSim()
local driverCar = ac.stateCar
local safetyCarID = ac.getCarByDriverName("Safety Car")
local safetyCar = ac.getCar(safetyCarID)
local adminCar
local currentSession = ac.getSession(sim.currentSessionIndex)
local trackLength = sim.trackLengthM

local function getStates()
    sim = ac.getSim()
    safetyCarID = ac.getCarByDriverName("Safety Car")
    safetyCar = ac.getCar(safetyCarID)
    if ac.getCarByDriverName("Jon Astrop") then
        local adminCarID = ac.getCarByDriverName("Jon Astrop")
        adminCar = ac.getCar(adminCarID)
    end
end

getStates()

-- Safety Car state variables
local scState = {
    deployed = "DEPLOYED",
    returning = "ENDING",
    enteringPit = "ENTERING PIT",
    inPit = "IN PIBOX",
    getReady = "GET READY",
    off = "",
    settings = "SETTINGS"
}

local scHeadingTextState = {
    sc = "SAFETY CAR",
    green = "GREEN FLAG"
}

local scLeaderTextState = {
    leader = "YOU LEAD - CAUTION",
    maintain = "MAINTAIN 120 KMH",
    getReady = "GO AT ANY TIME",
    off = ""
}

local scHelperTextState = {
    catchPack = "CATCH THE PACK",
    closeGap = "TOO FAR - CLOSE GAP",
    erratic = "DON'T DRIVE ERRATICALLY",
    off = ""
}

-- Initialize variables
local flagColor = rgbm.colors.gray
local showFlags = false
local goGreen = false
local getCarLapCounts = false
local checkGoGreen = false
local carLapCounts = {}
local prevSCState = ""
local raceLeader = nil

-- Text variables
local headFontSize = 22
local fontsize = 28
local scHeadingText = scHeadingTextState.sc
local scHeadingTextBG = rgbm.colors.black
local scHeadingTextColor = rgbm.colors.yellow
local scTextColor = rgbm.colors.white
local scHelperTextColor = rgbm.colors.yellow
local scStatusText = ""
local scLeaderText = ""
local scHelperText = ""

-- Time variables
local timeAccumulator = 0
local scInTimeAccumulator = 0
local scInCheckInterval = 0.5 -- seconds
local timeToDisplayTextAccumulator = 0
local timeToDisplaySCText = 5
local timeToDisplayGreenAccumulator = 0
local timeToDisplayGreen = 10
local lapcount = 0

-- Audio variables
local scGoGreenAudio
local scInThisLapAudio
local scDeployedAudio
local audioSCGoGreenEvent
local audioSCInThisLapEvent
local audioSCDeployedEvent
local audioLoaded = false

-- Window variables
local flagWindowPos
local flagWindowSize = vec2(300, 180)
local defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
local defaultFlagWindowPosY = (sim.windowHeight/8) - (flagWindowSize.y/2)
local flagWindowPosX = ac.load("SCFlagsWindowPosX")
local flagWindowPosY = ac.load("SCFlagsWindowPosY")

-- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
local previousDriverCarState = nil
local previousHelperTextState = nil
local distanceThreshold = 30

-- Combined threshold values for detecting erratic behavior
local erraticThresholds = {
    suddenAcceleration = 10,  -- m/s^2
    suddenBrake = -10,        -- m/s^2 (negative for braking)
    suddenSteer = 15,         -- degrees
    highAngularVelocity = 1   -- rad/s, for swerving detection
}

if flagWindowPosX and flagWindowPosY then
    flagWindowPos = vec2(flagWindowPosX - (flagWindowSize.x/2), flagWindowPosY - (flagWindowSize.y/2))
else
    flagWindowPos = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
end

local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. message) -- Also log to the default writeLog
end

local function repositionFlags()
    flagWindowPosX = ac.load("SCFlagsWindowPosX") - (flagWindowSize.x/2)
    flagWindowPosY = ac.load("SCFlagsWindowPosY") - (flagWindowSize.y/2)
    flagWindowPos = vec2(flagWindowPosX, flagWindowPosY)

    ac.debug("scFlagsSettingsOpen", ac.load("scFlagsSettingsOpen"))
    scStatusText = scState.settings
end

local function initializeSCFlagScript()
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    getStates()
end


-- Define the callback function
local function logAudioCallback(err, folder)
    
    scDeployedAudio = folder .. "/safety_car.wav"
    scInThisLapAudio = folder .. "/safety_car_this_lap.wav"
    scGoGreenAudio = folder .. "/safety_car_this_lap.wav"    

    scDeployedAudio = {
        --filename = 'extension/lua/online/AC_RP_SafetyCar/safety_car.wav',
        filename = scDeployAudio,
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
        --filename = 'extension/lua/online/AC_RP_SafetyCar/safety_car_this_lap.wav',     -- Audio filename
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

    scGoGreenAudio = {
        --filename = 'extension/lua/online/AC_RP_SafetyCar/safety_car_green_flag.wav',
        filename = scDeployedAudio,
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
    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)

    writeLog("SC: audioSCDeployedEvent Vol: " .. audioSCInThisLapEvent.volume)
    writeLog("SC: audioSCInThisLapEvent Vol: " .. audioSCInThisLapEvent.volume)
    writeLog("SC: audioSCGoGreenEvent Vol: " .. audioSCGoGreenEvent.volume)

    audioLoaded = true
end

-- Call web.loadRemoteAssets with the URL and the logging callback
web.loadRemoteAssets("https://github.com/Jords03/vvs_sc/raw/main/sc_wav_files.zip", logAudioCallback)

ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    if not safetyCar then
        getStates()
    end

    if string.startsWith(message, "SC:") and (senderCarIndex == safetyCar.index or senderCarIndex == adminCar.index) then
        writeLog("SC: chatmsg: " .. message)

        if message == "SC: Safety Car has left pits" then
            writeLog("SC: Recieved - Safety Car has left pits")
            flagColor = rgbm.colors.yellow
            scTextColor = rgbm.colors.black
            scHeadingTextColor = rgbm.colors.yellow
            scStatusText = scState.deployed
            scHeadingText = scHeadingTextState.sc
            showFlags = true
            goGreen = false
            audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
            audioSCDeployedEvent.volume = 15
            audioSCDeployedEvent:start()
        elseif message == "SC: Safety Car is heading to pits" then
            writeLog("SC: Recieved - Safety Car is heading to pits")
            flagColor = rgbm(0.6, 0.6, 0, 1)
            scStatusText = scState.returning
            scTextColor = rgbm.colors.black
            scLeaderText = scLeaderTextState.maintain
            showFlags = true
            goGreen = false
            audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
            audioSCInThisLapEvent.volume = 15
            audioSCInThisLapEvent:start()
            timeToDisplayTextAccumulator = timeAccumulator
        elseif message == "SC: Safety Car is entering pit lane" then
            writeLog("SC: Recieved - Safety Car is entering pit lane")
            flagColor = rgbm(0.4, 0.4, 0.4, 1)
            scStatusText = scState.enteringPit
            scTextColor = rgbm.colors.yellow
            scLeaderText = scLeaderTextState.getReady
            showFlags = true
            goGreen = false
            getCarLapCounts = true
            timeToDisplayTextAccumulator = timeAccumulator
        elseif message == "SC: Safety Car has reset in pits" then
            writeLog("SC: Recieved - Safety Car has reset in pits")
            --flagColor = rgbm.colors.gray
            --showFlags = true
            --UNUSED
        elseif string.startsWith(message, "SC: Go Green") then
            writeLog("SC: Recieved - Go Green")
            -- Unused -> we track leader on client side for accuracy
        elseif message == "SC: Kill Switch" then
            initializeSCFlagScript()
        end
    end
    return true
end)

-- Function to detect erratic driving behavior and check distance
local function detectErraticAndPos()
    local car = driverCar

    if car and not car.isInPitlane and not car.isInPit then
        local carRacePos = car.racePosition
        local carAhead = nil
        local carDistance = nil
        local tooFar = false

        if carRacePos == 1 then
            carAhead = safetyCar
        else
            for i, otherCar in ac.iterateCars.ordered() do
                if otherCar.racePosition == carRacePos - 1 then
                    carAhead = otherCar
                    break
                end
            end
        end

        if carAhead then
            carDistance = (car.splinePosition - carAhead.splinePosition) * trackLength
            if carDistance < 0 then
                carDistance = carDistance + trackLength
            end
            tooFar = carDistance > distanceThreshold
        end
        
        if previousDriverCarState then
            local accelChange = car.acceleration.z - previousDriverCarState.acceleration.z
            local steerChange = math.abs(car.steer - previousDriverCarState.steer)
            local angularVelocityChange = math.abs(car.angularVelocity.y)

            local isErratic = (
                accelChange > erraticThresholds.suddenAcceleration or
                accelChange < erraticThresholds.suddenBrake or
                steerChange > erraticThresholds.suddenSteer or
                angularVelocityChange > erraticThresholds.highAngularVelocity
            )

            local newHelperTextState = scHelperTextState.off
            if isErratic then
                newHelperTextState = scHelperTextState.eratic
            elseif tooFar then
                newHelperTextState = scHelperTextState.closeGap
            end

            if newHelperTextState ~= previousHelperTextState then
                scHelperText = newHelperTextState
                previousHelperTextState = newHelperTextState
            end
        end

        previousDriverCarState = {
            acceleration = car.acceleration,
            steer = car.steer,
            angularVelocity = car.angularVelocity
        }
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

local function textSize(text_size, fontsize)
    local calcTextSize = ui.measureDWriteText(text_size, fontsize)
    return calcTextSize
end

local function uiFlags(dt)
    if showFlags or ac.load("scFlagsSettingsOpen") == 1 then

        if ac.load("scFlagsSettingsOpen") == 1 then
            repositionFlags()
        end
        
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
        local scHelperTextCenter = vec2(ui.availableSpaceX()/2, (sectionGridAvailableSpaceY*3)+(sectionGridAvailableSpaceY/2))

        local scHeadingTextSize = textSize(scHeadingText, headFontSize)
        local scStatusTextSize = textSize(scStatusText, fontsize)
        local scLeaderTextSize = textSize(scLeaderText, fontsize)
        local scHelperTextSize = textSize(scHelperText, fontsize)

        local scHeadingTextStart = scHeadingRectCenter - (scHeadingTextSize / 2)
        local scStatusTextStart = scFlagBoxCenter - (scStatusTextSize / 2)
        local scLeaderTextStart = scHelperTextCenter - (scLeaderTextSize / 2)
        local scHelperTextStart = scHelperTextCenter - (scHelperTextSize / 2)

        ui.pushDWriteFont("RealPenalty")
        ui.drawRectFilled(vec2(scHeadingTextBoxStart), vec2(scHeadingTextBoxEnd), scHeadingTextBG, 5,
            ui.CornerFlags.Top)
        ui.dwriteDrawText(scHeadingText, headFontSize, scHeadingTextStart, scHeadingTextColor)

        ui.drawRectFilled(vec2(scFlagBoxStart), vec2(scFlagBoxEnd), flagColor, 5, ui.CornerFlags.Bottom)
        ui.dwriteDrawText(scStatusText, fontsize, scStatusTextStart, scTextColor)

        if driverCar == ac.getCar.leaderboard(0) then
            ui.dwriteDrawText(scLeaderText, fontsize, scLeaderTextStart, scHelperTextColor)
            scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 5)
        end
        
        ui.dwriteDrawText(scHelperText, fontsize, scHelperTextStart, scHelperTextColor)

        ui.endTransparentWindow()

    end
end

function script.drawUI()
    uiFlags()
end


function script.update(dt)
    timeAccumulator = timeAccumulator + dt

    --[[
    ac.debug("SC FLags: Time Accumulator", timeAccumulator)
    ac.debug("SC FLags: showFlags", showFlags)
    ac.debug("SC FLags: goGreen", goGreen)
    ac.debug("SC FLags: scState", scStatusText)
    ac.debug("SC FLags: flagWindowPos", flagWindowPos)
    ]]

    if showFlags then

        if isNearSC(driverCar.splinePosition, safetyCar.splinePosition, (distanceThreshold * driverCar.racePosition)) then
            detectErraticAndPos()
        end

        if scStatusText == scState.enteringPit then
            if timeAccumulator - timeToDisplayTextAccumulator >= timeToDisplaySCText then
                scStatusText = scState.getReady
                scLeaderText = scLeaderTextState.getReady
                flagColor = rgbm(0.3, 0.3, 0.3, 1)
                scTextColor = rgbm(1, 0.27, 0.02, 1)
                writeLog("SC: Status - Get Ready")
            end
            timeToDisplayTextAccumulator = timeAccumulator
        end

        if goGreen then
            if timeAccumulator - timeToDisplayGreenAccumulator >= timeToDisplayGreen then
                showFlags = false
                goGreen = false
                writeLog("SC: Gone green - Flags off")
                timeToDisplayGreenAccumulator = timeAccumulator
            end
        end

        if getCarLapCounts then        
            local maxSplinePosition = -1

            for i, car in ac.iterateCars.ordered() do
                if car.splinePosition > safetyCar.splinePosition then
                    carLapCounts[car.index] = 9999
                else
                    carLapCounts[car.index] = car.lapCount or 0
                    
                    if car.splinePosition > maxSplinePosition then
                        maxSplinePosition = car.splinePosition
                        raceLeader = car
                    end
                end
                writeLog("SC: Car ID: " .. car.index .. " on lap " .. car.lapCount)
            end

            if raceLeader then
                writeLog("SC: Race Leader: " .. raceLeader:driverName() .. " (Car ID: " .. raceLeader.index .. ")")
            end

            checkGoGreen = true
            getCarLapCounts = false
        end


        if checkGoGreen then
            for i, car in ac.iterateCars.ordered() do
                if car == safetyCarID or car.isInPitlane or car.isInPit then
                    ac.debug("SC: Car Info: ", car)
                elseif car.lapCount > carLapCounts[car.index] then
                    writeLog("SC: Car ID: " .. car.index .. " crossed start finish")
                    writeLog("SC: Leader Go Green")
                    flagColor = rgbm.colors.green
                    scHeadingTextColor = rgbm.colors.green
                    scHeadingText = scHeadingTextState.green
                    scStatusText = scState.off
                    scLeaderText = scLeaderTextState.off

                    showFlags = true
                    goGreen = true
                    
                    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)

                    checkGoGreen = false
                    timeToDisplayGreenAccumulator = timeAccumulator
                    break
                end
            end
        end
    end
end

ac.onSessionStart(function(sessionIndex, restarted)
    initializeSCFlagScript()
    currentSession = ac.getSession(sessionIndex)
    writeLog("SC: Flag Script Initialized on Session Start")
end)

ac.onRelease(initializeSCFlagScript)

initializeSCFlagScript()

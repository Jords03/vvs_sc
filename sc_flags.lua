-- Get states
local sim = ac.getSim()
local driverCar = ac.getCar()
local safetyCarID = ac.getCarByDriverName("Safety Car")
local safetyCar = ac.getCar(safetyCarID)
local adminCar
local currentSession = ac.getSession(sim.currentSessionIndex)
local trackLength = sim.trackLengthM

local function getStates()
    sim = ac.getSim()
    driverCar = ac.getCar()
    safetyCarID = ac.getCarByDriverName("Safety Car")
    safetyCar = ac.getCar(safetyCarID)
    if ac.getCarByDriverName("Jon Astrop") then
        local adminCarID = ac.getCarByDriverName("Jon Astrop")
        adminCar = ac.getCar(adminCarID)
    end
end

-- Safety Car state variables
local scState = {
    deployed = "DEPLOYED",
    returning = "ENDING",
    enteringPit = "CLEAR",
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
    leader = "YOU ARE RACE LEADER",
    maintain = "MAINTAIN 120 KMH",
    goAnyTime = "GO AT ANY TIME",
    off = ""
}

local scHelperTextState = {
    catchPack = "CATCH THE SAFETY CAR",
    closeGap = "TOO FAR - CLOSE GAP",
    erratic = "DON'T DRIVE ERRATICALLY",
    passSafetyCar = "PASS SAFETY CAR - CATCH PACK",
    off = ""
}

-- Initialize variables
local flagColor = rgbm.colors.gray
local showFlags = false
local goGreen = false
local onTrack = false
local enterPits = false
local getCarLapCounts = false
local checkGoGreen = false
local carLapCounts = {}
local prevSCState = ""
local raceLeader = nil

-- Leaderboard variables
local carLeaderboard = {}
local prevDistances = {}
local hasCrossedSF = {}
local prevSplines = {}
local sfCheckHeartBeat = 1
local sfCheckTime = 0
local leaderCheckTime = 0
local allCarsCrossed = false

-- Text variables
local headFontSize = 22
local fontsize = 28
local helperFontsize = 18
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
local scInTimeAccumulator = 0
local erraticCheckAccumulator = 0
local timeToDisplayTextAccumulator = 0
local timeToDisplayGreenAccumulator = 0
local miniCheckInterval = 0.1 -- seconds
local shortCheckInterval = 0.5 -- seconds
local timeToDisplaySCText = 2
local timeToDisplayGreen = 6
local lapcount = 0
local erraticTimer = 0
local erraticDisplayDuration = 2

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
local previousSpeed = nil
local previousHelperTextState = nil
local distanceThreshold = 28

-- Combined threshold values for detecting erratic behavior
local erraticThresholds = {
    suddenSpeedChange = 5,    -- km/h
    suddenSteer = 8,         -- degrees
    highAngularVelocity = 0.6   -- rad/s, for swerving detection
}

local function reInitailizeVars ()
    -- Initialize variables
    flagColor = rgbm.colors.gray
    showFlags = false
    goGreen = false
    onTrack = false
    enterPits = false
    getCarLapCounts = false
    checkGoGreen = false
    carLapCounts = {}
    prevSCState = ""
    raceLeader = nil

    -- Leaderboard variables
    carLeaderboard = {}
    prevDistances = {}
    hasCrossedSF = {}
    prevSplines = {}
    sfCheckHeartBeat = 1
    sfCheckTime = 0
    leaderCheckTime = 0
    allCarsCrossed = false

    -- Text variables
    headFontSize = 22
    fontsize = 28
    helperFontsize = 18
    scHeadingText = scHeadingTextState.sc
    scHeadingTextBG = rgbm.colors.black
    scHeadingTextColor = rgbm.colors.yellow
    scTextColor = rgbm.colors.white
    scHelperTextColor = rgbm.colors.red
    scLeaderTextColor = rgbm.colors.orange
    scStatusText = ""
    scLeaderText = ""
    scHelperText = ""

    -- Time variables
    timeAccumulator = 0
    scInTimeAccumulator = 0
    miniCheckInterval = 0.1
    shortCheckInterval = 0.5
    timeToDisplayTextAccumulator = 0
    timeToDisplaySCText = 2
    timeToDisplayGreenAccumulator = 0
    timeToDisplayGreen = 6
    lapcount = 0
    erraticTimer = 0
    erraticDisplayDuration = 2

    -- Audio variables
    audioLoaded = false

    -- Window variables
    flagWindowSize = vec2(300, 180)
    defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
    defaultFlagWindowPosY = (sim.windowHeight/8) - (flagWindowSize.y/2)
    flagWindowPosX = ac.load("SCFlagsWindowPosX")
    flagWindowPosY = ac.load("SCFlagsWindowPosY")

    -- Data storage for tracking the previous state of the driver car (to detect erratic behavior)
    previousDriverCarState = nil
    previousSpeed = nil
    previousHelperTextState = nil
    distanceThreshold = 28

end

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
    scGoGreenAudio = folder .. "/safety_car_green_flag.wav"

    scDeployedAudio = {
        --filename = 'extension/lua/online/AC_RP_SafetyCar/safety_car.wav',
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
    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)

    --writeLog("SC: audioSCDeployedEvent Vol: " .. audioSCInThisLapEvent.volume)
    --writeLog("SC: audioSCInThisLapEvent Vol: " .. audioSCInThisLapEvent.volume)
    --writeLog("SC: audioSCGoGreenEvent Vol: " .. audioSCGoGreenEvent.volume)

    audioLoaded = true
end

-- Call web.loadRemoteAssets with the URL and the logging callback
web.loadRemoteAssets("https://raw.githubusercontent.com/Jords03/vvs_sc/main/sc_wav_files.zip", logAudioCallback)

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
            scLeaderText = scLeaderTextState.leader
            showFlags = true
            goGreen = false
            onTrack = true
            audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
            audioSCDeployedEvent.volume = 15
            audioSCDeployedEvent:start()
        elseif message == "SC: Safety Car is heading to pits" then
            writeLog("SC: Recieved - Safety Car is heading to pits")
            flagColor = rgbm(0.6, 0.6, 0, 1)
            scStatusText = scState.returning
            scTextColor = rgbm.colors.black
            scLeaderText = scLeaderTextState.off
            showFlags = true
            goGreen = false
            onTrack = true
            audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
            audioSCInThisLapEvent.volume = 15
            audioSCInThisLapEvent:start()
            timeToDisplayTextAccumulator = timeAccumulator
        elseif message == "SC: Safety Car is entering pit lane" then
            writeLog("SC: Recieved - Safety Car is entering pit lane")
            flagColor = rgbm(0.4, 0.4, 0.4, 1)
            scStatusText = scState.enteringPit
            scTextColor = rgbm.colors.yellow
            scLeaderText = scLeaderTextState.goAnyTime
            showFlags = true
            enterPits = true
            onTrack = false
            goGreen = false
            getCarLapCounts = true
            --checkGoGreen = true
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


local function checkSFCrossing()
    --for efficiency, once all cars are crossed then don't run this
    if allCarsCrossed then return end
    --on the heartbeat
    if timeAccumulator - sfCheckTime  >= sfCheckHeartBeat then
        local anyFalse = false

        --iterate the list of cars
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

        -- sanity check - if it's less than the previous distance then discard and go with previous measurement
        if distanceDriven >= prevDistances[car.index] then
            prevDistances[car.index] = distanceDriven
        else
            writeLog("SANITY CHECK FAILED! " .. car:driverName() .. car.splinePosition .. "|" .. trackLength .. "|" .. car.lapCount .. "|".. distanceDriven .. "|" .. prevDistances[car.index] )
            distanceDriven = prevDistances[car.index]
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
local function calculateDistanceBehind(carPosition, scPosition)
    local distance = (scPosition - carPosition) % 1
    return distance  -- Always a value between 0 and 1
end

-- Function to detect erratic driving behavior and check distance
local function detectErraticAndPos(dt)
    local car = driverCar

    if car and not car.isInPitlane and not car.isInPit then
        local carAhead = nil
        local carDistance = nil
        local tooFar = false
        local catchPack = false
        local passSafetyCar = false
        local raceLeaderPos = nil
        local isRaceLeader = false

        -- Determine the race leader
        if timeAccumulator - leaderCheckTime >= shortCheckInterval then
            carLeaderboard = getLeaderboard()
            raceLeaderPos = carLeaderboard[1].car
            leaderCheckTime = timeAccumulator
        end

        -- Check if driverCar is the race leader
        if raceLeaderPos then
            isRaceLeader = (car == raceLeaderPos)
        end

        -- Calculate the distance behind the safety car
        local distanceBehindSC = calculateDistanceBehind(car.splinePosition, safetyCar.splinePosition)
        local distanceInMeters = distanceBehindSC * trackLength

        -- Only calculate distanceBehindLeader if the driver is not the race leader
        local distanceBehindLeader = 0
        if not isRaceLeader then
            distanceBehindLeader = calculateDistanceBehind(car.splinePosition, raceLeaderPos.splinePosition)
        end

        -- Check if the driver is a lap down and between the race leader and the Safety Car
        local lapDownFromLeader = not isRaceLeader and (raceLeaderPos.lapCount > car.lapCount)
        local betweenLeaderAndSafetyCar = not isRaceLeader and (distanceBehindLeader < distanceBehindSC)

        if lapDownFromLeader and betweenLeaderAndSafetyCar then
            passSafetyCar = true
        end

        -- Determine if another car is ahead and calculate the distance to it
        local minDistanceAhead = 1  -- Initialize with maximum possible spline position difference
        for i, otherCar in ac.iterateCars.ordered() do
            if otherCar ~= safetyCar and otherCar ~= car then
                local distanceAhead = calculateDistanceBehind(car.splinePosition, otherCar.splinePosition)
                if distanceAhead > 0 and distanceAhead < minDistanceAhead then
                    minDistanceAhead = distanceAhead
                    carAhead = otherCar
                end
            end
        end

        -- Calculate the distance and determine if the driver is too far
        if carAhead then
            carDistance = minDistanceAhead * trackLength
            tooFar = carDistance > distanceThreshold
            if carDistance > (distanceThreshold * 3) then
                catchPack = true
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

            -- Handle erratic display timer using dt
            if isErratic then
                erraticTimer = erraticDisplayDuration
            elseif erraticTimer > 0 then
                erraticTimer = erraticTimer - miniCheckInterval
            end

            -- Determine if the erratic state should still be displayed
            local erraticActive = erraticTimer > 0

            -- Prioritize conditions
            local newHelperTextState = scHelperTextState.off
            
            if passSafetyCar then
                newHelperTextState = scHelperTextState.passSafetyCar
            elseif catchPack then
                newHelperTextState = scHelperTextState.catchPack
            elseif erraticActive then  -- Use the timer-controlled state instead of direct isErratic
                newHelperTextState = scHelperTextState.erratic
            elseif tooFar then
                newHelperTextState = scHelperTextState.closeGap
            end

            if newHelperTextState ~= previousHelperTextState then
                scHelperText = newHelperTextState
                previousHelperTextState = newHelperTextState
            end

            -- Debugging output
            ac.debug("SC Flags: newHelperTextState", newHelperTextState)
            ac.debug("SC Flags: DT", dt)
            ac.debug("SC Flags: Driver", car:driverName())
            ac.debug("SC Flags: raceLeaderPos", raceLeaderPos:driverName())
            ac.debug("SC Flags: distanceInMeters", distanceInMeters)
            ac.debug("SC Flags: distanceBehindSC", distanceBehindSC)
            ac.debug("SC Flags: distanceBehindLeader", distanceBehindLeader)
            ac.debug("SC Flags: carDistance", carDistance)
            ac.debug("SC Flags: speedChange", speedChange)
            ac.debug("SC Flags: steerChange", steerChange)
            ac.debug("SC Flags: angularVelocityChange", angularVelocityChange)
            ac.debug("SC Flags: catchPack", catchPack)
            ac.debug("SC Flags: isErratic", isErratic)
            ac.debug("SC Flags: erraticActive", erraticActive)
            ac.debug("SC Flags: tooFar", tooFar)
        end

        -- Update previous driver car state for the next frame
        previousDriverCarState = {
            speedKmh = car.speedKmh,
            steer = car.steer,
            angularVelocity = car.angularVelocity
        }
    end
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
        ui.drawRectFilled(vec2(scHeadingTextBoxStart), vec2(scHeadingTextBoxEnd), scHeadingTextBG, 5,
            ui.CornerFlags.Top)
        ui.dwriteDrawText(scHeadingText, headFontSize, scHeadingTextStart, scHeadingTextColor)

        ui.drawRectFilled(vec2(scFlagBoxStart), vec2(scFlagBoxEnd), flagColor, 5, ui.CornerFlags.Bottom)
        ui.dwriteDrawText(scStatusText, fontsize, scStatusTextStart, scTextColor)
        
        if driverCar ~= safetyCar then
            if carLeaderboard[1] then
                if driverCar == carLeaderboard[1].car then
                    ui.dwriteDrawText(scLeaderText, helperFontsize, scLeaderTextStart, scLeaderTextColor)
                    scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 2)
                end
            end
            ui.dwriteDrawText(scHelperText, helperFontsize, scHelperTextStart, scHelperTextColor)
        end
        ui.endTransparentWindow()

    end
end

function script.drawUI()
    uiFlags()
end

function script.update(dt)

    timeAccumulator = timeAccumulator + dt

    checkSFCrossing()

    ac.debug("SC Flags: driverCar", driverCar:driverName())
    if carLeaderboard[1] then
        ac.debug("SC Flags: leaderboard 1", carLeaderboard[1].car:driverName())
    end

    --[[
    ac.debug("SC FLags: Time Accumulator", timeAccumulator)
    ac.debug("SC FLags: showFlags", showFlags)
    ac.debug("SC FLags: goGreen", goGreen)
    ac.debug("SC FLags: scState", scStatusText)
    ac.debug("SC FLags: flagWindowPos", flagWindowPos)
    ]]

    if showFlags then

        if onTrack then
            if timeAccumulator - erraticCheckAccumulator >= miniCheckInterval then
                if carLeaderboard[1] then
                    if not (driverCar == carLeaderboard[1].car and driverCar.splinePosition > 0.8) then
                        detectErraticAndPos(dt)
                    end
                end
                erraticCheckAccumulator = timeAccumulator
            end
        end

        if enterPits then
            scHelperText = scHelperTextState.off
            if timeAccumulator - timeToDisplayTextAccumulator >= timeToDisplaySCText then
                scStatusText = scState.off
                flagColor = rgbm(0.3, 0.3, 0.3, 1)
                scTextColor = rgbm(1, 0.27, 0.02, 1)
                enterPits = false
                onTrack = false
                writeLog("SC: Status - Get Ready")
                timeToDisplayTextAccumulator = timeAccumulator
            end
        end

        if goGreen then
            if timeAccumulator - timeToDisplayGreenAccumulator >= timeToDisplayGreen then
                showFlags = false
                onTrack = false
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
                    ac.debug("SC: Car Info: ", car:driverName())
                elseif car.lapCount > carLapCounts[car.index] then
                    writeLog("SC: Car ID: " .. car:driverName() .. " crossed start finish")
                    writeLog("SC: Leader Go Green")
                    flagColor = rgbm(0,225,0,1)
                    scHeadingTextColor = rgbm(0,225,0,1)
                    scHeadingText = scHeadingTextState.green
                    scStatusText = scState.off
                    scLeaderText = scLeaderTextState.off

                    showFlags = true
                    goGreen = true
                    
                    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)
                    audioSCGoGreenEvent.volume = 15
                    audioSCGoGreenEvent:start()

                    checkGoGreen = false
                    timeToDisplayGreenAccumulator = timeAccumulator
                    break
                end
            end
        end
    end
end

ac.onSessionStart(function(sessionIndex, restarted)
    getStates()
    reInitailizeVars()
    initializeSCFlagScript()
    currentSession = ac.getSession(sessionIndex)
    writeLog("SC: Flag Script Initialized on Session Start")
end)

ac.onRelease(initializeSCFlagScript)

getStates()
reInitailizeVars()
initializeSCFlagScript()


SCRIPT_NAME = "VVS Safety Car Flags Mark2"
SCRIPT_SHORT_NAME = "VVSSCFLAGS2"
SCRIPT_VERSION = "0.0.1.2"
SCRIPT_VERSION_CODE = 00002

--####################################################################################################
--####################################### GLOBALS ####################################################
--####################################################################################################

--CONSTANTS
local adminCarNames = {"Jon Astrop", "Dominic Fovargue", "Nigel Walters"}
local safetyCarName = "Safety Car"
--distance you should be within when following
local distanceThreshold = 16
--distance multiplier - controls where we switch to catch up message rather than close gap
local distanceThresholdMultiplier = 2.5

--VARIABLES WE NEED TO REINIT

--timers
local timeAccumulator = 0
local thirdSecWaitTimer = 0
local halfSecWaitTimer = 0
local tenthSecWaitTimer = 0
local goGreenTimer = 0

--track race leader
local raceLeaderCar = nil
local prevRaceLeaderCar = nil
local leaderChangedLastBeat = false
local raceLeaderLapCount = -1

--sim stuff
local sim = ac.getSim()
local trackLength = sim.trackLengthM
local driverCar = ac.getCar(0)

--we will use scFlagsState.status to track the current state of the SC Flags
--for rolling starts it will go: inactive -> rolling -> rollingComingIn -> green -> inactive
--for normal SC callouts it will go: inactive -> deployed -> comingIn -> clear -> green -> inactive
local scFlagsState = {
    status = "inactive",
    headingText = "", --shown at the very top of the normal flag box
    headingTextColor = rgbm.colors.black, -- heading text colour
    statusText = "", --Main display text / top line of the coming in box
    statusTextColor = rgbm.colors.black, -- status text colour
    speedText = "", --only shown on the coming in box, in the middle
    helperText = "", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
    leaderText = "", --Special sub text for the leader
    flagColor = rgbm.colors.yellow -- flag colour   
}

--END OF VARIABLES WE NEED TO REINIT


--####################################################################################################
--####################################### UTILITIES ##################################################
--####################################################################################################

--utility function to write log messages
local function writeLog(message)
    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
    ac.log(timeStamp .. " | " .. SCRIPT_VERSION .. " | SCFLAGS: " .. message)
end

--utility function to check if a table contains a value
local function tableContains(testTable, value)
    for i = 1,#testTable do
      if (testTable[i] == value) then
        return true
      end
    end
    return false
  end


--####################################################################################################
--####################################### SPECIAL CARS ###############################################
--#################################################################################################### 

--getAdminAndSafetyCars variables
local safetyCar
local adminCars = {}

-- Get states from nil checks and late connections
local function getAdminAndSafetyCars()

    local newSafetyCar
    local safetyCarID = ac.getCarByDriverName(safetyCarName)
    if safetyCarID then
        newSafetyCar = ac.getCar(safetyCarID)
        if newSafetyCar then
            if newSafetyCar.isConnected then
                if newSafetyCar ~= safetyCar then
                    writeLog("SC Flags: SC identified as:" .. safetyCarID)
                    safetyCar = newSafetyCar
                end
            end
        end
    end

    adminCars = {}
    for i,v in ipairs(adminCarNames) do
        local adminCarID = ac.getCarByDriverName(v)
        if adminCarID then
            table.insert(adminCars,adminCarID)
        end
    end

end


--####################################################################################################
--####################################### SETTINGS ###################################################
--####################################################################################################

--shared data structure for sc flags settings
local scFlagsValues = ac.connect({
    ac.StructItem.key('vvs.sc_flags_pos'),
    posVec2 = ac.StructItem.vec2(),
    settingsOpen = ac.StructItem.boolean()
}, true, ac.SharedNamespace.Shared)


--####################################################################################################
--####################################### AUDIO ######################################################
--####################################################################################################

-- Audio variables
local scGoGreenAudio
local scClearAudio
local scInThisLapAudio
local scDeployedAudio
local audioSCClearEvent
local audioSCGoGreenEvent
local audioSCInThisLapEvent
local audioSCDeployedEvent

-- Define the callback function
local function logAudioCallback(err, folder)

    -- NEW SOUNDS With Crewchief audio
    scDeployedAudio = folder .. "/sc_safetycarisout.wav"
    scInThisLapAudio = folder .. "/sc_safetycarinthislap.wav"
    scClearAudio = folder .. "/sc_safetycarisclear.wav"
    scGoGreenAudio = folder .. "/sc_greengreengreen.wav"

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


--####################################################################################################
--####################################### RENDERING FLAGS CODE #######################################
--####################################################################################################

-- Window variables
local flagWindowPos
local flagWindowSize = vec2(300, 180)
local defaultFlagWindowPosX = (sim.windowWidth/2) - (flagWindowSize.x/2)
local defaultFlagWindowPosY = (sim.windowHeight/4) - (flagWindowSize.y/2)

-- Text variables
local speedLimit = 100
local headFontSize = 22
local fontsize = 28
local helperFontsize = 16
local scHeadingTextBG = rgbm.colors.black
local scHelperTextColor = rgbm.colors.red
local scLeaderTextColor = rgbm.colors.orange


if scFlagsValues.posVec2 == vec2(0.0) or nil then
    scFlagsValues.posVec2 = vec2(defaultFlagWindowPosX, defaultFlagWindowPosY)
    flagWindowPos = scFlagsValues.posVec2
else
    flagWindowPos = scFlagsValues.posVec2
end

local function textSize(text_size, fontsize)
    local calcTextSize = ui.measureDWriteText(text_size, fontsize)
    return calcTextSize
end

local function uiFlags(dt)
    --draw the flags, but only if the flagsStatus is not inactive (or we are repositioning the flags window)
    if (driverCar ~= safetyCar and scFlagsState.status ~= "inactive") or scFlagsValues.settingsOpen then

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

        local scHeadingTextSize = textSize(scFlagsState.headingText, headFontSize)
        local scStatusTextSize = textSize(scFlagsState.statusText, fontsize)
        local scLeaderTextSize = textSize(scFlagsState.leaderText, helperFontsize)
        local scHelperTextSize = textSize(scFlagsState.helperText, helperFontsize)

        local scHeadingTextStart = scHeadingRectCenter - (scHeadingTextSize / 2)
        local scStatusTextStart = scFlagBoxCenter - (scStatusTextSize / 2)
        local scLeaderTextStart = scHelperTextCenter - (scLeaderTextSize / 2)
        local scHelperTextStart = scHelperTextCenter - (scHelperTextSize / 2)
        ui.pushDWriteFont("RealPenalty")

        --there are 2 states for the flags box - the normal one, and the one with the speed limit display
        --the speed limit display is shown for the leader when the SC is coming in after deployment
        --and is shown for everyone if the sc is coming in after a rolling start
        if not (scFlagsState.status == "rollingComingIn" or (scFlagsState.status == "comingIn" and driverCar == raceLeaderCar)) then
            --Draw main flag box for everyone
            ui.drawRectFilled(scHeadingTextBoxStart, scHeadingTextBoxEnd, scHeadingTextBG, 5, ui.CornerFlags.Top)
            ui.dwriteDrawText(scFlagsState.headingText, headFontSize, scHeadingTextStart, scFlagsState.headingTextColor)

            ui.drawRectFilled(scFlagBoxStart, scFlagBoxEnd, scFlagsState.flagColor, 5, ui.CornerFlags.Bottom)
            ui.dwriteDrawText(scFlagsState.statusText, fontsize, scStatusTextStart, scFlagsState.statusTextColor)

            if sim.timeToSessionStart < 0 then
                if driverCar == raceLeaderCar then
                    -- Leader gets an additional text line
                    ui.dwriteDrawText(scFlagsState.leaderText, helperFontsize, scLeaderTextStart, scLeaderTextColor)
                    scHelperTextStart = scHelperTextStart + vec2(0, scHelperTextSize.y + 2)
                end
                if true then
                    -- All driver helper text
                    ui.dwriteDrawText(scFlagsState.helperText, helperFontsize, scHelperTextStart, scHelperTextColor)
                end
            end
        --Speed limit display
        else

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
            local carSpeed = 1
            if driverCar == nil then
                writeLog("ERROR: Rendering flags and driver car is nil!!")
                -- try and get it again
                driverCar = ac.getCar(0)
                return
            else
                carSpeed = math.floor(driverCar.speedKmh * 10) / 10
            end
        
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
            local speedIndicatorEnd = vec2(speedIndicatorValue, speedIndicatorBoxSize.y)
            local isOverLimit = carSpeed > speedLimit
            local rectColor = isOverLimit and rgbm(0.8, 0, 0, 1) or rgbm(0, 0.8, 0, 1)

            ui.drawRectFilled( vec2(0, 0), vec2(speedIndicatorBoxSize.x, speedIndicatorBarHeight), rgbm(0.8, 0.8, 0, 1), 0, ui.CornerFlags.None )
            ui.dwriteTextAligned( scFlagsState.statusText, speedHelperFontSize, ui.Alignment.Center, ui.Alignment.End, vec2(ui.availableSpaceX(), speedIndicatorBarHeight-2), false, rgbm(0, 0, 0, 1))
            
            ui.drawRectFilled( vec2(0, speedIndicatorBarHeight), vec2(speedIndicatorBoxSize.x, speedIndicatorBarHeight*2), rgbm(0.15, 0.15, 0.3, 1), 0, ui.CornerFlags.None )
            ui.dwriteTextAligned( scFlagsState.speedText, speedHelperFontSize-2, ui.Alignment.Center, ui.Alignment.End, vec2(ui.availableSpaceX(), speedIndicatorBarHeight-10), false, rgbm(0.7, 0.7, 0.7, 1))
            
            ui.drawRectFilled( vec2(0, speedIndicatorBarHeight*2 + speedIndicatorValueGap), speedIndicatorEnd, rectColor, 0, ui.CornerFlags.None )
            ui.dwriteDrawText(tostring(carSpeed), speedIndicatorFontSize, vec2(20, speedIndicatorValueYOffset), rgbm(0, 0, 0, 1))

            if isOverLimit then
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
        ui.endTransparentWindow()
    end
end

function script.drawUI()
    uiFlags()
end

--####################################################################################################
--############################# STATE TRANSITION UTILITY FUNCTIONS ###################################
--####################################################################################################

--for rolling starts it will go: inactive -> rolling -> rollingComingIn -> green -> inactive
--for normal SC callouts it will go: inactive -> deployed -> comingIn -> clear -> green -> inactive

local function scRollingStart()
    writeLog("State transition from " .. scFlagsState.status .. " to rolling")

    scFlagsState = {
        status = "rolling",
        headingText = "SAFETY CAR", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.yellow, -- heading text colour
        statusText = "ROLLING START", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.black, -- status text colour
        speedText = "", --only shown on the coming in box, in the middle
        helperText = "NO OVERTAKING", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "YOU ARE RACE LEADER", --Special sub text for the leader
        flagColor = rgbm.colors.yellow -- flag colour   
    }

end

local function scDeployed()

    writeLog("State transition from " .. scFlagsState.status .. " to deployed")

    scFlagsState = {
        status = "deployed",
        headingText = "SAFETY CAR", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.yellow, -- heading text colour
        statusText = "DEPLOYED", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.black, -- status text colour
        speedText = "", --only shown on the coming in box, in the middle
        helperText = "NO OVERTAKING", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "YOU ARE RACE LEADER", --Special sub text for the leader
        flagColor = rgbm.colors.yellow -- flag colour   
    }

    audioSCDeployedEvent = ac.AudioEvent.fromFile(scDeployedAudio, false)
    audioSCDeployedEvent.volume = 5
    audioSCDeployedEvent:start()

end

local function scRollingComingIn()
    writeLog("State transition from " .. scFlagsState.status .. " to rollingComingIn")

    scFlagsState = {
        status = "rollingComingIn",
        headingText = "SAFETY CAR", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.yellow, -- heading text colour
        statusText = "ENDING", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.black, -- status text colour
        speedText = "MAINTAIN YOUR SPEED", --only shown on the coming in box, in the middle
        helperText = "NO OVERTAKING", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "", --Special sub text for the leader
        flagColor = rgbm(0.6, 0.6, 0, 1) -- flag colour   
    }

    audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
    audioSCInThisLapEvent.volume = 5
    audioSCInThisLapEvent:start()

end

local function scInThisLap()
    writeLog("State transition from " .. scFlagsState.status .. " to comingIn")

    scFlagsState = {
        status = "comingIn",
        headingText = "SAFETY CAR", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.yellow, -- heading text colour
        statusText = "ENDING", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.black, -- status text colour
        speedText = "MAINTAIN YOUR SPEED", --only shown on the coming in box, in the middle
        helperText = "NO OVERTAKING", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "", --Special sub text for the leader
        flagColor = rgbm(0.6, 0.6, 0, 1) -- flag colour   
    }

    audioSCInThisLapEvent = ac.AudioEvent.fromFile(scInThisLapAudio, false)
    audioSCInThisLapEvent.volume = 5
    audioSCInThisLapEvent:start()

    writeLog("Set Safety Car in this lap Done")
end

local function scIsClear()
    writeLog("State transition from " .. scFlagsState.status .. " to clear")

    scFlagsState = {
        status = "clear",
        headingText = "SAFETY CAR", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.yellow, -- heading text colour
        statusText = "CLEAR", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.yellow, -- status text colour
        speedText = "", --only shown on the coming in box, in the middle
        helperText = "NO OVERTAKING", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "GO AT ANY TIME", --Special sub text for the leader
        flagColor = rgbm(0.4, 0.4, 0.4, 1) -- flag colour   
    }

    audioSCClearEvent = ac.AudioEvent.fromFile(scClearAudio, false)
    audioSCClearEvent.volume = 5
    audioSCClearEvent:start()

    writeLog("Set Safety Car is clear Done")
end

local function scGoGreen()
    writeLog("State transition from " .. scFlagsState.status .. " to green")

    scFlagsState = {
        status = "green",
        headingText = "GREEN FLAG", --shown at the very top of the normal flag box
        headingTextColor = rgbm(0,225,0,1), -- heading text colour
        statusText = "", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.yellow, -- status text colour
        speedText = "", --only shown on the coming in box, in the middle
        helperText = "", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "", --Special sub text for the leader
        flagColor = rgbm(0,225,0,1) -- flag colour   
    }

    audioSCGoGreenEvent = ac.AudioEvent.fromFile(scGoGreenAudio, false)
    audioSCGoGreenEvent.volume = 5
    audioSCGoGreenEvent:start()

    goGreenTimer = timeAccumulator

end

local function scInactive()
    writeLog("State transition from " .. scFlagsState.status .. " to inactive")

    scFlagsState = {
        status = "inactive",
        headingText = "", --shown at the very top of the normal flag box
        headingTextColor = rgbm.colors.black, -- heading text colour
        statusText = "", --Main display text / top line of the coming in box
        statusTextColor = rgbm.colors.black, -- status text colour
        speedText = "", --only shown on the coming in box, in the middle
        helperText = "", --helper text shown below to give guidance (e.g. catch up etc.) - usually dynamic and will change frequently
        leaderText = "", --Special sub text for the leader
        flagColor = rgbm.colors.yellow -- flag colour   
    }

end

--####################################################################################################
--####################################### INITIALIZATION #############################################
--####################################################################################################

local function initialize()
    writeLog("SC Flags: Initialization starting")

    --timers
    timeAccumulator = 0
    thirdSecWaitTimer = 0
    halfSecWaitTimer = 0
    tenthSecWaitTimer = 0
    goGreenTimer = 0

    --track race leader
    raceLeaderCar = nil
    prevRaceLeaderCar = nil
    leaderChangedLastBeat = false
    raceLeaderLapCount = -1

    --sim stuff
    sim = ac.getSim()
    trackLength = sim.trackLengthM
    driverCar = ac.getCar(0)

    --reset SC flags to inactive (will turn off the flags)
    scInactive()

    --fetch the admin and safety cars
    getAdminAndSafetyCars()

    writeLog("SC Flags: Initialization finished - sending notification messages.")
    if (driverCar ==nil) then
        writeLog("SC Flags: Initialization finished - Initialisation ERROR driverCar not identified!")
        ac.sendChatMessage("SC: INFO | SC Flags Script " .. SCRIPT_VERSION .. " Initialisation ERROR driverCar not identified!")
    elseif (safetyCar == nil) then
        writeLog("SC Flags: Initialization finished - Initialisation ERROR safetyCar not identified!")
        ac.sendChatMessage("SC: INFO | SC Flags Script " .. SCRIPT_VERSION .. " Initialisation ERROR safetyCar not identified for driver " .. driverCar:driverName())
    else
        writeLog("SC Flags: Initialization finished - Initialisation successful")
        ac.sendChatMessage("SC: INFO | SC Flags Script " .. SCRIPT_VERSION .. " Initialisation " .. driverCar:driverName() .. " - SC - " .. safetyCar:driverName())
    end
end

--force reinit whenever session changes or script reloads
ac.onSessionStart(function(sessionIndex, restarted)
    initialize()
end)

function script.reset()
    writeLog("SC Flags: Flag Script Reset")
    initialize()
end

ac.onRelease(function()
    writeLog("SC Flags: Flag Script Released/Reload")
    initialize()
end)

initialize()


--####################################################################################################
--####################################### GAME LOOP ##################################################
--####################################################################################################

--chat message processing - will cause various state transitions
ac.onChatMessage(function(message, senderCarIndex, senderSessionID)
    if string.startsWith(message, "SC") then
        --refresh the admin and safety car details
        getAdminAndSafetyCars()

        if safetyCar then

            if (senderCarIndex == safetyCar.index or (adminCars and tableContains(adminCars,senderCarIndex))) then
                writeLog("Chatmsg received: " .. message)
                --rolling start invoked
                if message == "SC: Safety Car rolling start" then
                    writeLog("SC Flags: Recieved - Safety Car rolling start")
                    scRollingStart()
                --sc deployed and on track
                elseif message == "SC: Safety Car deployed" then
                    scDeployed()
                --sc coming in after rolling start
                elseif message == "SC: Safety Car Rolling Start Coming In" then
                    scRollingComingIn()
                --sc coming in after deployment
                elseif message == "SC: Safety Car in this lap" then
                    scInThisLap()
                --sc made it back to pits
                elseif message == "SC: Safety Car is clear" then
                    scIsClear()
                --sc being killed
                elseif message == "SC kill" then
                    writeLog("SC Flags: Recieved - SC kill")
                    --treat this like the SC has gone in
                    scInThisLap()
                    scIsClear()
                --flags kill switch
                elseif message == "SC kf" then 
                    writeLog("SC Flags: Recieved - SC kf")
                    initialize()
                end
            end
        end
    end
    return true
end)

-- Determine the race leader - because AC is a fucker, for safety we only update to the new race leader if it stays that way for 2 consecutive beats
local function updateRaceLeader()

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
                writeLog("Race leader change - leader now is: " .. raceLeaderCar:driverName())
                leaderChangedLastBeat = false
            else
                --it changed again, we can't trust this
                writeLog("Race leader consecutive change - discarding: " .. raceLeaderCar:driverName())
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
end

-- Calculate the normalized distance between 2 cars
local function calculateDistanceTo(carPosition, otherPosition)
    if carPosition > otherPosition then
        otherPosition = otherPosition + 1
    end
    return otherPosition - carPosition  -- Always a value between 0 and 1
end

-- get the updated helper text
local function getHelperText()

    local carAhead = nil
    local carAheadDistance = 1 -- Initialize with maximum possible spline position difference

    -- Calculate the distance behind the safety car

    if driverCar == nil then
        writeLog("ERROR: In get helper text and driver car is nil!!")
        -- try and get it again
        driverCar = ac.getCar(0)
        return
    end

    local distanceBehindSC = calculateDistanceTo(driverCar.splinePosition, safetyCar.splinePosition)

    -- Find the next car ahead on track and get the distance ahead
    if driverCar == raceLeaderCar then
        --if we are race keader then force car ahead to be the SC
        carAhead = safetyCar
        carAheadDistance = distanceBehindSC
    else
        --for everyone else then step across all other cars and find the one with the lowest distance ahead of us
        for i, otherCar in ac.iterateCars.ordered() do
            if otherCar ~= safetyCar and otherCar ~= driverCar and otherCar.isConnected and not (otherCar.isInPitlane or otherCar.isInPit) then
                local distanceAhead = calculateDistanceTo(car.splinePosition, otherCar.splinePosition)
                if distanceAhead > 0 and distanceAhead < carAheadDistance then
                    carAheadDistance = distanceAhead
                    carAhead = otherCar
                end
            end
        end
    end

    --writeLog("Car ahead is: " .. carAhead:driverName() .. " and is " .. minDistanceAhead * trackLength .. " ahead")

    -- first check are we between the leader and the safety car, in which case we need to pass the SC and catch back up
    if driverCar ~= raceLeaderCar then
        if raceLeaderCar ~= nil then
            local distanceBehindLeader = calculateDistanceTo(car.splinePosition, raceLeaderCar.splinePosition)
            local betweenLeaderAndSafetyCar = (distanceBehindLeader >= distanceBehindSC)
            if betweenLeaderAndSafetyCar then
                return "PASS SAFETY CAR - CATCH PACK"
            end
        else
            writeLog("WARNING: in getHelperText - Race leader car is nil!")
        end
    end

    -- next check, are we too far behind and need to catch up, or close enough but not quite and should close gap
    if carAhead then
        local carAheadDistanceInM = carAheadDistance * trackLength
        
        --way back so use catch message (differs slightly if you are the race leader)
        if (carAheadDistanceInM > (distanceThreshold * distanceThresholdMultiplier)) then
            if driverCar == raceLeaderCar then
                return "CATCH THE SAFETY CAR" .. " - " .. math.floor(carAheadDistanceInM) .. "m"
            else
                return "CATCH THE CAR AHEAD" .. " - " .. math.floor(carAheadDistanceInM) .. "m"
            end
        end

        --close gap check
        if carAheadDistanceInM > distanceThreshold then
            return "TOO FAR - CLOSE GAP" .. " - " .. math.floor(carAheadDistanceInM) .. "m"
        end
    end

    --no checks hit so just go with NO OVERTAKING
    return "NO OVERTAKING"
    
end

--runs every frame
function script.update(dt)

    --for rolling starts it will go: inactive -> rolling -> rollingComingIn -> green -> inactive
    --for normal SC callouts it will go: inactive -> deployed -> comingIn -> clear -> green -> inactive

    --accumulate total time
    timeAccumulator = timeAccumulator + dt

    ac.debug("Status", scFlagsState.status)

    --don't do anything for first 2 seconds
    if timeAccumulator < 2 then
        return
    end

    --check if we should clear the green flag - do this up here as we need to ensure nothing can stop this happening
    if scFlagsState.status == "green" then
        if timeAccumulator - goGreenTimer >= 5 then
            goGreenTimer = 0
            scInactive()
        end
    end

    --recheck for asdmin and safety car every 0.5s
    if timeAccumulator - halfSecWaitTimer >= 0.5 then
        --refresh the admin and safety car details
        getAdminAndSafetyCars()

        halfSecWaitTimer = timeAccumulator
    end

    --reinit 20s before race start 
    if sim.timeToSessionStart <= 20000 and sim.timeToSessionStart > 19000 then
        initialize()
    end

    --update the location if the settings are being tweaked
    if scFlagsValues.settingsOpen then
        flagWindowPos = scFlagsValues.posVec2
    end

    -- If the Safety Car is not present, return
    if not safetyCar then return end

    --if the SC is inactive then sanity check the SC is not on track
    if scFlagsState.status == "inactive" then
        --XXXTODO - sanity check here

        return
    end

    --helper text update
    --do this every 0.1 secs
    if timeAccumulator - tenthSecWaitTimer >= 0.1 then

        --helper text is updated for rolling, deployed or comingIn

        if scFlagsState.status == "rolling" or scFlagsState.status == "deployed" or scFlagsState.status == "comingIn" then

            -- Check positions and update helper text
            scFlagsState.helperText = getHelperText()

            --XXXTODO - implement latch on helpertext to not update unless it stays the same for 2 beats?
        else
            scFlagsState.helperText = ""
        end

        tenthSecWaitTimer = timeAccumulator
    end

    --do this every 0.3 secs
    --race leader check update
    if timeAccumulator - thirdSecWaitTimer >= 0.3 then
        --update the race leader
        updateRaceLeader()

        if raceLeaderCar ~=nil then
            raceLeaderLapCount = raceLeaderCar.lapCount
        else
            raceLeaderLapCount = -1
            writeLog("WARNING: Updated race leader and race leader is nil!!")
            return
        end
        
        thirdSecWaitTimer = timeAccumulator

    end

    -- Go green same time

    --waiting for this if the status is rollingComingIn or clear
    if scFlagsState.status == "rollingComingIn" or scFlagsState.status == "clear" then

        if raceLeaderCar ~=nil then
            if raceLeaderLapCount == -1 then
                writeLog("WARNING: In green check and race leader lap count is not initialised")
                return
            end

            if raceLeaderCar.lapCount > raceLeaderLapCount then
                writeLog("Leader Car ID: " .. raceLeaderCar:driverName() .. " crossed start finish")

                --green light trigger
                scGoGreen()

                --send out green light received chat message
                writeLog("SC Flags: About to send green light chat message back")

                if driverCar ~= nil and raceLeaderCar ~= nil then
                    local timeStamp = os.date("%Y-%m-%d %H:%M:%S")
                    local timeLeft = sim.sessionTimeLeft
                    if scFlagsState.status == "rollingComingIn" then
                        ac.sendChatMessage("SC: INFO | GREEN LIGHT AFTER ROLLING START | " .. driverCar:driverName() .. " | " .. driverCar.splinePosition .. " | " .. driverCar.speedKmh .. " | " .. timeStamp .. " | " .. timeLeft .. " | " .. timeAccumulator .. " | " .. raceLeaderCar:driverName())
                    else
                        ac.sendChatMessage("SC: INFO | GREEN LIGHT AFTER SC CALLOUT | " .. driverCar:driverName() .. " | " .. driverCar.splinePosition .. " | " .. driverCar.speedKmh .. " | " .. timeStamp .. " | " .. timeLeft .. " | " .. timeAccumulator .. " | " .. raceLeaderCar:driverName())
                    end
                end
            end
        else
            writeLog("WARNING: In green check and race leader is nil!!")
        end
    end
end

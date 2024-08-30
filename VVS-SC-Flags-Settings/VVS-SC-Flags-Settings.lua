local sim = ac.getSim()

local initalX = sim.windowWidth/2
local initalY = sim.windowHeight/8
local scFlagsPosValues = ac.storage {}

if not ac.storageHasKey(scFlagsPosValues, "flagPosX") then
    scFlagsPosValues = ac.storage {
        flagPosX = initalX,
        flagPosY = initalY
    }
end

ac.store("SCFlagsWindowPosX" , scFlagsPosValues.flagPosX)
ac.store("SCFlagsWindowPosY" , scFlagsPosValues.flagPosY)
ac.store("scFlagsSettingsOpen" , 1)

function script.update()
    ac.debug("SC: FlagsOn: ", ac.load("scFlagsSettingsOpen"))
end

function script.windowMain(dt)

    ui.text("SC Flags Position")
    local refX = refnumber(scFlagsPosValues.flagPosX)
    if ui.slider('X', refX, 300, sim.windowWidth, 'X: %.0f') then
        scFlagsPosValues.flagPosX = refX.value
        ac.store("scFlagsSettingsOpen" , 1)
        ac.store("SCFlagsWindowPosX" , refX.value)
    end

    local refY = refnumber(scFlagsPosValues.flagPosY)
    if ui.slider('Y', refY, 0, sim.windowHeight-150, 'Y: %.0f') then
        scFlagsPosValues.flagPosY = refY.value
        ac.store("scFlagsSettingsOpen" , 1)
        ac.store("SCFlagsWindowPosY" , refY.value)
    end
    if ui.button("Reset") then
        scFlagsPosValues.flagPosX = initalX
        scFlagsPosValues.flagPosY = initalY
        ac.store("scFlagsSettingsOpen" , 1)
        ac.store("SCFlagsWindowPosX" , initalX)
        ac.store("SCFlagsWindowPosY" , initalY)
    end
    
end

ac.onRelease(function()
    ac.store("scFlagsSettingsOpen" , 0)
end)
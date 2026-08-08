-- KNOWN ISSUE (not fixed here - Blizzard bug in a bundled third-party library,
-- not this addon's code, tracked here purely for documentation):
--
-- Symptom: while Edit Mode is open, casting/receiving Power Word: Shield (and
-- presumably other aura-name-driven combat log activity) spams BugSack with
-- "Blizzard_FrameXMLUtil/AuraUtil.lua:25: attempt to call a nil value"
-- (methodName="GetAuraDataBySpellName"). Also reproducible by hovering a
-- buff/debuff icon whose screen position happens to overlap one of Edit
-- Mode's dummy preview icons, which surfaces the real aura's tooltip.
--
-- Root cause: Blizzard_EditMode/Shared/EditModeManager.lua's EnterEditMode()
-- calls AuraUtil.SetDataProvider(GetEditModeAuraDataProvider()), swapping
-- AuraUtil's data source to a small mock object (Blizzard_EditMode/Shared/
-- EditModeAuraDataProvider.lua) that only implements GetAuraSlots,
-- GetAuraDataBySlot and GetAuraDataByAuraInstanceID - not
-- GetAuraDataBySpellName. This addon's bundled libs/LibHealComm-4.0/
-- LibHealComm-4.0.lua calls AuraUtil.FindAuraByName (via its own local
-- unitHasAura(unit, name) helper, LibHealComm-4.0.lua:794-800) from inside
-- HealComm:COMBAT_LOG_EVENT_UNFILTERED (LibHealComm-4.0.lua:2871) on every
-- relevant combat log event for a tracked unit, which crashes while that mock
-- provider is active. ExitEditMode() calls AuraUtil.ClearDataProvider() to
-- restore the real C_UnitAuras provider, so this is scoped entirely to Edit
-- Mode being open - confirmed via C_UnitAuras itself being fully intact
-- in-game (GetAuraDataBySpellName included) once Edit Mode is closed.
--
-- Not patched: purely cosmetic (BugSack noise while previewing frame layout
-- in Edit Mode, a non-gameplay UI state), no effect on heal prediction or
-- absorb display during normal play, and the bug is in Blizzard's own mock
-- object plus bundled/vendored LibHealComm-4.0 - not this addon's own code.
--
-- FIXME
--
-- ORIGINAL: GetAddOnMetadata (was a global var before) no longer exists in the
-- shared Retail/Classic UI codebase - calling it threw "attempt to call a nil value" on the
-- second line of this file, which silently killed the entire rest of the file on load
-- (nothing after this poYint ever ran), except if some other addon happened to shim
-- the old global back in (probably an addon alphabetically before Heal... due to load order).
--
-- local ADDON_NAME = ...
-- local ADDON_VERSION = string.match(GetAddOnMetadata(ADDON_NAME, "Version"), "^v(%d+%.%d+%.%d+)$")
local ADDON_NAME, _ = ...
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local metaData = GetAddOnMetadata(ADDON_NAME, "Version")
local ADDON_VERSION = string.match(metaData or "", "^v(%d+%.%d+%.%d+)$")
if not ADDON_VERSION then
    ADDON_VERSION = "Local Dev Build"
end
ChatFrame1:AddMessage("Loading " .. ADDON_NAME .. "(" .. ADDON_VERSION .. ")" .. " test version for WoW Classic Era Patch 1.15.9.", 0.85, 0.82, 0.0)

local HealComm = LibStub("LibHealComm-4.0")
local HealComm_OVERTIME_HEALS = bit.bor(HealComm.HOT_HEALS, HealComm.CHANNEL_HEALS)

ClassicHealPredictionFrame_OnLoad = ClassicHealPredictionFrame_OnLoad or function() end
ClassicHealPredictionFrame_OnEvent = ClassicHealPredictionFrame_OnEvent or function() end


local assert = assert
local bit = bit
local format = format
local min = min
local max = max
local pairs = pairs
local ipairs = ipairs
local select = select
local wipe = wipe
local tinsert = tinsert
local unpack = unpack
local next = next

local GetTime = GetTime
local CreateColor = CreateColor

local UnitGUID = UnitGUID
local UnitCanAssist = UnitCanAssist
local CastingInfo = CastingInfo
local GetSpellPowerCost = GetSpellPowerCost
local GetSpellInfo = GetSpellInfo
local InCombatLockdown = InCombatLockdown

local PlayerFrame = PlayerFrame
local PetFrame = PetFrame
local TargetFrame = TargetFrame
local TargetFrameToT = TargetFrameToT
local FocusFrame = FocusFrame
PartyMemberFrame = {}
local PartyMemberFramePetFrame = {}

for i = 1, MAX_PARTY_MEMBERS do
    PartyMemberFrame[i] = _G["PartyMemberFrame" .. i]

    PartyMemberFramePetFrame[i] = _G["PartyMemberFrame" .. i .. "PetFrame"]
end

local function toggleValue(value, bool)
    if bool == true then
        value = max(value, -(value + 1))
    elseif bool == false then
        value = min(value, -(value + 1))
    elseif bool == nil then
        value = -(value + 1)
    end
    return value
end

local function rgbToHsl(r, g, b, a)
    local max, min = max(r, g, b), min(r, g, b)
    local h, s, l

    l = (max + min) / 2

    if max == min then
        h, s = 0, 0
    else
        local d = max - min

        if l > 0.5 then
            s = d / (2 - max - min)
        else
            s = d / (max + min)
        end

        if max == r then
            h = (g - b) / d

            if g < b then
                h = h + 6
            end
        elseif max == g then
            h = (b - r) / d + 2
        elseif max == b then
            h = (r - g) / d + 4
        end

        h = h / 6
    end

    return h, s, l, a or 1
end

local function hslToRgb(h, s, l, a)
    local r, g, b

    if s == 0 then
        r, g, b = l, l, l
    else
        local function f(p, q, t)
            if t < 0 then
                t = t + 1
            elseif t > 1 then
                t = t - 1
            end

            if t < 1 / 6 then
                return p + (q - p) * 6 * t
            end

            if t < 1 / 2 then
                return q
            end

            if t < 2 / 3 then
                return p + (q - p) * (2 / 3 - t) * 6
            end

            return p
        end

        local q

        if l < 0.5 then
            q = l * (1 + s)
        else
            q = l + s - l * s
        end

        local p = 2 * l - q

        r = f(p, q, h + 1 / 3)
        g = f(p, q, h)
        b = f(p, q, h - 1 / 3)
    end

    return r, g, b, a or 1
end

local function dimColor(x, r, g, b, a)
    local h, s, l = rgbToHsl(r, g, b, a)
    return hslToRgb(h, s, x * l, a)
end

local function gradient(r, g, b, a)
    return r, g, b, a, dimColor(0.667, r, g, b, a)
end

local function complementaryColor(r, g, b, a)
    local h, s, l = rgbToHsl(r, g, b, a)

    if h < 0.333 then
        h = h * 1.5
    else
        h = (h - 0.333) * 0.5 + 0.5
    end

    h = (h + 0.5) % 1

    if h < 0.5 then
        h = h * 0.667
    else
        h = (h - 0.5) * 1.333 + 0.333
    end

    return hslToRgb(h % 1, s, l, a)
end

local function tappend(tbl, ...)
    for i = 1, select("#", ...) do
        local x = select(i, ...)
        tinsert(tbl, x)
    end

    return tbl
end

local ClassicHealPrediction = {}
_G.ClassicHealPrediction = ClassicHealPrediction

local ClassicHealPredictionDefaultSettings = {
    myFilter = toggleValue(HealComm.ALL_HEALS, true),
    otherFilter = toggleValue(HealComm.ALL_HEALS, true),
    myDelta = toggleValue(3, false),
    otherDelta = toggleValue(3, false),
    overhealThreshold = toggleValue(0.2, false),
    overlaying = false,
    colors = {
        {gradient(0.043, 0.533, 0.412, 1.0)},
        {gradient(0.043, 0.533, 0.412, 0.5)},
        {gradient(complementaryColor(0.043, 0.533, 0.412, 1.0))},
        {gradient(complementaryColor(0.043, 0.533, 0.412, 0.5))},
        {gradient(0.082, 0.349, 0.282, 1.0)},
        {gradient(0.082, 0.349, 0.282, 0.5)},
        {gradient(complementaryColor(0.082, 0.349, 0.282, 1.0))},
        {gradient(complementaryColor(0.082, 0.349, 0.282, 0.5))},
        {gradient(0.0, 0.827, 0.765, 1.0)},
        {gradient(0.0, 0.827, 0.765, 0.5)},
        {gradient(complementaryColor(0.0, 0.827, 0.765, 1.0))},
        {gradient(complementaryColor(0.0, 0.827, 0.765, 0.5))},
        {gradient(0.0, 0.631, 0.557, 1.0)},
        {gradient(0.0, 0.631, 0.557, 0.5)},
        {gradient(complementaryColor(0.0, 0.631, 0.557, 1.0))},
        {gradient(complementaryColor(0.0, 0.631, 0.557, 0.5))},
        {gradient(0.0, 0.447, 1.0, 1.0)}
    },
    showManaCostPrediction = true,
    raidFramesMaxOverflow = toggleValue(0.05, true),
    unitFramesMaxOverflow = toggleValue(0.0, true),
    -- Opt-in, not opt-out: attaching heal prediction textures to nameplates can
    -- trigger a Blizzard-side "Can't measure restricted regions" taint error on
    -- Classic Era 1.15.9+, since nameplate auras (new to this patch) share a
    -- frame hierarchy with the health bar this feature attaches to. Defaulting
    -- this off protects existing users who never asked for nameplate heal
    -- prediction from a bug they'd otherwise have no way to know about.
    enableNameplates = false
}
local ClassicHealPredictionSettings = ClassicHealPredictionDefaultSettings

local function getOtherEndTime()
    local delta = ClassicHealPredictionSettings.otherDelta

    if delta >= 0 then
        return GetTime() + delta
    end

    return nil
end

local function getChild(frame, ...)
    if not frame or type(frame.GetChildren) ~= "function" then
        return frame
    end

    local path = {...}

    for step, index in ipairs(path) do
        local children = { frame:GetChildren() }

        if not children[index] then
            return frame
        end

        frame = children[index]
    end

    return frame
end

local function getTexture(frame, name)
    while not frame:GetName() do
        frame = frame:GetParent()
    end

    name = name and string.gsub(name, "%$parent", frame:GetName())
    return name and _G[name]
end

local function createTexture(frame, name, layer, subLayer)
    return getTexture(frame, name) or frame:CreateTexture(name, layer, nil, subLayer)
end

-- ORIGINAL: Added two helper functions, they didn't exist before; every caller below used to
-- call :ClearAllPoints()/:SetTexture()/:SetVertexColor() directly on the bar.
-- Some bar regions this addon expects to be plain Textures (identified by name,
-- e.g. "$parentMyHealPredictionBar") now resolve, via getTexture() above, to
-- Blizzard's own native generic StatusBarOverlaySegmentMixin-based frames instead (also impemented
-- for PlayerFrame/PetFrame in the shared Retail/Classic UI codebase).
-- Blizzard's own source comment on `Shared/StatusBarOverlaySegment.lua`:
-- "A segment of fill that displays on top of a status bar. Ex: Heal prediction bar,
-- which displays on top of a unit's health bar."
-- Blizzard has now standardized overlay bars into a shared widget type used by both their
-- own native heal-prediction and, as a side effect, by anything else that resolves to one of
-- these objects by name
-- Scope: we are now able to resolve to blizzard overlays in Individual unit frames (PlayerFrame,
-- PetFrame, TargetFrame, party-member frames) within this addon's 2-tier system of heal/overheal,
-- heal absorb and total absorb
-- For Compact/raid frames and nameplates Blizzard's API seems to provide nothing, so we still
-- have to manipulate self-created textures
local function setFillTexture(texture, path)
    if texture.SetTexture then
        texture:ClearAllPoints()
        texture:SetTexture(path)
    end
end

local function setFillVertexColor(texture, r, g, b, a)
    if texture.SetVertexColor then
        texture:SetVertexColor(r, g, b, a)
    elseif texture.Fill then
        texture.Fill:SetVertexColor(r, g, b, a)
    end
end

local function deepcopy(orig)
    local orig_type = type(orig)
    local copy

    if orig_type == "table" then
        copy = {}

        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end

        setmetatable(copy, deepcopy(getmetatable(orig)))
    else
        copy = orig
    end

    return copy
end

local function deepmerge(tbl1, tbl2)
    for k, v in pairs(tbl2) do
        if tbl1[k] == nil then
            if type(v) == "table" then
                tbl1[k] = {}
                deepmerge(tbl1[k], v)
            else
                tbl1[k] = v
            end
        end
    end
end

local weaktable = {__mode = "k"}
local healthBar = setmetatable({}, weaktable)
-- ORIGINAL 
-- myHealPrediction[someFrame] is the myHealPrediction bar belonging to some frame
local myHealPrediction = setmetatable({}, weaktable)
-- table that maps frame -> textures for my overheals (it's like a 2-tier bar system with heals and overheals)
local myHealPrediction2 = setmetatable({}, weaktable)
-- table that maps frame -> textures for others' heals
local otherHealPrediction = setmetatable({}, weaktable)
-- these are again the overheal bars or textures for others in the 2-tier bar/texture system (these are all dicts in case you didn't notice)
local otherHealPrediction2 = setmetatable({}, weaktable)
local healAbsorb = setmetatable({}, weaktable)
local overHealAbsorbGlow = setmetatable({}, weaktable)
local overAbsorbGlow = setmetatable({}, weaktable)
local healAbsorbRightShadow = setmetatable({}, weaktable)
local healAbsorbLeftShadow = setmetatable({}, weaktable)
local totalAbsorb = setmetatable({}, weaktable)
local totalAbsorbOverlay = setmetatable({}, weaktable)
local setGradient = setmetatable({}, weaktable)
local proxyFrame = setmetatable({}, weaktable)
local currUnitGUID = setmetatable({}, weaktable)

local tickIntervals

local guidToUnitFrame = {}
local guidToCompactUnitFrame = {}
local guidToNameplateFrame = {}

local lastFrameTime = -1
local deferredUnitFrames = {}
local deferredCompactUnitFrames = {}

local loadedSettings = false
local loadedFrame = false
local checkBoxes
local checkBox2
local checkBox3
local checkBox4
local slider
local slider2
local slider3
local slider4
local sliderCheckBox
local sliderCheckBox2
local sliderCheckBox3
local sliderCheckBox4
local colorSwatches = {}

local function getIncomingHeals(unit)
    if not unit or not UnitCanAssist("player", unit) then
        return 0, 0, 0, 0
    end

    local dstGUID = UnitGUID(unit)
    local dstBitFlag = ClassicHealPredictionSettings.otherFilter
    local dstTime = getOtherEndTime()
    local srcGUID = UnitGUID("player")
    local srcBitFlag = HealComm.ALL_HEALS
    local srcTime = nil

    local modifier = HealComm:GetHealModifier(dstGUID) or 1.0
    local dstAmount1, dstAmount2, srcAmount1, srcAmount2 = HealComm:GetHealAmountEx(dstGUID, dstBitFlag, dstTime, srcGUID, srcBitFlag, srcTime)

    return (srcAmount1 or 0) * modifier, (srcAmount2 or 0) * modifier, (dstAmount1 or 0) * modifier, (dstAmount2 or 0) * modifier
end

local function updateHealPrediction(frame, unit, cutoff, gradient, colorPalette, colorPalette2, updateFillBar)
    if not myHealPrediction[frame] then
        return
    end

    local _, maxHealth = healthBar[frame]:GetMinMaxValues()
    local health = healthBar[frame]:GetValue()
    local myIncomingHeal1, myIncomingHeal2, otherIncomingHeal1, otherIncomingHeal2 = getIncomingHeals(unit)
    local currentTotalAbsorb = 0
    local currentHealAbsorb = 0

    local healAbsorb = healAbsorb[frame]

    if healAbsorb then
        currentHealAbsorb = 0

        -- ORIGINAL: unconditional overHealAbsorbGlow[frame]:Show()/Hide(), no guard.
        -- Default party member frames set healAbsorb[frame] (memberHealthBar.HealAbsorbBar
        -- exists) but memberHealthBar.OverHealAbsorbGlow does not - initPartyMemberFrame's
        -- own "if memberHealthBar.OverHealAbsorbGlow then" guard already anticipates this,
        -- but left overHealAbsorbGlow[frame] nil for that frame, which crashed here since
        -- this code always assumed it would be set whenever healAbsorb[frame] was.
        if overHealAbsorbGlow[frame] then
            if health < currentHealAbsorb then
                overHealAbsorbGlow[frame]:Show()
                currentHealAbsorb = health
            else
                overHealAbsorbGlow[frame]:Hide()
            end
        end
    end

    local overhealing = maxHealth <= 0 and 0 or max((health - currentHealAbsorb + myIncomingHeal1 + otherIncomingHeal1) / maxHealth - 1, 0)

    do
        local overhealThreshold = ClassicHealPredictionSettings.overhealThreshold

        if overhealThreshold >= 0 and overhealing > overhealThreshold then
            colorPalette = colorPalette2
        end
    end

    local colors = ClassicHealPredictionSettings.colors
	-- Normal incoming heals, either a native Blizzard overlay segment (for Player, Pet, Target,
    -- party-member frames ) or a plain self-drawn (i.e. by this addon) texture (for compact/raid frames
    --  and nameplates)
    local myHealPrediction1 = myHealPrediction[frame]
	-- Incoming overheals (in a different color?)
    local myHealPrediction2 = myHealPrediction2[frame]
    -- The same as above other the heals and overheals of others
    local otherHealPrediction1 = otherHealPrediction[frame]
    local otherHealPrediction2 = otherHealPrediction2[frame]

    if gradient then
		-- This concerns Raid and compact party frames (raid style party frames) and player pet frames
        local r, g, b, a, r2, g2, b2

        r, g, b, a, r2, g2, b2 = unpack(colors[colorPalette[1]])

        if a == 0 then
            myIncomingHeal1 = 0
        else
            -- myHealPrediction1's name (assigned via createTexture's $parent
            -- naming, see the getTexture/createTexture comment above) collides
            -- with a native Blizzard texture on some frame types, which has
            -- its own non-white base color. SetGradient/SetVertexColor
            -- multiply against that base, so without resetting it to white
            -- first, any color set here comes out tinted/blackened.
            if myHealPrediction1.SetColorTexture then
                myHealPrediction1:SetColorTexture(1, 1, 1)
            end
            setFillVertexColor(myHealPrediction1, r, g, b, a)
        end

        r, g, b, a, r2, g2, b2 = unpack(colors[colorPalette[2]])

        if a == 0 then
            myIncomingHeal2 = 0
        else
            setFillVertexColor(myHealPrediction2, r, g, b, a)
        end

        r, g, b, a, r2, g2, b2 = unpack(colors[colorPalette[3]])

        if a == 0 then
            otherIncomingHeal1 = 0
        else
            -- Same base-texture-collision fix as myHealPrediction1 above.
            if otherHealPrediction1.SetColorTexture then
                otherHealPrediction1:SetColorTexture(1, 1, 1)
            end
            setFillVertexColor(otherHealPrediction1, r, g, b, a)
        end

        r, g, b, a, r2, g2, b2 = unpack(colors[colorPalette[4]])

        if a == 0 then
            otherIncomingHeal2 = 0
        else
            setFillVertexColor(otherHealPrediction2, r, g, b, a)
        end
    else
		-- ... gradient is false: player/target/pet frame/party frames (non raid style) and name plates
        -- ORIGINAL: these 4 branches called myHealPrediction1:SetVertexColor(...),
        -- myHealPrediction2:SetVertexColor(...), otherHealPrediction1:SetVertexColor(...),
        -- otherHealPrediction2:SetVertexColor(...) directly. On PlayerFrame/PetFrame/
        -- party/target frames.
        -- myHealPrediction1/otherHealPrediction1 are now Blizzard's StatusBarOverlaySegment
        -- objects (see setFillVertexColor above) which have no SetVertexColor of their
        -- own, so those two calls threw "attempt to call a nil value". myHealPrediction2/
        -- otherHealPrediction2 (the addon's own "2" overflow-color bars) have no Blizzard
        -- name collision and remain plain Textures, so those two calls were already fine
        local r, g, b, a

        r, g, b, a = unpack(colors[colorPalette[1]])

        if a == 0 then
            myIncomingHeal1 = 0
        else
            setFillVertexColor(myHealPrediction1, r, g, b, a)
        end

        r, g, b, a = unpack(colors[colorPalette[2]])

        if a == 0 then
            myIncomingHeal2 = 0
        else
            setFillVertexColor(myHealPrediction2, r, g, b, a)
        end

        r, g, b, a = unpack(colors[colorPalette[3]])

        if a == 0 then
            otherIncomingHeal1 = 0
        else
            setFillVertexColor(otherHealPrediction1, r, g, b, a)
        end

        r, g, b, a = unpack(colors[colorPalette[4]])

        if a == 0 then
            otherIncomingHeal2 = 0
        else
            setFillVertexColor(otherHealPrediction2, r, g, b, a)
        end
    end

    local incomingHeal1
    local incomingHeal2

    if ClassicHealPredictionSettings.overlaying then
        incomingHeal1 = max(myIncomingHeal1, otherIncomingHeal1)
        incomingHeal2 = max(myIncomingHeal2, otherIncomingHeal2)
    else
        incomingHeal1 = myIncomingHeal1 + otherIncomingHeal1
        incomingHeal2 = myIncomingHeal2 + otherIncomingHeal2
    end

    local allIncomingHeal = incomingHeal1 + incomingHeal2

    if cutoff then
        allIncomingHeal = min(allIncomingHeal, maxHealth * cutoff - health + currentHealAbsorb)
    end

    incomingHeal1 = min(incomingHeal1, allIncomingHeal)
    incomingHeal2 = allIncomingHeal - incomingHeal1

    myIncomingHeal1 = min(myIncomingHeal1, incomingHeal1)
    myIncomingHeal2 = min(myIncomingHeal2, incomingHeal2)

    otherIncomingHeal1 = incomingHeal1 - myIncomingHeal1
    otherIncomingHeal2 = incomingHeal2 - myIncomingHeal2

    local overAbsorb = false

    if health - currentHealAbsorb + allIncomingHeal + currentTotalAbsorb >= maxHealth or health + currentTotalAbsorb >= maxHealth then
        if currentTotalAbsorb > 0 then
            overAbsorb = true
        end

        if allIncomingHeal > currentHealAbsorb then
            currentTotalAbsorb = max(0, maxHealth - (health - currentHealAbsorb + allIncomingHeal))
        else
            currentTotalAbsorb = max(0, maxHealth - health)
        end
    end

    -- ORIGINAL: unconditional overAbsorbGlow[frame]:Show()/Hide(), no guard - same
    -- rationale as overHealAbsorbGlow above (default party frames may not have
    -- memberHealthBar.OverAbsorbGlow, per initPartyMemberFrame's own guard).
    if overAbsorbGlow[frame] then
        if overAbsorb then
            overAbsorbGlow[frame]:Show()
        else
            overAbsorbGlow[frame]:Hide()
        end
    end

    local healthTexture = healthBar[frame]:GetStatusBarTexture()
    local currentHealAbsorbPercent = 0
    local healAbsorbTexture

    if healAbsorb then
        currentHealAbsorbPercent = maxHealth <= 0 and 0 or currentHealAbsorb / maxHealth

        local healAbsorbLeftShadow = healAbsorbLeftShadow[frame]
        local healAbsorbRightShadow = healAbsorbRightShadow[frame]

        if currentHealAbsorb > allIncomingHeal then
            local shownHealAbsorb = currentHealAbsorb - allIncomingHeal
            local shownHealAbsorbPercent = maxHealth <= 0 and 0 or shownHealAbsorb / maxHealth

            healAbsorbTexture = updateFillBar(frame, healthTexture, healAbsorb, shownHealAbsorb, -shownHealAbsorbPercent)

            if allIncomingHeal > 0 then
                healAbsorbLeftShadow:Hide()
            else
                healAbsorbLeftShadow:SetPoint("TOPLEFT", healAbsorbTexture, "TOPLEFT", 0, 0)
                healAbsorbLeftShadow:SetPoint("BOTTOMLEFT", healAbsorbTexture, "BOTTOMLEFT", 0, 0)
                healAbsorbLeftShadow:Show()
            end

            if currentTotalAbsorb > 0 then
                healAbsorbRightShadow:SetPoint("TOPLEFT", healAbsorbTexture, "TOPRIGHT", -8, 0)
                healAbsorbRightShadow:SetPoint("BOTTOMLEFT", healAbsorbTexture, "BOTTOMRIGHT", -8, 0)
                healAbsorbRightShadow:Show()
            else
                healAbsorbRightShadow:Hide()
            end
        else
            healAbsorb:Hide()
            healAbsorbLeftShadow:Hide()
            healAbsorbRightShadow:Hide()
        end
    end

    local incomingHealsTexture = updateFillBar(frame, healthTexture, myHealPrediction1, myIncomingHeal1, -currentHealAbsorbPercent)
    incomingHealsTexture = updateFillBar(frame, incomingHealsTexture, otherHealPrediction1, otherIncomingHeal1)
    incomingHealsTexture = updateFillBar(frame, incomingHealsTexture, myHealPrediction2, myIncomingHeal2)
    incomingHealsTexture = updateFillBar(frame, incomingHealsTexture, otherHealPrediction2, otherIncomingHeal2)

    local appendTexture = healAbsorbTexture or incomingHealsTexture
    updateFillBar(frame, appendTexture, totalAbsorb[frame], currentTotalAbsorb)
end

local CompactUnitFrame_UpdateHealPrediction
local UnitFrameHealPredictionBars_Update

-- ORIGINAL: this function did not exist; UnitFrameHealPredictionBars_Update
-- (below) passed the bare global UnitFrameUtil_UpdateFillBar directly as its
-- updateFillBar callback instead of unitFrameHealPredictionBar_UpdateFillPosition.
-- On PlayerFrame/PetFrame/TargetFrame etc. (unlike CompactUnitFrame-style raid/party
-- frames, which still use plain Textures here), the individual heal-prediction bars
-- are now Blizzard's own StatusBarOverlaySegmentMixin-based frames, positioned via
-- :UpdateFillPosition() instead of manual SetPoint/SetWidth. We can't confirm
-- Blizzard's own UnitFrameUtil_UpdateFillBar still exists or still supports the old
-- calling convention, so this reimplements its contract directly: dispatch to
-- UpdateFillPosition when available, otherwise fall back to the same manual
-- positioning Blizzard's (confirmed still current) CompactUnitFrameUtil_UpdateFillBar
-- uses, in case a given bar is still a plain Texture.
local function unitFrameHealPredictionBar_UpdateFillPosition(frame, previousTexture, bar, amount, barOffsetXPercent)
    if bar.UpdateFillPosition then
        local result = bar:UpdateFillPosition(previousTexture, amount, barOffsetXPercent)
        return result
    end

    local totalWidth = healthBar[frame]:GetWidth()

    if totalWidth == 0 or amount == 0 then
        bar:Hide()

        if bar.overlay then
            bar.overlay:Hide()
        end

        return previousTexture
    end

    local barOffsetX = barOffsetXPercent and totalWidth * barOffsetXPercent or 0

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", previousTexture, "TOPRIGHT", barOffsetX, 0)
    bar:SetPoint("BOTTOMLEFT", previousTexture, "BOTTOMRIGHT", barOffsetX, 0)

    local _, totalMax = healthBar[frame]:GetMinMaxValues()
    local barSize = (amount / totalMax) * totalWidth

    bar:SetWidth(barSize)
    bar:Show()

    if bar.overlay then
        bar.overlay:Show()
    end

    return bar
end

do
    local compactUnitFrameColorPalette = {1, 2, 5, 6}
    local compactUnitFrameColorPalette2 = {3, 4, 7, 8}
    local unitFrameColorPalette = {9, 10, 13, 14}
    local unitFrameColorPalette2 = {11, 12, 15, 16}

    function CompactUnitFrame_UpdateHealPrediction(frame)
        local cutoff
        local maxOverflow = ClassicHealPredictionSettings.raidFramesMaxOverflow

        if maxOverflow >= 0 then
            cutoff = 1.0 + maxOverflow
        end

        updateHealPrediction(frame, frame.displayedUnit, cutoff, setGradient[frame], compactUnitFrameColorPalette, compactUnitFrameColorPalette2, CompactUnitFrameUtil_UpdateFillBar)
    end

    function UnitFrameHealPredictionBars_Update(frame)
        local cutoff
        local maxOverflow = ClassicHealPredictionSettings.unitFramesMaxOverflow

        if maxOverflow >= 0 then
            cutoff = 1.0 + maxOverflow
        end

        -- ORIGINAL: updateHealPrediction(..., UnitFrameUtil_UpdateFillBar) - see the
        -- unitFrameHealPredictionBar_UpdateFillPosition comment above for why.
        updateHealPrediction(frame, frame.unit, cutoff, false, unitFrameColorPalette, unitFrameColorPalette2, unitFrameHealPredictionBar_UpdateFillPosition)
    end
end

local function defer_CompactUnitFrame_UpdateHealPrediction(frame)
    if GetTime() > lastFrameTime then
        deferredCompactUnitFrames[frame] = true
    else
        CompactUnitFrame_UpdateHealPrediction(frame)
    end
end

local function defer_UnitFrameHealPredictionBars_Update(frame)
    if GetTime() > lastFrameTime then
        deferredUnitFrames[frame] = true
    else
        UnitFrameHealPredictionBars_Update(frame)
    end
end

-- ORIGINAL: this function did not exist; unitFrameManaCostPredictionBars_Update
-- below called frame.myManaCostPredictionBar:SetVertexColor(...) directly and
-- passed the bare global UnitFrameUtil_UpdateManaFillBar as the fill-position call.
-- Mirrors unitFrameHealPredictionBar_UpdateFillPosition above for the mana-cost
-- prediction bar: dispatch to UpdateFillPosition when the bar is Blizzard's new
-- StatusBarOverlaySegment type, otherwise fall back to the same manual anchoring
-- pattern (anchored off the mana bar's current fill edge, no X offset needed since
-- there is only ever one segment here).
local function unitFrameManaCostPredictionBar_UpdateFillPosition(frame, previousTexture, bar, amount)
    if bar.UpdateFillPosition then
        return bar:UpdateFillPosition(previousTexture, amount)
    end

    local totalWidth = frame.manabar:GetWidth()

    if totalWidth == 0 or amount == 0 then
        bar:Hide()
        return
    end

    local _, totalMax = frame.manabar:GetMinMaxValues()
    local barSize = (amount / totalMax) * totalWidth

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", previousTexture, "TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", previousTexture, "BOTTOMRIGHT", 0, 0)
    bar:SetWidth(barSize)
    bar:Show()
end

local function unitFrameManaCostPredictionBars_Update(frame, isStarting, startTime, endTime, spellID)
    if frame.unit ~= "player" or not frame.manabar or not frame.myManaCostPredictionBar then
        return
    end

    if not ClassicHealPredictionSettings.showManaCostPrediction then
        frame.myManaCostPredictionBar:Hide()
        return
    end

    local cost = 0

    if not isStarting or startTime == endTime then
        local currentSpellID = select(9, CastingInfo())

        if currentSpellID and frame.predictedPowerCost then
            cost = frame.predictedPowerCost
        else
            frame.predictedPowerCost = nil
        end
    else
        local costTable = GetSpellPowerCost(spellID)

        for _, costInfo in pairs(costTable) do
            if costInfo.type == frame.manabar.powerType then
                cost = costInfo.cost
                break
            end
        end

        frame.predictedPowerCost = cost
    end

    local manaBarTexture = frame.manabar:GetStatusBarTexture()

    -- ORIGINAL:
    -- local r, g, b, a = unpack(ClassicHealPredictionSettings.colors[17])
    -- frame.myManaCostPredictionBar:SetVertexColor(r, g, b, a)
    --
    -- UnitFrameManaBar_Update(frame.manabar, "player")
    -- UnitFrameUtil_UpdateManaFillBar(frame, manaBarTexture, frame.myManaCostPredictionBar, cost)
    local r, g, b, a = unpack(ClassicHealPredictionSettings.colors[17])
    setFillVertexColor(frame.myManaCostPredictionBar, r, g, b, a)

    UnitFrameManaBar_Update(frame.manabar, "player")

    unitFrameManaCostPredictionBar_UpdateFillPosition(frame, manaBarTexture, frame.myManaCostPredictionBar, cost)
end

local function UnitFrameHealPredictionBars_UpdateSize(self)
    if not myHealPrediction[self] or not otherHealPrediction[self] then
        return
    end

    defer_UnitFrameHealPredictionBars_Update(self)
end

-- ORIGINAL (pre shared Retail/Classic UI codebase rewrite): unregistered UNIT_HEALTH
-- on every compact frame right after Blizzard registered it. Traced via upstream
-- ClassicHealPrediction history to leftover code from a removed 2019 "animated
-- health-loss bar" feature - harmless for years since the old client treated
-- UNIT_HEALTH and UNIT_HEALTH_FREQUENT as interchangeable refresh triggers, so
-- this addon's own UNIT_HEALTH_FREQUENT-driven refresh (below) covered for it.
-- 1.15.9 narrowed that: CompactUnitFrame_SetHealthDirty (the real health value
-- redraw) now only fires from UNIT_HEALTH, while SetHealPredictionDirty still
-- fires from both (confirmed via diagnostic logging) - so this stale unregister
-- call silently cut off the real health bar while prediction kept working,
-- matching the exact symptom reported. Disabled.
--
-- hooksecurefunc(
--     "CompactUnitFrame_UpdateUnitEvents",
--     function(frame)
--         if not frame:IsForbidden() then
--             frame:UnregisterEvent("UNIT_HEALTH")
--         end
--     end
-- )

hooksecurefunc(
    "CompactUnitFrame_OnEvent",
    function(self, event, ...)
        if event == self.updateAllEvent and (not self.updateAllFilter or self.updateAllFilter(self, event, ...)) then
            return
        end

        local unit = ...

        if unit == self.unit or unit == self.displayedUnit then
            if event == "UNIT_HEALTH_FREQUENT" or event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
                defer_CompactUnitFrame_UpdateHealPrediction(self)
            end
        end
    end
)

local function compactUnitFrame_UpdateAll(frame)
    local unit = frame.displayedUnit

    do
        local unitGUID = currUnitGUID[frame]
        local newUnitGUID = unit and UnitGUID(unit)

        if newUnitGUID ~= unitGUID then
            if unitGUID then
                guidToCompactUnitFrame[unitGUID][frame] = nil

                if next(guidToCompactUnitFrame[unitGUID]) == nil then
                    guidToCompactUnitFrame[unitGUID] = nil
                end
            end

            if newUnitGUID then
                guidToCompactUnitFrame[newUnitGUID] = guidToCompactUnitFrame[newUnitGUID] or {}
                guidToCompactUnitFrame[newUnitGUID][frame] = true
            end

            currUnitGUID[frame] = newUnitGUID
        end
    end

    defer_CompactUnitFrame_UpdateHealPrediction(frame)
end

hooksecurefunc("CompactUnitFrame_UpdateAll", compactUnitFrame_UpdateAll)

hooksecurefunc("CompactUnitFrame_UpdateHealth", defer_CompactUnitFrame_UpdateHealPrediction)

hooksecurefunc("CompactUnitFrame_UpdateMaxHealth", defer_CompactUnitFrame_UpdateHealPrediction)

-- ORIGINAL: this hook did not exist.
-- Belt-and-suspenders fix for the same symptom as the UNIT_HEALTH UnregisterEvent
-- hook below (see "ORIGINAL (pre shared Retail/Classic UI codebase rewrite)" further down): with
-- UNIT_HEALTH unregistered on compact frames, CompactUnitFrame_SetHealthDirty
-- never fired on plain damage/healing while CompactUnitFrame_SetHealPredictionDirty
-- kept firing reliably (confirmed via diagnostic logging), so the health bar's
-- value never refreshed while heal prediction kept working - matching the exact
-- symptom reported. Piggyback the missing call onto the one that does fire
-- reliably. Now that the actual UnregisterEvent("UNIT_HEALTH") call has been
-- disabled, Blizzard's own SetHealthDirty call should fire on its own again,
-- making this redundant (but harmless - the flag is idempotent) unless something
-- else is still suppressing it.
if CompactUnitFrame_SetHealPredictionDirty and CompactUnitFrame_SetHealthDirty then
    hooksecurefunc("CompactUnitFrame_SetHealPredictionDirty", function(frame)
        CompactUnitFrame_SetHealthDirty(frame)
    end)
end

-- ORIGINAL: this function did not exist. Party member frames (the "old default",
-- non-raid-style party display, PartyMemberFrameTemplate) are a new gap uncovered
-- after the fact: initUnitFrame's global-name-based createTexture/getChild lookup
-- doesn't work here at all, since these frames come from a frame pool and are
-- unnamed - every party member slot shares the same nearest-named-ancestor
-- (PartyFrame), so createTexture's "$parent"-substituted global name would
-- collide across all 4 slots for anything that has to be created fresh (the "2"
-- tier bars, shadow/glow textures). Unlike initUnitFrame, this populates the
-- heal-prediction tables directly from Blizzard's real child objects (confirmed
-- via PartyFrameTemplates.xml: HealthBarContainer.HealthBar.MyHealPredictionBar/
-- OtherHealPredictionBar/HealAbsorbBar/TotalAbsorbBar are the same
-- StatusBarOverlaySegment-based bars PlayerFrame uses), and only creates new
-- (anonymously-named, collision-free) textures for the parts Blizzard doesn't
-- provide natively. Hooked from unitFrame_Update below rather than needing a new
-- hook, since UnitFrame_SetUnit (already hooked into unitFrame_Update) already
-- fires for these frames on its own. Party member pet mini-icons are not covered -
-- Blizzard's PartyMemberPetFrameTemplate has no equivalent bar structure at all,
-- so supporting those would mean building everything from scratch; deferred.
local function initPartyMemberFrame(frame)
    -- ORIGINAL: this guard checked "frame.HealthBarContainer and
    -- frame.HealthBarContainer.HealthBar" - based on reference-repo research that
    -- turned out not to match the live default party frame structure. Diagnostic
    -- logging confirmed frame.HealthBarContainer is nil on the real frame, and the
    -- health bar is actually frame.healthbar directly (the same lowercase, flat
    -- convention this file already uses for Player/Pet/Target frames), with
    -- MyHealPredictionBar etc. as direct children of that.
    if not frame or myHealPrediction[frame] or not frame.healthbar then
        return
    end

    local memberHealthBar = frame.healthbar

    if not (memberHealthBar.MyHealPredictionBar and memberHealthBar.OtherHealPredictionBar
        and memberHealthBar.HealAbsorbBar and memberHealthBar.TotalAbsorbBar) then
        return
    end

    healthBar[frame] = memberHealthBar
    myHealPrediction[frame] = memberHealthBar.MyHealPredictionBar
    otherHealPrediction[frame] = memberHealthBar.OtherHealPredictionBar
    healAbsorb[frame] = memberHealthBar.HealAbsorbBar
    totalAbsorb[frame] = memberHealthBar.TotalAbsorbBar

    -- No Blizzard-native equivalent for these; create our own the same
    -- collision-free (nil-named) way defaultCompactUnitFrameSetup/
    -- namePlateApplyFrameOptions already do for their own pooled/unnamed frames.
    myHealPrediction2[frame] = createTexture(memberHealthBar, nil, "BORDER", 5)
    setFillTexture(myHealPrediction2[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

    otherHealPrediction2[frame] = createTexture(memberHealthBar, nil, "BORDER", 5)
    setFillTexture(otherHealPrediction2[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

    healAbsorbLeftShadow[frame] = createTexture(memberHealthBar, nil, "ARTWORK", 1)
    setFillTexture(healAbsorbLeftShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")

    healAbsorbRightShadow[frame] = createTexture(memberHealthBar, nil, "ARTWORK", 1)
    setFillTexture(healAbsorbRightShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")
    healAbsorbRightShadow[frame]:SetTexCoord(1, 0, 0, 1)

    -- OverAbsorbGlow/OverHealAbsorbGlow ARE provided natively here (confirmed
    -- plain Textures, same OverAbsorbGlowTemplate/OverHealAbsorbGlowTemplate as
    -- PlayerFrame) - direct field access is safe (per-instance, not name-based),
    -- so reuse Blizzard's objects and restyle them the same way initUnitFrame does.
    if memberHealthBar.OverAbsorbGlow then
        overAbsorbGlow[frame] = memberHealthBar.OverAbsorbGlow
        overAbsorbGlow[frame]:ClearAllPoints()
        overAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
        overAbsorbGlow[frame]:SetBlendMode("ADD")
        overAbsorbGlow[frame]:SetPoint("BOTTOMLEFT", memberHealthBar, "BOTTOMRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetPoint("TOPLEFT", memberHealthBar, "TOPRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - restyling a reused Blizzard object is not
        -- guaranteed to leave it in a hidden state, so force it, same rationale as
        -- the freshly created textures elsewhere.
        overAbsorbGlow[frame]:Hide()
    end

    if memberHealthBar.OverHealAbsorbGlow then
        overHealAbsorbGlow[frame] = memberHealthBar.OverHealAbsorbGlow
        overHealAbsorbGlow[frame]:ClearAllPoints()
        overHealAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Overabsorb")
        overHealAbsorbGlow[frame]:SetBlendMode("ADD")
        overHealAbsorbGlow[frame]:SetPoint("BOTTOMRIGHT", memberHealthBar, "BOTTOMLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetPoint("TOPRIGHT", memberHealthBar, "TOPLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - same rationale as overAbsorbGlow above.
        overHealAbsorbGlow[frame]:Hide()
    end
end

local function unitFrame_Update(self)
    initPartyMemberFrame(self)

    do
        local unit = self.unit
        local unitGUID = currUnitGUID[self]
        local newUnitGUID = unit and UnitGUID(unit)

        if newUnitGUID ~= unitGUID then
            if unitGUID then
                guidToUnitFrame[unitGUID][self] = nil

                if next(guidToUnitFrame[unitGUID]) == nil then
                    guidToUnitFrame[unitGUID] = nil
                end
            end

            if newUnitGUID then
                guidToUnitFrame[newUnitGUID] = guidToUnitFrame[newUnitGUID] or {}
                guidToUnitFrame[newUnitGUID][self] = true
            end

            currUnitGUID[self] = newUnitGUID
        end
    end

    defer_UnitFrameHealPredictionBars_Update(self)
    unitFrameManaCostPredictionBars_Update(self)
end

hooksecurefunc("UnitFrame_SetUnit", unitFrame_Update)

hooksecurefunc("UnitFrame_Update", unitFrame_Update)

local function unitFrame_OnEvent(self, event, unit)
    if unit == self.unit then
        if event == "UNIT_MAXHEALTH" then
            defer_UnitFrameHealPredictionBars_Update(self)
        elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            assert(unit == "player")
            local name, text, texture, startTime, endTime, isTradeSkill, castID, notInterruptible, spellID = CastingInfo()
            unitFrameManaCostPredictionBars_Update(self, event == "UNIT_SPELLCAST_START", startTime, endTime, spellID)
        end
    end
end

hooksecurefunc("UnitFrame_OnEvent", unitFrame_OnEvent)

hooksecurefunc(
    "UnitFrameHealthBar_OnUpdate",
    function(self)
        if not self.disconnected and not self.lockValues then
            if not self.ignoreNoUnit or UnitGUID(self.unit) then
                local parent = self:GetParent()
                -- ORIGINAL: this call did not exist. unitFrame_Update (which calls
                -- initPartyMemberFrame) never actually fires for default party member
                -- frames in the shared Retail/Classic UI codebase - only this lower-level
                -- health-bar-specific hook reliably does - so setup is invoked from here
                -- too. initPartyMemberFrame no-ops immediately once already set up, so
                -- this is safe to call on every tick.
                initPartyMemberFrame(parent)
                defer_UnitFrameHealPredictionBars_Update(parent)
            end
        end
    end
)

hooksecurefunc(
    "UnitFrameHealthBar_Update",
    function(statusbar, unit)
        if not statusbar or statusbar.lockValues then
            return
        end

        local parent = statusbar:GetParent()
        -- ORIGINAL: this call did not exist - see the matching comment on
        -- UnitFrameHealthBar_OnUpdate's hook above for why.
        initPartyMemberFrame(parent)
        defer_UnitFrameHealPredictionBars_Update(parent)
    end
)

local function UpdateHealPrediction(...)
    for j = 1, select("#", ...) do
        local unitGUID = select(j, ...)

        do
            local unitFrames = guidToUnitFrame[unitGUID]

            if unitFrames then
                for unitFrame in pairs(unitFrames) do
                    defer_UnitFrameHealPredictionBars_Update(unitFrame)
                end
            end
        end

        do
            local compactUnitFrames = guidToCompactUnitFrame[unitGUID]

            if compactUnitFrames then
                for compactUnitFrame in pairs(compactUnitFrames) do
                    defer_CompactUnitFrame_UpdateHealPrediction(compactUnitFrame)
                end
            end
        end

        do
            local namePlateFrame = guidToNameplateFrame[unitGUID]

            if namePlateFrame then
                defer_CompactUnitFrame_UpdateHealPrediction(namePlateFrame)
            end
        end
    end
end

local function updateAllFrames()
    do
        local allUnitFrames = {}

        for _, unitFrames in pairs(guidToUnitFrame) do
            if unitFrames then
                for unitFrame in pairs(unitFrames) do
                    allUnitFrames[unitFrame] = true
                end
            end
        end

        for unitFrame in pairs(allUnitFrames) do
            local isParty = unitFrame:GetID() ~= 0
            unitFrame_Update(unitFrame, isParty)
        end
    end

    do
        local allCompactUnitFrames = {}

        for _, compactUnitFrames in pairs(guidToCompactUnitFrame) do
            if compactUnitFrames then
                for compactUnitFrame in pairs(compactUnitFrames) do
                    allCompactUnitFrames[compactUnitFrame] = true
                end
            end
        end

        for compactUnitFrame in pairs(allCompactUnitFrames) do
            compactUnitFrame_UpdateAll(compactUnitFrame)
        end
    end

    do
        local allNameplateFrames = {}

        for _, namePlateFrame in pairs(guidToNameplateFrame) do
            allNameplateFrames[namePlateFrame] = namePlateFrame
        end

        for namePlateFrame in pairs(allNameplateFrames) do
            compactUnitFrame_UpdateAll(namePlateFrame)
        end
    end
end

local function ClassicHealPrediction_OnEvent(event, arg1)
    if event == "GROUP_ROSTER_UPDATE" then
        if InCombatLockdown() then
            for _, compactUnitFrames in pairs(guidToCompactUnitFrame) do
                if compactUnitFrames then
                    for compactUnitFrame in pairs(compactUnitFrames) do
                        defer_CompactUnitFrame_UpdateHealPrediction(compactUnitFrame)
                    end
                end
            end
        end
    else
        local namePlateUnitToken = arg1

        if not UnitCanAssist("player", namePlateUnitToken) then
            return
        end

        local unitGUID = UnitGUID(namePlateUnitToken)

        if event == "NAME_PLATE_UNIT_ADDED" then
            local namePlate = C_NamePlate.GetNamePlateForUnit(namePlateUnitToken)
            local namePlateFrame = namePlate and namePlate.UnitFrame
            guidToNameplateFrame[unitGUID] = namePlateFrame

            if namePlateFrame then
                defer_CompactUnitFrame_UpdateHealPrediction(namePlateFrame)
            end
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            guidToNameplateFrame[unitGUID] = nil
        end
    end
end

local function ClassicHealPrediction_OnUpdate()
    for unitFrame in pairs(deferredUnitFrames) do
        UnitFrameHealPredictionBars_Update(unitFrame)
    end

    for compactUnitFrame in pairs(deferredCompactUnitFrames) do
        CompactUnitFrame_UpdateHealPrediction(compactUnitFrame)
    end

    wipe(deferredUnitFrames)
    wipe(deferredCompactUnitFrames)

    lastFrameTime = GetTime()
end

do
    local function defaultCompactUnitFrameSetup(frame)
        if frame:IsForbidden() or myHealPrediction[frame] then
            return
        end

        setGradient[frame] = true
        healthBar[frame] = frame.healthBar

        myHealPrediction[frame] = createTexture(frame, "$parentMyHealPrediction", "BORDER", 5)
        myHealPrediction[frame]:ClearAllPoints()
        myHealPrediction[frame]:SetColorTexture(1, 1, 1)

        myHealPrediction2[frame] = createTexture(frame, "$parentMyHealPrediction2", "BORDER", 5)
        myHealPrediction2[frame]:ClearAllPoints()
        myHealPrediction2[frame]:SetColorTexture(1, 1, 1)

        otherHealPrediction[frame] = createTexture(frame, "$parentOtherHealPrediction", "BORDER", 5)
        otherHealPrediction[frame]:ClearAllPoints()
        otherHealPrediction[frame]:SetColorTexture(1, 1, 1)

        otherHealPrediction2[frame] = createTexture(frame, "$parentOtherHealPrediction2", "BORDER", 5)
        otherHealPrediction2[frame]:ClearAllPoints()
        otherHealPrediction2[frame]:SetColorTexture(1, 1, 1)

        -- ORIGINAL (DRY cleanup, not a bug fix - these frames are confirmed always
        -- plain Textures, never StatusBarOverlaySegment, so setFillTexture's guard
        -- is a no-op here; routed through it anyway to match the rest of the file
        -- instead of repeating ClearAllPoints()/SetTexture() by hand):
        -- totalAbsorb[frame]:ClearAllPoints()
        -- totalAbsorb[frame]:SetTexture("Interface\\RaidFrame\\Shield-Fill")
        totalAbsorb[frame] = createTexture(frame, "$parentTotalAbsorb", "BORDER", 5)
        setFillTexture(totalAbsorb[frame], "Interface\\RaidFrame\\Shield-Fill")

        totalAbsorbOverlay[frame] = createTexture(frame, "$parentTotalAbsorbOverlay", "BORDER", 6)
        totalAbsorb[frame].overlay = totalAbsorbOverlay[frame]
        totalAbsorbOverlay[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overlay", true, true)
        totalAbsorbOverlay[frame]:SetAllPoints(totalAbsorb[frame])
        totalAbsorbOverlay[frame].tileSize = 32

        healAbsorb[frame] = createTexture(frame, "$parentMyHealAbsorb", "ARTWORK", 1)
        healAbsorb[frame]:ClearAllPoints()
        healAbsorb[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Fill", true, true)

        -- ORIGINAL (DRY cleanup, same rationale as totalAbsorb above):
        -- healAbsorbLeftShadow[frame]:ClearAllPoints()
        -- healAbsorbLeftShadow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Edge")
        healAbsorbLeftShadow[frame] = createTexture(frame, "$parentMyHealAbsorbLeftShadow", "ARTWORK", 1)
        setFillTexture(healAbsorbLeftShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")

        -- ORIGINAL (DRY cleanup for the ClearAllPoints/SetTexture pair only;
        -- SetTexCoord is unrelated to setFillTexture and stays a direct call):
        -- healAbsorbRightShadow[frame]:ClearAllPoints()
        -- healAbsorbRightShadow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Edge")
        healAbsorbRightShadow[frame] = createTexture(frame, "$parentMyHealAbsorbRightShadow", "ARTWORK", 1)
        setFillTexture(healAbsorbRightShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")
        healAbsorbRightShadow[frame]:SetTexCoord(1, 0, 0, 1)

        overAbsorbGlow[frame] = createTexture(frame, "$parentOverAbsorbGlow", "ARTWORK", 2)
        overAbsorbGlow[frame]:ClearAllPoints()
        overAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
        overAbsorbGlow[frame]:SetBlendMode("ADD")
        overAbsorbGlow[frame]:SetPoint("BOTTOMLEFT", healthBar[frame], "BOTTOMRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetPoint("TOPLEFT", healthBar[frame], "TOPRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - a freshly created texture defaults to
        -- shown once SetTexture is called, so this glow was visible until the
        -- first updateHealPrediction pass for this frame explicitly hid it.
        overAbsorbGlow[frame]:Hide()

        overHealAbsorbGlow[frame] = createTexture(frame, "$parentOverHealAbsorbGlow", "ARTWORK", 2)
        overHealAbsorbGlow[frame]:ClearAllPoints()
        overHealAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Overabsorb")
        overHealAbsorbGlow[frame]:SetBlendMode("ADD")
        overHealAbsorbGlow[frame]:SetPoint("BOTTOMRIGHT", healthBar[frame], "BOTTOMLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetPoint("TOPRIGHT", healthBar[frame], "TOPLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - same rationale as overAbsorbGlow above.
        overHealAbsorbGlow[frame]:Hide()
    end

    hooksecurefunc("DefaultCompactUnitFrameSetup", defaultCompactUnitFrameSetup)

    local defaultCompactMiniFrameSetup = defaultCompactUnitFrameSetup

    hooksecurefunc("DefaultCompactMiniFrameSetup", defaultCompactMiniFrameSetup)

    -- ORIGINAL (removed entirely, not just replaced):
    -- local compactRaidFrameReservation_GetFrame
    --
    -- hooksecurefunc(
    --     "CompactRaidFrameReservation_GetFrame",
    --     function(self, key)
    --         compactRaidFrameReservation_GetFrame = self.reservations[key]
    --     end
    -- )
    --
    -- local frameCreationSpecifiers = {
    --     raid = {mapping = UnitGUID, setUpFunc = defaultCompactUnitFrameSetup},
    --     pet = {setUpFunc = defaultCompactMiniFrameSetup},
    --     flagged = {mapping = UnitGUID, setUpFunc = defaultCompactUnitFrameSetup},
    --     target = {setUpFunc = defaultCompactMiniFrameSetup}
    -- }
    --
    -- hooksecurefunc(
    --     "CompactRaidFrameContainer_GetUnitFrame",
    --     function(self, unit, frameType)
    --         if not compactRaidFrameReservation_GetFrame then
    --             local info = frameCreationSpecifiers[frameType]
    --             local mapping
    --
    --             if info.mapping then
    --                 mapping = info.mapping(unit)
    --             else
    --                 mapping = unit
    --             end
    --
    --             local frame = self.frameReservations[frameType].reservations[mapping]
    --             info.setUpFunc(frame)
    --         end
    --     end
    -- )
    --
    -- As of the shared Retail/Classic UI codebase's raid frame rewrite, CompactRaidFrameContainerMixin:GetUnitFrame()
    -- (formerly the global CompactRaidFrameContainer_GetUnitFrame) unconditionally calls
    -- CompactUnitFrame_SetUpFrame(frame, info.setUpFunc) for every frame it hands out, reused or
    -- not. That makes the hooks on DefaultCompactUnitFrameSetup/DefaultCompactMiniFrameSetup above
    -- sufficient on their own; the old reservation-tracking workaround above is no longer needed.

    -- ORIGINAL wrapper (texture-creation body below is unchanged, only the
    -- function signature/hook target changed - see the hooksecurefunc at the
    -- bottom of this function for what it used to be attached to):
    -- hooksecurefunc(
    --     "DefaultCompactNamePlateFrameSetup",
    --     function(frame)
    --         if frame:IsForbidden() or myHealPrediction[frame] then
    --             return
    --         end
    local function namePlateApplyFrameOptions(namePlateFrame)
        local frame = namePlateFrame.UnitFrame

        if not frame or frame:IsForbidden() or myHealPrediction[frame] then
            return
        end

        -- Opt-in only - see ClassicHealPredictionDefaultSettings.enableNameplates
        -- for why nameplates default off (known taint issue).
        if not ClassicHealPredictionSettings.enableNameplates then
            return
        end

        healthBar[frame] = frame.healthBar

            -- ORIGINAL (DRY cleanup, not a bug fix - same rationale as the
            -- defaultCompactUnitFrameSetup comment above: nameplate frames are
            -- confirmed always plain Textures here too):
            -- myHealPrediction[frame]:ClearAllPoints()
            -- myHealPrediction[frame]:SetTexture("Interface/TargetingFrame/UI-TargetingFrame-BarFill")
            myHealPrediction[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 5)
            myHealPrediction[frame] = myHealPrediction[healthBar[frame]]
            setFillTexture(myHealPrediction[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

            otherHealPrediction[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 5)
            otherHealPrediction[frame] = otherHealPrediction[healthBar[frame]]
            setFillTexture(otherHealPrediction[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

            myHealPrediction2[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 5)
            myHealPrediction2[frame] = myHealPrediction2[healthBar[frame]]
            setFillTexture(myHealPrediction2[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

            otherHealPrediction2[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 5)
            otherHealPrediction2[frame] = otherHealPrediction2[healthBar[frame]]
            setFillTexture(otherHealPrediction2[frame], "Interface/TargetingFrame/UI-TargetingFrame-BarFill")

            totalAbsorb[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 5)
            totalAbsorb[frame] = totalAbsorb[healthBar[frame]]
            setFillTexture(totalAbsorb[frame], "Interface\\RaidFrame\\Shield-Fill")

            totalAbsorbOverlay[healthBar[frame]] = createTexture(healthBar[frame], nil, "BORDER", 6)
            totalAbsorbOverlay[frame] = totalAbsorbOverlay[healthBar[frame]]
            totalAbsorb[frame].overlay = totalAbsorbOverlay[frame]
            totalAbsorbOverlay[frame]:SetAllPoints(totalAbsorb[frame])
            totalAbsorbOverlay[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overlay", true, true)
            totalAbsorbOverlay[frame].tileSize = 20

            healAbsorb[healthBar[frame]] = createTexture(healthBar[frame], nil, "ARTWORK", 1)
            healAbsorb[frame] = healAbsorb[healthBar[frame]]
            healAbsorb[frame]:ClearAllPoints()
            healAbsorb[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Fill", true, true)

            -- ORIGINAL (DRY cleanup, same rationale as above):
            -- healAbsorbLeftShadow[frame]:ClearAllPoints()
            -- healAbsorbLeftShadow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Edge")
            healAbsorbLeftShadow[healthBar[frame]] = createTexture(healthBar[frame], nil, "ARTWORK", 1)
            healAbsorbLeftShadow[frame] = healAbsorbLeftShadow[healthBar[frame]]
            setFillTexture(healAbsorbLeftShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")

            -- ORIGINAL (DRY cleanup for the ClearAllPoints/SetTexture pair only;
            -- SetTexCoord stays a direct call, unrelated to setFillTexture):
            -- healAbsorbRightShadow[frame]:ClearAllPoints()
            -- healAbsorbRightShadow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Edge")
            healAbsorbRightShadow[healthBar[frame]] = createTexture(healthBar[frame], nil, "ARTWORK", 1)
            healAbsorbRightShadow[frame] = healAbsorbRightShadow[healthBar[frame]]
            setFillTexture(healAbsorbRightShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")
            healAbsorbRightShadow[frame]:SetTexCoord(1, 0, 0, 1)

            overAbsorbGlow[healthBar[frame]] = createTexture(healthBar[frame], nil, "ARTWORK", 2)
            overAbsorbGlow[frame] = overAbsorbGlow[healthBar[frame]]
            overAbsorbGlow[frame]:ClearAllPoints()
            overAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
            overAbsorbGlow[frame]:SetBlendMode("ADD")
            overAbsorbGlow[frame]:SetPoint("BOTTOMLEFT", healthBar[frame], "BOTTOMRIGHT", -4, -1)
            overAbsorbGlow[frame]:SetPoint("TOPLEFT", healthBar[frame], "TOPRIGHT", -4, 1)
            overAbsorbGlow[frame]:SetHeight(8)
            -- ORIGINAL: no Hide() call here - a freshly created texture defaults to
            -- shown once SetTexture is called, so this glow was visible on
            -- nameplates until the first updateHealPrediction pass for this frame
            -- explicitly hid it.
            overAbsorbGlow[frame]:Hide()

            overHealAbsorbGlow[healthBar[frame]] = createTexture(healthBar[frame], nil, "ARTWORK", 2)
            overHealAbsorbGlow[frame] = overHealAbsorbGlow[healthBar[frame]]
            overHealAbsorbGlow[frame]:ClearAllPoints()
            overHealAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Overabsorb")
            overHealAbsorbGlow[frame]:SetBlendMode("ADD")
            overHealAbsorbGlow[frame]:SetPoint("BOTTOMRIGHT", healthBar[frame], "BOTTOMLEFT", 2, -1)
            overHealAbsorbGlow[frame]:SetPoint("TOPRIGHT", healthBar[frame], "TOPLEFT", 2, -1)
            overHealAbsorbGlow[frame]:SetHeight(8)
            -- ORIGINAL: no Hide() call here - same rationale as overAbsorbGlow above.
            overHealAbsorbGlow[frame]:Hide()
    --         end
    --     end
    -- )
    end

    -- ORIGINAL: the wrapping hooksecurefunc("DefaultCompactNamePlateFrameSetup", ...)
    -- shown commented above namePlateApplyFrameOptions is what used to close/register
    -- here instead of this if-block.
    if NamePlateBaseMixin and NamePlateBaseMixin.ApplyFrameOptions then
        -- Nameplate setup no longer goes through a named global function
        -- (DefaultCompactNamePlateFrameSetup); NamePlateBaseMixin:ApplyFrameOptions()
        -- now builds an inline closure and passes it to CompactUnitFrame_SetUpFrame instead.
        hooksecurefunc(NamePlateBaseMixin, "ApplyFrameOptions", namePlateApplyFrameOptions)
    end

    -- ORIGINAL: local function initUnitFrame(frame, createTextureArgs)
    --     local textures = {} - i.e. no nil-guard, went straight into the loop below.
    local function initUnitFrame(frame, createTextureArgs)
        if not frame then
            -- Some legacy globals this is called with (e.g. numbered
            -- PartyMemberFrame1..4) no longer exist in the shared Retail/Classic UI codebase;
            -- those unit types are handled by the CompactPartyFrame /
            -- DefaultCompactUnitFrameSetup path instead.
            return
        end

        local textures = {}

        -- ORIGINAL: every entry here used getChild(frame, unpack(depth)) to find its
        -- parent, regardless of depth. Diagnostic logging (during the mana-cost bar
        -- investigation, then confirmed here for the heal-prediction/absorb bars too)
        -- found getChild(PlayerFrame, 1, 1) resolves to an unrelated, hidden, unnamed
        -- utility frame in the shared Retail/Classic UI codebase's current PlayerFrame
        -- layout - every entry below using a non-empty depth (i.e. every one of these
        -- bars except totalAbsorbBar/totalAbsorbBarOverlay, which use an empty depth
        -- and so already correctly resolved to frame itself) was being parented to
        -- that same hidden frame, making myHealPrediction/otherHealPrediction/
        -- myHealPrediction2/otherHealPrediction2/healAbsorbBar/its shadows/
        -- overAbsorbGlow/overHealAbsorbGlow permanently invisible on PlayerFrame
        -- specifically (other frames' own getChild(frame, 1, 1) apparently resolves
        -- to something visible, which is why only PlayerFrame was affected). These
        -- are all conceptually children of the health bar, so parent directly to
        -- frame.healthbar instead of the fragile positional lookup.
        for _, args in pairs(createTextureArgs) do
            local depth, name, layer, subLayer = unpack(args)
            local parent = #depth == 0 and frame or frame.healthbar
            textures[name] = createTexture(parent, name, layer, subLayer)
        end

        healthBar[frame] = frame.healthbar

        -- ORIGINAL: frame.myManaCostPredictionBar used to be pulled from
        -- textures["$parentManaCostPredictionBar"] (created via the generic
        -- getChild(frame, 1, 1) loop above) - see the ORIGINAL comment on that entry's
        -- old location in the createTextureArgs table for why that was broken (parented
        -- to a hidden, unrelated frame). Created directly on frame.manabar instead,
        -- which is always a real, visible frame by this point.
        -- Bug fixed here: the first version of this fix checked only "frame.manabar"
        -- truthiness, but every unit frame (PetFrame, TargetFrame, etc.) has its own
        -- .manabar - that created a myManaCostPredictionBar for every frame type, not
        -- just the player, tripping the "assert(frame.unit == 'player')" guard below
        -- for PetFrame. Explicitly scoped to the player frame only, matching the
        -- original textures[...] lookup's effective behavior (only PlayerFrame's own
        -- createTextureArgs list ever included this entry).
        if not frame.myManaCostPredictionBar and frame.manabar and frame.unit == "player" then
            frame.myManaCostPredictionBar = createTexture(frame.manabar, "$parentManaCostPredictionBar", "BACKGROUND")
        end

        -- ORIGINAL: every setFillTexture(x, path) call from here through
        -- healAbsorbRightShadow below used to be a plain
        --     x:ClearAllPoints()
        --     x:SetTexture(path)
        -- pair (3-arg tiled SetTexture calls for totalAbsorbOverlay/healAbsorb are
        -- shown with their original ClearAllPoints()/SetTexture() pair inline at
        -- their own "if x.SetTexture then" guards below). These all threw "attempt
        -- to call a nil value" on Player/Pet/party/target frames once the shared
        -- Retail/Classic UI codebase's StatusBarOverlaySegmentMixin bars replaced the plain
        -- Textures these names used to resolve to - see setFillTexture's comment
        -- near the top of the file for the full explanation.
        if frame.myManaCostPredictionBar then
            assert(frame.unit == "player")

            setFillTexture(frame.myManaCostPredictionBar, "Interface\\TargetingFrame\\UI-StatusBar")

            proxyFrame[frame] = CreateFrame("Frame")
            proxyFrame[frame]:RegisterUnitEvent("UNIT_SPELLCAST_START", frame.unit)
            proxyFrame[frame]:RegisterUnitEvent("UNIT_SPELLCAST_STOP", frame.unit)
            proxyFrame[frame]:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", frame.unit)
            proxyFrame[frame]:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", frame.unit)
            proxyFrame[frame]:SetScript(
                "OnEvent",
                function(_, ...)
                    unitFrame_OnEvent(frame, ...)
                end
            )
        end

        myHealPrediction[frame] = textures["$parentMyHealPredictionBar"]

        if not myHealPrediction[frame] then
            UnitFrame_Update(frame)
            return
        end

        setFillTexture(myHealPrediction[frame], "Interface\\TargetingFrame\\UI-StatusBar")

        myHealPrediction2[frame] = textures["$parentMyHealPredictionBar2"]
        setFillTexture(myHealPrediction2[frame], "Interface\\TargetingFrame\\UI-StatusBar")

        otherHealPrediction[frame] = textures["$parentOtherHealPredictionBar"]
        setFillTexture(otherHealPrediction[frame], "Interface\\TargetingFrame\\UI-StatusBar")

        otherHealPrediction2[frame] = textures["$parentOtherHealPredictionBar2"]
        setFillTexture(otherHealPrediction2[frame], "Interface\\TargetingFrame\\UI-StatusBar")

        totalAbsorb[frame] = textures["$parentTotalAbsorbBar"]
        setFillTexture(totalAbsorb[frame], "Interface\\RaidFrame\\Shield-Fill")

        totalAbsorbOverlay[frame] = textures["$parentTotalAbsorbBarOverlay"]
        totalAbsorb[frame].overlay = totalAbsorbOverlay[frame]

        -- ORIGINAL: unconditional (no "if x.SetTexture then" guard at all) -
        -- totalAbsorbOverlay[frame]:ClearAllPoints()/SetTexture(...)/SetAllPoints(...)/
        -- .tileSize = 32 ran unconditionally every time. These two need the
        -- 3-argument (path, horizTile, vertTile) SetTexture form, which
        -- setFillTexture doesn't cover, so they're guarded inline instead.
        if totalAbsorbOverlay[frame].SetTexture then
            totalAbsorbOverlay[frame]:ClearAllPoints()
            totalAbsorbOverlay[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overlay", true, true)
            totalAbsorbOverlay[frame]:SetAllPoints(totalAbsorb[frame])
            totalAbsorbOverlay[frame].tileSize = 32
        end

        healAbsorb[frame] = textures["$parentHealAbsorbBar"]

        -- ORIGINAL: unconditional healAbsorb[frame]:ClearAllPoints()/SetTexture(...),
        -- no guard.
        if healAbsorb[frame].SetTexture then
            healAbsorb[frame]:ClearAllPoints()
            healAbsorb[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Fill", true, true)
        end

        healAbsorbLeftShadow[frame] = textures["$parentHealAbsorbBarLeftShadow"]
        setFillTexture(healAbsorbLeftShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")

        healAbsorbRightShadow[frame] = textures["$parentHealAbsorbBarRightShadow"]
        setFillTexture(healAbsorbRightShadow[frame], "Interface\\RaidFrame\\Absorb-Edge")

        -- ORIGINAL: unconditional healAbsorbRightShadow[frame]:SetTexCoord(1, 0, 0, 1), no guard.
        if healAbsorbRightShadow[frame].SetTexCoord then
            healAbsorbRightShadow[frame]:SetTexCoord(1, 0, 0, 1)
        end

        overAbsorbGlow[frame] = textures["$parentOverAbsorbGlow"]
        overAbsorbGlow[frame]:ClearAllPoints()
        overAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Shield-Overshield")
        overAbsorbGlow[frame]:SetBlendMode("ADD")
        overAbsorbGlow[frame]:SetPoint("BOTTOMLEFT", healthBar[frame], "BOTTOMRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetPoint("TOPLEFT", healthBar[frame], "TOPRIGHT", -7, 0)
        overAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - a freshly created texture defaults to
        -- shown once SetTexture is called, so this glow was visible until the
        -- first updateHealPrediction pass for this frame explicitly hid it.
        overAbsorbGlow[frame]:Hide()

        overHealAbsorbGlow[frame] = textures["$parentOverHealAbsorbGlow"]
        overHealAbsorbGlow[frame]:ClearAllPoints()
        overHealAbsorbGlow[frame]:SetTexture("Interface\\RaidFrame\\Absorb-Overabsorb")
        overHealAbsorbGlow[frame]:SetBlendMode("ADD")
        overHealAbsorbGlow[frame]:SetPoint("BOTTOMRIGHT", healthBar[frame], "BOTTOMLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetPoint("TOPRIGHT", healthBar[frame], "TOPLEFT", 7, 0)
        overHealAbsorbGlow[frame]:SetWidth(16)
        -- ORIGINAL: no Hide() call here - same rationale as overAbsorbGlow above.
        overHealAbsorbGlow[frame]:Hide()

        frame:RegisterUnitEvent("UNIT_MAXHEALTH", frame.unit)

        healthBar[frame]:SetScript(
            "OnSizeChanged",
            function(self)
                UnitFrameHealPredictionBars_UpdateSize(self:GetParent())
            end
        )

        UnitFrame_Update(frame)
    end

    initUnitFrame(
        PlayerFrame,
        {
            {{}, "$parentTotalAbsorbBar", "ARTWORK"},
            {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
            {{1, 1}, "$parentMyHealPredictionBar", "BACKGROUND"},
            {{1, 1}, "$parentOtherHealPredictionBar", "BACKGROUND"},
            {{1, 1}, "$parentMyHealPredictionBar2", "BACKGROUND"},
            {{1, 1}, "$parentOtherHealPredictionBar2", "BACKGROUND"},
            -- ORIGINAL: $parentManaCostPredictionBar used to be created here via the
            -- same getChild(frame, 1, 1) path as the entries above. Diagnostic logging
            -- confirmed getChild(PlayerFrame, 1, 1) resolves to an unrelated, hidden,
            -- unnamed utility frame (frame level 1001) in the shared Retail/Classic UI
            -- codebase's current PlayerFrame layout - unlike the other bars above, this
            -- one never resolves via getTexture()'s native-name lookup first (no native
            -- StatusBarOverlaySegment exists for it in Classic Era), so it always falls
            -- through to frame:CreateTexture(...) - meaning it was the only bar actually
            -- parented to that hidden frame, making it permanently invisible regardless
            -- of its own Show()/SetVertexColor()/position. See initUnitFrame below,
            -- where it's now created directly on frame.manabar instead.
            {{1, 1}, "$parentHealAbsorbBar", "BACKGROUND"},
            {{1, 1}, "$parentHealAbsorbBarLeftShadow", "BACKGROUND"},
            {{1, 1}, "$parentHealAbsorbBarRightShadow", "BACKGROUND"},
            {{1, 1}, "$parentOverAbsorbGlow", "ARTWORK", 1},
            {{1, 1}, "$parentOverHealAbsorbGlow", "ARTWORK", 1}
        }
    )

    initUnitFrame(
        PetFrame,
        {
            {{}, "$parentTotalAbsorbBar", "ARTWORK"},
            {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
            {{1, 1}, "$parentMyHealPredictionBar", "OVERLAY"},
            {{1, 1}, "$parentOtherHealPredictionBar", "BACKGROUND"},
            {{1, 1}, "$parentMyHealPredictionBar2", "BACKGROUND"},
            {{1, 1}, "$parentOtherHealPredictionBar2", "BACKGROUND"},
            {{1, 1}, "$parentHealAbsorbBar", "BACKGROUND"},
            {{1, 1}, "$parentHealAbsorbBarLeftShadow", "BACKGROUND"},
            {{1, 1}, "$parentHealAbsorbBarRightShadow", "BACKGROUND"},
            {{1, 1}, "$parentOverAbsorbGlow", "ARTWORK"},
            {{1, 1}, "$parentOverHealAbsorbGlow", "ARTWORK"}
        }
    )

    initUnitFrame(
        TargetFrame,
        {
            {{}, "$parentTotalAbsorbBar", "ARTWORK"},
            {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
            {{}, "$parentMyHealPredictionBar", "ARTWORK", 1},
            {{}, "$parentOtherHealPredictionBar", "ARTWORK", 1},
            {{}, "$parentMyHealPredictionBar2", "ARTWORK", 1},
            {{}, "$parentOtherHealPredictionBar2", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBar", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBarLeftShadow", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBarRightShadow", "ARTWORK", 1},
            {{1}, "$parentOverAbsorbGlow", "ARTWORK", 1},
            {{1}, "$parentOverHealAbsorbGlow", "ARTWORK", 1}
        }
    )

    initUnitFrame(
        TargetFrameToT,
        {
            {{}, "$parentTotalAbsorbBar", "ARTWORK"},
            {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
            {{}, "$parentMyHealPredictionBar", "ARTWORK", 1},
            {{}, "$parentOtherHealPredictionBar", "ARTWORK", 1},
            {{}, "$parentMyHealPredictionBar2", "ARTWORK", 1},
            {{}, "$parentOtherHealPredictionBar2", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBar", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBarLeftShadow", "ARTWORK", 1},
            {{}, "$parentHealAbsorbBarRightShadow", "ARTWORK", 1},
            {{1}, "$parentOverAbsorbGlow", "ARTWORK", 1},
            {{1}, "$parentOverHealAbsorbGlow", "ARTWORK", 1}
        }
    )

    if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC then
        initUnitFrame(
            FocusFrame,
            {
                {{}, "$parentTotalAbsorbBar", "ARTWORK"},
                {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
                {{}, "$parentMyHealPredictionBar", "ARTWORK", 1},
                {{}, "$parentOtherHealPredictionBar", "ARTWORK", 1},
                {{}, "$parentMyHealPredictionBar2", "ARTWORK", 1},
                {{}, "$parentOtherHealPredictionBar2", "ARTWORK", 1},
                {{}, "$parentHealAbsorbBar", "ARTWORK", 1},
                {{}, "$parentHealAbsorbBarLeftShadow", "ARTWORK", 1},
                {{}, "$parentHealAbsorbBarRightShadow", "ARTWORK", 1},
                {{1}, "$parentOverAbsorbGlow", "ARTWORK", 1},
                {{1}, "$parentOverHealAbsorbGlow", "ARTWORK", 1}
            }
        )
    end

    for i = 1, MAX_PARTY_MEMBERS do
        initUnitFrame(
            PartyMemberFrame[i],
            {
                {{}, "$parentTotalAbsorbBar", "ARTWORK"},
                {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
                {{1, 1}, "$parentMyHealPredictionBar", "OVERLAY"},
                {{1, 1}, "$parentOtherHealPredictionBar", "BACKGROUND"},
                {{1, 1}, "$parentMyHealPredictionBar2", "BACKGROUND"},
                {{1, 1}, "$parentOtherHealPredictionBar2", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBar", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBarLeftShadow", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBarRightShadow", "BACKGROUND"},
                {{1, 1}, "$parentOverAbsorbGlow", "ARTWORK"},
                {{1, 1}, "$parentOverHealAbsorbGlow", "ARTWORK"}
            }
        )

        initUnitFrame(
            PartyMemberFramePetFrame[i],
            {
                {{}, "$parentTotalAbsorbBar", "ARTWORK"},
                {{}, "$parentTotalAbsorbBarOverlay", "ARTWORK", 1},
                {{1, 1}, "$parentMyHealPredictionBar", "BACKGROUND"},
                {{1, 1}, "$parentOtherHealPredictionBar", "BACKGROUND"},
                {{1, 1}, "$parentMyHealPredictionBar2", "BACKGROUND"},
                {{1, 1}, "$parentOtherHealPredictionBar2", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBar", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBarLeftShadow", "BACKGROUND"},
                {{1, 1}, "$parentHealAbsorbBarRightShadow", "BACKGROUND"},
                {{1, 1}, "$parentOverAbsorbGlow", "ARTWORK"},
                {{1, 1}, "$parentOverHealAbsorbGlow", "ARTWORK"}
            }
        )
    end
end

local function ClassicHealPredictionFrame_Refresh()
    if not loadedSettings or not loadedFrame then
        return
    end

    for i, checkBox in ipairs(checkBoxes) do
        if i == 1 then
            checkBox:SetChecked(ClassicHealPredictionSettings.otherFilter >= 0)
        else
            checkBox:SetChecked(bit.band(toggleValue(ClassicHealPredictionSettings.otherFilter, true), checkBox.flag) == checkBox.flag)
            checkBox:SetEnabled(ClassicHealPredictionSettings.otherFilter >= 0)

            if ClassicHealPredictionSettings.otherFilter >= 0 then
                checkBox.Text:SetTextColor(1.0, 1.0, 1.0)
            else
                checkBox.Text:SetTextColor(0.5, 0.5, 0.5)
            end
        end
    end

    sliderCheckBox:SetChecked(ClassicHealPredictionSettings.otherDelta >= 0)
    sliderCheckBox:SetEnabled(ClassicHealPredictionSettings.otherFilter >= 0)

    if ClassicHealPredictionSettings.otherFilter >= 0 then
        sliderCheckBox.Text:SetTextColor(1.0, 1.0, 1.0)
    else
        sliderCheckBox.Text:SetTextColor(0.5, 0.5, 0.5)
    end

    slider:SetValue(toggleValue(ClassicHealPredictionSettings.otherDelta, true))
    slider:SetEnabled(ClassicHealPredictionSettings.otherFilter >= 0 and ClassicHealPredictionSettings.otherDelta >= 0)

    if ClassicHealPredictionSettings.otherFilter >= 0 and ClassicHealPredictionSettings.otherDelta >= 0 then
        slider.Text:SetTextColor(1.0, 1.0, 1.0)
        slider.Low:SetTextColor(1.0, 1.0, 1.0)
        slider.High:SetTextColor(1.0, 1.0, 1.0)
    else
        slider.Text:SetTextColor(0.5, 0.5, 0.5)
        slider.Low:SetTextColor(0.5, 0.5, 0.5)
        slider.High:SetTextColor(0.5, 0.5, 0.5)
    end

    sliderCheckBox2:SetChecked(ClassicHealPredictionSettings.overhealThreshold >= 0)

    slider2:SetValue(toggleValue(ClassicHealPredictionSettings.overhealThreshold, true) * 100)
    slider2:SetEnabled(ClassicHealPredictionSettings.overhealThreshold >= 0)

    if ClassicHealPredictionSettings.overhealThreshold >= 0 then
        slider2.Text:SetTextColor(1.0, 1.0, 1.0)
        slider2.Low:SetTextColor(1.0, 1.0, 1.0)
        slider2.High:SetTextColor(1.0, 1.0, 1.0)
    else
        slider2.Text:SetTextColor(0.5, 0.5, 0.5)
        slider2.Low:SetTextColor(0.5, 0.5, 0.5)
        slider2.High:SetTextColor(0.5, 0.5, 0.5)
    end

    sliderCheckBox3:SetChecked(ClassicHealPredictionSettings.raidFramesMaxOverflow >= 0)

    slider3:SetValue(toggleValue(ClassicHealPredictionSettings.raidFramesMaxOverflow, true) * 100)
    slider3:SetEnabled(ClassicHealPredictionSettings.raidFramesMaxOverflow >= 0)

    if ClassicHealPredictionSettings.raidFramesMaxOverflow >= 0 then
        slider3.Text:SetTextColor(1.0, 1.0, 1.0)
        slider3.Low:SetTextColor(1.0, 1.0, 1.0)
        slider3.High:SetTextColor(1.0, 1.0, 1.0)
    else
        slider3.Text:SetTextColor(0.5, 0.5, 0.5)
        slider3.Low:SetTextColor(0.5, 0.5, 0.5)
        slider3.High:SetTextColor(0.5, 0.5, 0.5)
    end

    sliderCheckBox4:SetChecked(ClassicHealPredictionSettings.unitFramesMaxOverflow >= 0)

    slider4:SetValue(toggleValue(ClassicHealPredictionSettings.unitFramesMaxOverflow, true) * 100)
    slider4:SetEnabled(ClassicHealPredictionSettings.unitFramesMaxOverflow >= 0)

    if ClassicHealPredictionSettings.unitFramesMaxOverflow >= 0 then
        slider4.Text:SetTextColor(1.0, 1.0, 1.0)
        slider4.Low:SetTextColor(1.0, 1.0, 1.0)
        slider4.High:SetTextColor(1.0, 1.0, 1.0)
    else
        slider4.Text:SetTextColor(0.5, 0.5, 0.5)
        slider4.Low:SetTextColor(0.5, 0.5, 0.5)
        slider4.High:SetTextColor(0.5, 0.5, 0.5)
    end

    checkBox3:SetChecked(ClassicHealPredictionSettings.overlaying)

    checkBox2:SetChecked(ClassicHealPredictionSettings.showManaCostPrediction)

    checkBox4:SetChecked(ClassicHealPredictionSettings.enableNameplates)

    for _, colorSwatch in ipairs(colorSwatches) do
        local r, g, b, a = unpack(ClassicHealPredictionSettings.colors[colorSwatch.index])
        colorSwatch:GetNormalTexture():SetVertexColor(r, g, b, a)
    end
end

function ClassicHealPredictionFrame_OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        if not _G.ClassicHealPredictionSettings then
            _G.ClassicHealPredictionSettings = {}
        end

        deepmerge(_G.ClassicHealPredictionSettings, ClassicHealPredictionDefaultSettings)

        _G.ClassicHealPredictionSettings["version"] = ADDON_VERSION

        ClassicHealPredictionSettings = {}

        for k, v in pairs(_G.ClassicHealPredictionSettings) do
            ClassicHealPredictionSettings[k] = deepcopy(v)
        end

        self:RegisterEvent("PLAYER_ENTERING_WORLD")

        loadedSettings = true

        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_ENTERING_WORLD" then
        updateAllFrames()

        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end


function ClassicHealPredictionFrame_Default()
    wipe(ClassicHealPredictionSettings)
    wipe(_G.ClassicHealPredictionSettings)

    for k, v in pairs(ClassicHealPredictionDefaultSettings) do
        ClassicHealPredictionSettings[k] = deepcopy(v)
        _G.ClassicHealPredictionSettings[k] = deepcopy(v)
    end

    ClassicHealPredictionSettings["version"] = ADDON_VERSION
    _G.ClassicHealPredictionSettings["version"] = ADDON_VERSION

    updateAllFrames()
end

_G.ClassicHealPredictionFrame_Default = ClassicHealPredictionFrame_Default

function ClassicHealPredictionFrame_Okay()
    wipe(_G.ClassicHealPredictionSettings)

    for k, v in pairs(ClassicHealPredictionSettings) do
        _G.ClassicHealPredictionSettings[k] = deepcopy(v)
    end

    updateAllFrames()
end

_G.ClassicHealPredictionFrame_Okay = ClassicHealPredictionFrame_Okay

function ClassicHealPredictionFrame_Cancel()
    wipe(ClassicHealPredictionSettings)

    for k, v in pairs(_G.ClassicHealPredictionSettings) do
        ClassicHealPredictionSettings[k] = deepcopy(v)
    end

    updateAllFrames()
end

_G.ClassicHealPredictionFrame_Cancel = ClassicHealPredictionFrame_Cancel

function ClassicHealPredictionFrame_OnLoad(self)
    self:RegisterEvent("ADDON_LOADED")

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")

    frame:SetScript(
        "OnEvent",
        function(_, ...)
            ClassicHealPrediction_OnEvent(...)
        end
    )

    frame:SetScript(
        "OnUpdate",
        function(_, ...)
            ClassicHealPrediction_OnUpdate(...)
        end
    )

    local title = self:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 15, -15)
    title:SetText(ADDON_NAME)

    local version = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 5, 0)
    version:SetTextColor(0.5, 0.5, 0.5)
    version:SetText(ADDON_VERSION and "v" .. ADDON_VERSION)

    checkBoxes = {}

    local sliderCheckBoxName = "ClassicHealPredictionSliderCheckbox"
    sliderCheckBox = CreateFrame("CheckButton", sliderCheckBoxName, self, "OptionsSmallCheckButtonTemplate")

    local sliderName = "ClassicHealPredictionSlider"
    slider = CreateFrame("Slider", sliderName, self, "ClassicHealPredictionOptionsSliderTemplate")

    for i, x in ipairs(
        {
            {"Show healing of others", HealComm.ALL_HEALS},
            {"Show direct healing", HealComm.DIRECT_HEALS},
            {"Show healing over time", HealComm.HOT_HEALS},
            {"Show channeled healing", HealComm.CHANNEL_HEALS},
            {"Show bomb healing", HealComm.BOMB_HEALS}
        }
    ) do
        local text, flag = unpack(x)
        local name = format("ClassicHealPredictionCheckButton%d", i)
        local template

        if i == 1 then
            template = "InterfaceOptionsCheckButtonTemplate"
        else
            template = "OptionsSmallCheckButtonTemplate"
        end

        local checkBox = CreateFrame("CheckButton", name, self, template)

        if i == 1 then
            checkBox:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
        else
            local anchor

            if i > 2 then
                anchor = "BOTTOMLEFT"
            else
                anchor = "BOTTOMRIGHT"
            end

            checkBox:SetPoint("TOPLEFT", checkBoxes[i - 1], anchor, 0, 0)
        end

        checkBox.Text = _G[name .. "Text"]
        checkBox.Text:SetText(text)
        checkBox.Text:SetTextColor(1, 1, 1)
        checkBox.flag = flag

        checkBox:SetScript(
            "OnClick",
            function(self)
                if self == checkBoxes[1] then
                    for j = 2, #checkBoxes do
                        checkBoxes[j]:SetEnabled(self:GetChecked())

                        if self:GetChecked() then
                            checkBoxes[j].Text:SetTextColor(1.0, 1.0, 1.0)
                        else
                            checkBoxes[j].Text:SetTextColor(0.5, 0.5, 0.5)
                        end
                    end

                    sliderCheckBox:SetEnabled(self:GetChecked())

                    if self:GetChecked() then
                        sliderCheckBox.Text:SetTextColor(1.0, 1.0, 1.0)
                    else
                        sliderCheckBox.Text:SetTextColor(0.5, 0.5, 0.5)
                    end

                    slider:SetEnabled(self:GetChecked() and sliderCheckBox:GetChecked())

                    if self:GetChecked() and sliderCheckBox:GetChecked() then
                        slider.Text:SetTextColor(1.0, 1.0, 1.0)
                        slider.Low:SetTextColor(1.0, 1.0, 1.0)
                        slider.High:SetTextColor(1.0, 1.0, 1.0)
                    else
                        slider.Text:SetTextColor(0.5, 0.5, 0.5)
                        slider.Low:SetTextColor(0.5, 0.5, 0.5)
                        slider.High:SetTextColor(0.5, 0.5, 0.5)
                    end

                    ClassicHealPredictionSettings.otherFilter = toggleValue(ClassicHealPredictionSettings.otherFilter, self:GetChecked())
                else
                    if self:GetChecked() then
                        ClassicHealPredictionSettings.otherFilter = bit.bor(toggleValue(ClassicHealPredictionSettings.otherFilter, true), self.flag)
                    else
                        ClassicHealPredictionSettings.otherFilter = bit.band(toggleValue(ClassicHealPredictionSettings.otherFilter, true), bit.bnot(self.flag))
                    end

                    ClassicHealPredictionSettings.otherFilter = toggleValue(ClassicHealPredictionSettings.otherFilter, checkBoxes[1]:GetChecked())
                end

                updateAllFrames()
            end
        )

        tinsert(checkBoxes, checkBox)
    end

    sliderCheckBox:SetPoint("TOPLEFT", checkBoxes[#checkBoxes], "BOTTOMLEFT", 0, 0)
    sliderCheckBox.Text = _G[sliderCheckBoxName .. "Text"]
    sliderCheckBox.Text:SetText("Set threshold for imminent healing to ... seconds")
    sliderCheckBox.Text:SetTextColor(1, 1, 1)

    slider:SetPoint("TOPLEFT", sliderCheckBox, "BOTTOMRIGHT", 0, -15)
    slider:SetWidth(300)
    slider:SetMinMaxValues(0.0, 30.0)
    slider:SetValueStep(0.1)
    slider:SetObeyStepOnDrag(true)
    slider.Text = _G[sliderName .. "Text"]
    slider.Low = _G[sliderName .. "Low"]
    slider.High = _G[sliderName .. "High"]
    slider.Text:SetText(format("%.1f", slider:GetValue()))
    slider.Low:SetText(format("%.1f", select(1, slider:GetMinMaxValues())))
    slider.High:SetText(format("%.1f", select(2, slider:GetMinMaxValues())))

    slider:SetScript(
        "OnValueChanged",
        function(self, event)
            self.Text:SetText(format("%.1f", event))
            ClassicHealPredictionSettings.otherDelta = toggleValue(event, ClassicHealPredictionSettings.otherDelta >= 0)

            updateAllFrames()
        end
    )

    sliderCheckBox:SetScript(
        "OnClick",
        function(self)
            if self:GetChecked() then
                slider.Text:SetTextColor(1.0, 1.0, 1.0)
                slider.Low:SetTextColor(1.0, 1.0, 1.0)
                slider.High:SetTextColor(1.0, 1.0, 1.0)
            else
                slider.Text:SetTextColor(0.5, 0.5, 0.5)
                slider.Low:SetTextColor(0.5, 0.5, 0.5)
                slider.High:SetTextColor(0.5, 0.5, 0.5)
            end

            slider:SetEnabled(self:GetChecked())
            ClassicHealPredictionSettings.otherDelta = toggleValue(ClassicHealPredictionSettings.otherDelta, self:GetChecked())

            updateAllFrames()
        end
    )

    local sliderCheckBoxName2 = "ClassicHealPredictionSliderCheckbox2"
    sliderCheckBox2 = CreateFrame("CheckButton", sliderCheckBoxName2, self, "InterfaceOptionsCheckButtonTemplate")

    local sliderName2 = "ClassicHealPredictionSlider2"
    slider2 = CreateFrame("Slider", sliderName2, self, "ClassicHealPredictionOptionsSliderTemplate")

    sliderCheckBox2:SetPoint("TOPLEFT", checkBoxes[1], "BOTTOMLEFT", 0, -180)
    sliderCheckBox2.Text = _G[sliderCheckBoxName2 .. "Text"]
    sliderCheckBox2.Text:SetText("Use different colors if overhealing exceeds ... percent of max health")
    sliderCheckBox2.Text:SetTextColor(1, 1, 1)

    slider2:SetPoint("TOPLEFT", sliderCheckBox2, "BOTTOMRIGHT", 0, -15)
    slider2:SetWidth(300)
    slider2:SetMinMaxValues(0, 100)
    slider2:SetValueStep(1)
    slider2:SetObeyStepOnDrag(true)
    slider2.Text = _G[sliderName2 .. "Text"]
    slider2.Low = _G[sliderName2 .. "Low"]
    slider2.High = _G[sliderName2 .. "High"]
    slider2.Text:SetText(format("%d", slider2:GetValue()))
    slider2.Low:SetText(format("%d", select(1, slider2:GetMinMaxValues())))
    slider2.High:SetText(format("%d", select(2, slider2:GetMinMaxValues())))

    slider2:SetScript(
        "OnValueChanged",
        function(self, event)
            self.Text:SetText(format("%d", event))
            ClassicHealPredictionSettings.overhealThreshold = toggleValue(event / 100, ClassicHealPredictionSettings.overhealThreshold >= 0)

            updateAllFrames()
        end
    )

    sliderCheckBox2:SetScript(
        "OnClick",
        function(self)
            if self:GetChecked() then
                slider2.Text:SetTextColor(1.0, 1.0, 1.0)
                slider2.Low:SetTextColor(1.0, 1.0, 1.0)
                slider2.High:SetTextColor(1.0, 1.0, 1.0)
            else
                slider2.Text:SetTextColor(0.5, 0.5, 0.5)
                slider2.Low:SetTextColor(0.5, 0.5, 0.5)
                slider2.High:SetTextColor(0.5, 0.5, 0.5)
            end

            slider2:SetEnabled(self:GetChecked())
            ClassicHealPredictionSettings.overhealThreshold = toggleValue(ClassicHealPredictionSettings.overhealThreshold, self:GetChecked())

            updateAllFrames()
        end
    )

    local sliderCheckBoxName3 = "ClassicHealPredictionSliderCheckbox3"
    sliderCheckBox3 = CreateFrame("CheckButton", sliderCheckBoxName3, self, "InterfaceOptionsCheckButtonTemplate")

    local sliderName3 = "ClassicHealPredictionSlider3"
    slider3 = CreateFrame("Slider", sliderName3, self, "ClassicHealPredictionOptionsSliderTemplate")

    sliderCheckBox3:SetPoint("TOPLEFT", sliderCheckBox2, "BOTTOMLEFT", 0, -50)
    sliderCheckBox3.Text = _G[sliderCheckBoxName3 .. "Text"]
    sliderCheckBox3.Text:SetText("Set max overflow in raid frames to ... percent of max health")
    sliderCheckBox3.Text:SetTextColor(1, 1, 1)

    slider3:SetPoint("TOPLEFT", sliderCheckBox3, "BOTTOMRIGHT", 0, -15)
    slider3:SetWidth(300)
    slider3:SetMinMaxValues(0, 100)
    slider3:SetValueStep(1)
    slider3:SetObeyStepOnDrag(true)
    slider3.Text = _G[sliderName3 .. "Text"]
    slider3.Low = _G[sliderName3 .. "Low"]
    slider3.High = _G[sliderName3 .. "High"]
    slider3.Text:SetText(format("%d", slider3:GetValue()))
    slider3.Low:SetText(format("%d", select(1, slider3:GetMinMaxValues())))
    slider3.High:SetText(format("%d", select(2, slider3:GetMinMaxValues())))

    slider3:SetScript(
        "OnValueChanged",
        function(self, event)
            self.Text:SetText(format("%d", event))
            ClassicHealPredictionSettings.raidFramesMaxOverflow = toggleValue(event / 100, ClassicHealPredictionSettings.raidFramesMaxOverflow >= 0)

            updateAllFrames()
        end
    )

    sliderCheckBox3:SetScript(
        "OnClick",
        function(self)
            if self:GetChecked() then
                slider3.Text:SetTextColor(1.0, 1.0, 1.0)
                slider3.Low:SetTextColor(1.0, 1.0, 1.0)
                slider3.High:SetTextColor(1.0, 1.0, 1.0)
            else
                slider3.Text:SetTextColor(0.5, 0.5, 0.5)
                slider3.Low:SetTextColor(0.5, 0.5, 0.5)
                slider3.High:SetTextColor(0.5, 0.5, 0.5)
            end

            slider3:SetEnabled(self:GetChecked())
            ClassicHealPredictionSettings.raidFramesMaxOverflow = toggleValue(ClassicHealPredictionSettings.raidFramesMaxOverflow, self:GetChecked())

            updateAllFrames()
        end
    )

    local sliderCheckBoxName4 = "ClassicHealPredictionSliderCheckbox4"
    sliderCheckBox4 = CreateFrame("CheckButton", sliderCheckBoxName4, self, "InterfaceOptionsCheckButtonTemplate")

    local sliderName4 = "ClassicHealPredictionSlider4"
    slider4 = CreateFrame("Slider", sliderName4, self, "ClassicHealPredictionOptionsSliderTemplate")

    sliderCheckBox4:SetPoint("TOPLEFT", sliderCheckBox3, "BOTTOMLEFT", 0, -50)
    sliderCheckBox4.Text = _G[sliderCheckBoxName4 .. "Text"]
    sliderCheckBox4.Text:SetText("Set max overflow in unit frames to ... percent of max health")
    sliderCheckBox4.Text:SetTextColor(1, 1, 1)

    slider4:SetPoint("TOPLEFT", sliderCheckBox4, "BOTTOMRIGHT", 0, -15)
    slider4:SetWidth(300)
    slider4:SetMinMaxValues(0, 100)
    slider4:SetValueStep(1)
    slider4:SetObeyStepOnDrag(true)
    slider4.Text = _G[sliderName4 .. "Text"]
    slider4.Low = _G[sliderName4 .. "Low"]
    slider4.High = _G[sliderName4 .. "High"]
    slider4.Text:SetText(format("%d", slider4:GetValue()))
    slider4.Low:SetText(format("%d", select(1, slider4:GetMinMaxValues())))
    slider4.High:SetText(format("%d", select(2, slider4:GetMinMaxValues())))

    slider4:SetScript(
        "OnValueChanged",
        function(self, event)
            self.Text:SetText(format("%d", event))
            ClassicHealPredictionSettings.unitFramesMaxOverflow = toggleValue(event / 100, ClassicHealPredictionSettings.unitFramesMaxOverflow >= 0)

            updateAllFrames()
        end
    )

    sliderCheckBox4:SetScript(
        "OnClick",
        function(self)
            if self:GetChecked() then
                slider4.Text:SetTextColor(1.0, 1.0, 1.0)
                slider4.Low:SetTextColor(1.0, 1.0, 1.0)
                slider4.High:SetTextColor(1.0, 1.0, 1.0)
            else
                slider4.Text:SetTextColor(0.5, 0.5, 0.5)
                slider4.Low:SetTextColor(0.5, 0.5, 0.5)
                slider4.High:SetTextColor(0.5, 0.5, 0.5)
            end

            slider4:SetEnabled(self:GetChecked())
            ClassicHealPredictionSettings.unitFramesMaxOverflow = toggleValue(ClassicHealPredictionSettings.unitFramesMaxOverflow, self:GetChecked())

            updateAllFrames()
        end
    )

    local checkBoxName3 = format("ClassicHealPredictionCheckbox%d", #checkBoxes + 2)
    checkBox3 = CreateFrame("CheckButton", checkBoxName3, self, "InterfaceOptionsCheckButtonTemplate")
    checkBox3:SetPoint("TOPLEFT", sliderCheckBox4, "BOTTOMLEFT", 0, -50)
    checkBox3.Text = _G[checkBoxName3 .. "Text"]
    checkBox3.Text:SetText("Overlay the healing of others with my healing")
    checkBox3.Text:SetTextColor(1, 1, 1)

    checkBox3:SetScript(
        "OnClick",
        function(self)
            ClassicHealPredictionSettings.overlaying = self:GetChecked()

            updateAllFrames()
        end
    )

    local checkBoxName2 = format("ClassicHealPredictionCheckbox%d", #checkBoxes + 1)
    checkBox2 = CreateFrame("CheckButton", checkBoxName2, self, "InterfaceOptionsCheckButtonTemplate")
    checkBox2:SetPoint("TOPLEFT", checkBox3, "BOTTOMLEFT", 0, 0)
    checkBox2.Text = _G[checkBoxName2 .. "Text"]
    checkBox2.Text:SetText("Show my mana cost prediction in the player unit frame")
    checkBox2.Text:SetTextColor(1, 1, 1)

    checkBox2:SetScript(
        "OnClick",
        function(self)
            ClassicHealPredictionSettings.showManaCostPrediction = self:GetChecked()

            updateAllFrames()
        end
    )

    local checkBoxName4 = format("ClassicHealPredictionCheckbox%d", #checkBoxes + 3)
    checkBox4 = CreateFrame("CheckButton", checkBoxName4, self, "InterfaceOptionsCheckButtonTemplate")
    checkBox4:SetPoint("TOPLEFT", checkBox2, "BOTTOMLEFT", 0, 0)
    checkBox4.Text = _G[checkBoxName4 .. "Text"]
    checkBox4.Text:SetText("Show heal prediction on nameplates (Blizzard's 1.15.9 nameplate changes can make attaching this to the health bar taint the UI - not a heal prediction bug)")
    checkBox4.Text:SetTextColor(1, 1, 1)
    -- Long enough to run off the panel on one line - constrain the width so it
    -- wraps instead.
    checkBox4.Text:SetWidth(480)
    checkBox4.Text:SetWordWrap(true)
    checkBox4.Text:SetJustifyH("LEFT")

    -- Frames already touched while this was enabled stay exposed even after
    -- disabling it again (the setting only gates *new* attachments), so a
    -- reload is the only reliable way to fully apply either direction of this
    -- toggle - confirmed via live testing, not just theoretical caution.
    StaticPopupDialogs[ADDON_NAME .. "_NAMEPLATES_RELOAD"] = {
        text = "This setting requires a UI reload to fully take effect. Reload now?",
        button1 = "Reload Now",
        button2 = "Cancel",
        OnAccept = function(_, newValue)
            -- Write to both the local staging table and the persisted
            -- SavedVariables directly - reloading immediately skips the normal
            -- Okay/commit flow (ClassicHealPredictionFrame_Okay), which is what
            -- writes staged changes to _G.ClassicHealPredictionSettings. Without
            -- this, the reload discards the change before it's ever saved.
            ClassicHealPredictionSettings.enableNameplates = newValue
            _G.ClassicHealPredictionSettings.enableNameplates = newValue
            local reload = (C_UI and C_UI.Reload) or ReloadUI
            reload()
        end,
        OnCancel = function(_, newValue)
            checkBox4:SetChecked(not newValue)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    checkBox4:SetScript(
        "OnClick",
        function(self)
            StaticPopup_Show(ADDON_NAME .. "_NAMEPLATES_RELOAD", nil, nil, self:GetChecked())
        end
    )

    -- Set before the do-block below so commit()'s closure captures this local
    -- (not a same-named global) - and before ColorPickerFrame:SetupColorPickerAndShow()
    -- further down, so the manual R/G/B/A entry boxes know which swatch's
    -- applyColor to call. They can't rely on swatchFunc/opacityFunc since those
    -- only fire from Blizzard's own wheel/slider drag scripts, not from
    -- programmatic ColorPickerFrame:SetColorRGB()/SetColorAlpha() calls.
    local activeApplyColor

    -- Manual R/G/B/A entry (0-255) on Blizzard's color picker, in addition to
    -- the wheel/sliders - standard in most color pickers, this one doesn't
    -- have it natively. Created once, before the swatch loop below, so
    -- onColorChanged/onCancel (defined per swatch) can keep it in sync.
    -- R/G/B only - alpha deliberately excluded: ColorPickerFrame's opacity
    -- slider periodically re-fires its callback with a stale internal value
    -- on its own (confirmed live, unrelated to anything this addon does),
    -- clobbering any typed alpha shortly after. Dragging the opacity slider
    -- by hand is good enough; getting an exact RGB hue from the wheel is the
    -- part manual entry is actually needed for.
    local refreshColorPickerEditBoxes
    do
        local editBoxes = {}

        -- Grow the picker frame itself so this row fits inside its own
        -- backdrop instead of spilling into whatever sits below it in the
        -- options panel. Anchored above the bottom edge to leave room for
        -- Blizzard's own Okay/Cancel buttons, which sit at the very bottom.
        ColorPickerFrame:SetHeight(ColorPickerFrame:GetHeight() + 40)

        local container = CreateFrame("Frame", nil, ColorPickerFrame)
        container:SetPoint("BOTTOM", ColorPickerFrame, "BOTTOM", 0, 30)
        container:SetSize(165, 24)

        local function commit(channel, editBox)
            local value = tonumber(editBox:GetText())
            editBox:ClearFocus()

            if not value or not activeApplyColor then
                return
            end

            value = max(0, min(255, value)) / 255

            local r, g, b = ColorPickerFrame:GetColorRGB()
            local a = ColorPickerFrame:GetColorAlpha()

            if channel == "R" then
                r = value
            elseif channel == "G" then
                g = value
            else
                b = value
            end

            ColorPickerFrame:SetColorRGB(r, g, b)
            activeApplyColor(r, g, b, a)

            -- Display exactly what we just applied rather than re-querying
            -- ColorPickerFrame:GetColorRGB() to sidestep any similar staleness.
            editBoxes.R:SetText(tostring(floor(r * 255 + 0.5)))
            editBoxes.G:SetText(tostring(floor(g * 255 + 0.5)))
            editBoxes.B:SetText(tostring(floor(b * 255 + 0.5)))
        end

        for i, channel in ipairs({"R", "G", "B"}) do
            local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetText(channel)
            label:SetPoint("LEFT", container, "LEFT", (i - 1) * 55, 0)

            local editBox = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
            editBox:SetSize(32, 20)
            editBox:SetAutoFocus(false)
            editBox:SetMaxLetters(3)
            editBox:SetPoint("LEFT", label, "RIGHT", 4, 0)
            editBox:SetScript("OnEnterPressed", function(self) commit(channel, self) end)
            editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            editBoxes[channel] = editBox
        end

        function refreshColorPickerEditBoxes()
            local r, g, b = ColorPickerFrame:GetColorRGB()

            editBoxes.R:SetText(tostring(floor(r * 255 + 0.5)))
            editBoxes.G:SetText(tostring(floor(g * 255 + 0.5)))
            editBoxes.B:SetText(tostring(floor(b * 255 + 0.5)))
        end

        ColorPickerFrame:HookScript("OnShow", refreshColorPickerEditBoxes)
    end

    for k, x in ipairs(
        {
            {"Raid Frames: My healing", {1, 2, 3, 4}},
            {"Raid Frames: Other healing", {5, 6, 7, 8}},
            {"Unit Frames: My healing", {9, 10, 11, 12}},
            {"Unit Frames: Other healing", {13, 14, 15, 16}},
            {"Unit Frames: My mana cost", {17}}
        }
    ) do
        local text, slots = unpack(x)

        local j = 1

        colorSwatches[k] = {}

        for _, i in pairs(slots) do
            local name = format("ClassicHealPredictionColorSwatch%d", i)
            local colorSwatch = CreateFrame("Button", name, self, "ClassicHealPredictionColorSwatchTemplate")

            colorSwatch.index = i

            local positionInGroup = j

            if k == 1 and j == 1 then
                colorSwatch:SetPoint("TOPRIGHT", -235, -50)
            elseif k ~= 1 and j == 1 then
                colorSwatch:SetPoint("TOPLEFT", colorSwatches[k - 1][1], "BOTTOMLEFT", 0, -8)
            else
                colorSwatch:SetPoint("LEFT", colorSwatches[k][j - 1], "RIGHT", 0, 0)
            end

            j = j + 1

            local r, g, b, a = unpack(ClassicHealPredictionSettings.colors[colorSwatch.index])
            colorSwatch:GetNormalTexture():SetVertexColor(r, g, b, a)

            local function applyColor(newR, newG, newB, newA)
                colorSwatch:GetNormalTexture():SetVertexColor(newR, newG, newB, newA)

                local newColor = {gradient(newR, newG, newB, newA)}
                ClassicHealPredictionSettings.colors[colorSwatch.index] = newColor
                -- Also write straight to the persisted SavedVariables - relying on
                -- the panel's Okay/Cancel staging flow means an immediate /reload
                -- (or just never clicking Okay) silently discards the change.
                _G.ClassicHealPredictionSettings.colors[colorSwatch.index] = deepcopy(newColor)

                updateAllFrames()
            end

            local function onColorChanged()
                local newR, newG, newB = ColorPickerFrame:GetColorRGB()
                local newA = ColorPickerFrame:GetColorAlpha()
                applyColor(newR, newG, newB, newA)
                refreshColorPickerEditBoxes()
            end

            local function onCancel()
                local newR, newG, newB, newA = ColorPickerFrame:GetPreviousValues()
                applyColor(newR, newG, newB, newA)
                refreshColorPickerEditBoxes()
            end

            colorSwatch:SetScript(
                "OnClick",
                function(self)
                    local r, g, b, a = unpack(ClassicHealPredictionSettings.colors[colorSwatch.index])
                    activeApplyColor = applyColor
                    -- ORIGINAL: set ColorPickerFrame.func/.opacityFunc/.cancelFunc/.hasOpacity/
                    -- .opacity/.previousValues directly, then :SetColorRGB() + :Hide() + :Show().
                    -- That API is gone as of the shared Retail/Classic UI codebase - the color
                    -- picker is now invoked via SetupColorPickerAndShow(options), which is why the
                    -- Okay button threw "attempt to call a nil value" (it looked for something
                    -- SetupColorPickerAndShow sets up internally, not the old .func property).
                    ColorPickerFrame:SetupColorPickerAndShow({
                        swatchFunc = onColorChanged,
                        opacityFunc = onColorChanged,
                        cancelFunc = onCancel,
                        hasOpacity = true,
                        opacity = a,
                        r = r,
                        g = g,
                        b = b,
                    })
                end
            )

            colorSwatch:SetScript(
                "OnEnter",
                function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(text, 1, 1, 1)

                    if #slots == 1 then
                        GameTooltip:AddLine("Mana cost prediction bar color.", nil, nil, nil, true)
                    elseif k == 1 then
                        -- First row only: detailed explanation with an example. The other
                        -- rows (Raid Frames: Other healing, Unit Frames: My/Other healing)
                        -- work identically, just for a different heal source/frame type, so
                        -- they get the short version below instead of repeating all this.
                        if positionInGroup == 1 then
                            GameTooltip:AddLine("Immediate incoming heal.", nil, nil, nil, true)
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("The portion of your incoming heal(s) on this unit landing within the near-term time window (the \"delta\" setting). Example: if you cast only Renew, this is the value of the very next tick.", nil, nil, nil, true)
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("Multiple incoming heals from you are combined, not shown separately. Example: if a Renew tick is about to land and you also cast a direct heal, the immediate incoming heal is the sum of both.", nil, nil, nil, true)
                        elseif positionInGroup == 2 then
                            GameTooltip:AddLine("Remaining incoming heal.", nil, nil, nil, true)
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("The rest of your incoming heal(s) on this unit, landing after that near-term window. Example: for Renew only, this is the sum of all the ticks after the next one.", nil, nil, nil, true)
                        elseif positionInGroup == 3 then
                            GameTooltip:AddLine("Immediate incoming heal (overheal warning color).", nil, nil, nil, true)
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("Same value as the 1st color, shown instead when the total predicted heal (yours plus everyone else's, combined) would overheal past the \"Use different colors if overhealing exceeds ... percent of max health\" setting below. Only applies if that setting's checkbox is enabled - the whole bar swaps to this color set at once, not just the overhealing portion.", nil, nil, nil, true)
                        else
                            GameTooltip:AddLine("Remaining incoming heal (overheal warning color).", nil, nil, nil, true)
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine("Same value as the 2nd color, shown instead when the total predicted heal (yours plus everyone else's, combined) would overheal past the \"Use different colors if overhealing exceeds ... percent of max health\" setting below. Only applies if that setting's checkbox is enabled - the whole bar swaps to this color set at once, not just the overhealing portion.", nil, nil, nil, true)
                        end
                    elseif positionInGroup == 1 then
                        GameTooltip:AddLine("Immediate incoming heal.", nil, nil, nil, true)
                    elseif positionInGroup == 2 then
                        GameTooltip:AddLine("Remaining incoming heal.", nil, nil, nil, true)
                    elseif positionInGroup == 3 then
                        GameTooltip:AddLine("Immediate incoming heal (overheal warning color).", nil, nil, nil, true)
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Only used if \"Use different colors if overhealing exceeds ... percent of max health\" is enabled below - swaps the whole bar, not just the overhealing part.", nil, nil, nil, true)
                    else
                        GameTooltip:AddLine("Remaining incoming heal (overheal warning color).", nil, nil, nil, true)
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine("Only used if \"Use different colors if overhealing exceeds ... percent of max health\" is enabled below - swaps the whole bar, not just the overhealing part.", nil, nil, nil, true)
                    end

                    GameTooltip:Show()
                end
            )

            colorSwatch:SetScript("OnLeave", GameTooltip_Hide)

            tinsert(colorSwatches[k], colorSwatch)
        end

        local textString = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        textString:SetPoint("LEFT", colorSwatches[k][#colorSwatches[k]], "RIGHT", 16 * (4 - #colorSwatches[k]) + 5, 0)
        textString:SetTextColor(1, 1, 1)
        textString:SetText(text)
    end

    local colorSwatches2 = colorSwatches
    colorSwatches = {}

    for _, t in ipairs(colorSwatches2) do
        for _, x in ipairs(t) do
            tappend(colorSwatches, x)
        end
    end

    self.name = ADDON_NAME

    if InterfaceOptions_AddCategory then
        self.default = ClassicHealPredictionFrame_Default
        self.refresh = ClassicHealPredictionFrame_Refresh
        self.okay = ClassicHealPredictionFrame_Okay
        self.cancel = ClassicHealPredictionFrame_Cancel

        InterfaceOptions_AddCategory(self)
    else
        self.OnCommit = ClassicHealPredictionFrame_Okay
        self.OnDefault = ClassicHealPredictionFrame_Default
        self.OnRefresh = ClassicHealPredictionFrame_Refresh

        local category = Settings.RegisterCanvasLayoutCategory(self, self.name)
        Settings.RegisterAddOnCategory(category)
    end

    loadedFrame = true
end



do
    local healComm = {}

    local Renew = GetSpellInfo(139)
    local GreaterHealHot = GetSpellInfo(22009)
    local Rejuvenation = GetSpellInfo(774)
    local Regrowth = GetSpellInfo(8936)
    local Tranquility = GetSpellInfo(740)

    tickIntervals = {
        [Renew] = 3,
        [GreaterHealHot] = 3,
        [Rejuvenation] = 3,
        [Regrowth] = 3,
        [Tranquility] = 2
    }

    function healComm:HealComm_HealStarted(event, casterGUID, spellID, type, endTime, ...)
        local predictEndTime = getOtherEndTime()

        if casterGUID == UnitGUID("player") or not predictEndTime or endTime <= predictEndTime then
            UpdateHealPrediction(...)
            return
        end

        if bit.band(type, HealComm_OVERTIME_HEALS) > 0 then
            local tickInterval = tickIntervals[GetSpellInfo(spellID)] or 1
            local delta = predictEndTime - GetTime()
            local duration = tickInterval - delta % tickInterval + 0.001

            if duration < tickInterval then
                local guids = {...}

                C_Timer.After(
                    duration,
                    function()
                        UpdateHealPrediction(unpack(guids))
                    end
                )
            end

            UpdateHealPrediction(...)
        else
            local duration = endTime - predictEndTime + 0.001
            local guids = {...}

            C_Timer.After(
                duration,
                function()
                    UpdateHealPrediction(unpack(guids))
                end
            )
        end
    end

    function healComm:HealComm_HealStopped(event, casterGUID, spellID, type, interrupted, ...)
        UpdateHealPrediction(...)
    end

    function healComm:HealComm_ModifierChanged(event, ...)
        UpdateHealPrediction(...)
    end

    HealComm.RegisterCallback(healComm, "HealComm_HealStarted")
    HealComm.RegisterCallback(healComm, "HealComm_HealStopped")
    HealComm.RegisterCallback(healComm, "HealComm_HealDelayed", "HealComm_HealStarted")
    HealComm.RegisterCallback(healComm, "HealComm_HealUpdated", "HealComm_HealStarted")
    HealComm.RegisterCallback(healComm, "HealComm_ModifierChanged")
    HealComm.RegisterCallback(healComm, "HealComm_GUIDDisappeared", "HealComm_ModifierChanged")
end







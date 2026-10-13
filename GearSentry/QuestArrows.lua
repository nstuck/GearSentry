-- QuestArrows.lua: draws GearSentry's own upgrade arrow (BagArrows.lua's
-- atlas and drawing approach) on the quest turn-in reward panel, marking
-- which reward choice - if any - is the best upgrade.
--
-- Forever has no Camelot override for the quest frame code, so this follows
-- the Mainline files on the `forever` branch of wow-ui-source
-- (Interface/AddOns/Blizzard_UIPanels_Game/Mainline/QuestFrame.lua and
-- QuestInfo.lua, https://github.com/Gethe/wow-ui-source).
local _, ns = ...

local QuestArrows = {}
ns.QuestArrows = QuestArrows

-- Same atlas BagArrows.lua uses; drawing our own texture with it, never
-- touching any Blizzard region.
local ATLAS = "bags-greenarrow"

local atlasAvailable = C_Texture ~= nil and type(C_Texture.GetAtlasInfo) == "function"
    and C_Texture.GetAtlasInfo(ATLAS) ~= nil

-- Reward button -> the texture region we created for it. The only
-- per-button state this file keeps; nothing is ever written onto a
-- Blizzard button or frame table itself.
local overlays = {}

local function settings()
    local db = ns.DB()
    return db and db.settings
end

-- Gains at or below this count as ties, same tolerance Evaluator.lua uses
-- for its own threshold math.
local EPSILON = 1e-6

----------------------------------------------------------------------------
-- Which button (if any) gets the arrow
----------------------------------------------------------------------------

-- True if `suggestion`'s new item is a weapon of a type the player already
-- has equipped (ctx.player.weaponSkills, built by Player.Build from the
-- currently equipped weapon types). The score itself can't tell two
-- same-DPS weapons of different types apart (a Sword and a Mace with
-- identical damage score the same), but switching types means starting
-- that weapon skill over - more misses until it's trained back up, which
-- CanUseItem's plain "usable" doesn't capture. Used only to break a tie
-- between otherwise-equal choices, never to change which items qualify.
local function keepsTrainedWeaponType(ctx, suggestion)
    local action = suggestion.actions[1]
    local item = action and action.item
    local weaponType = item and item.weaponType
    return weaponType ~= nil and ctx.player.weaponSkills ~= nil and ctx.player.weaponSkills[weaponType] == true
end

-- Only "choice" reward buttons are candidates: those are the items the
-- player picks between, so an arrow helps a real decision. Fixed/guaranteed
-- rewards are never marked - there's nothing to choose, and they get their
-- own arrow/tooltip line once they land in the bags anyway.
--
-- Each shown choice item is evaluated on its own via
-- Scanner.EvaluateLink (the same "as if it were alone in the bags" check
-- /gs eval and the tooltip's on-demand line use), against a fresh
-- Scanner.Context() rather than a cached scan, since gear can change
-- between scans. The highest-gain qualifying item wins; a near-tie is
-- broken toward keeping an already-trained weapon type (see
-- keepsTrainedWeaponType); if none of the choices are a real upgrade,
-- nothing is marked.
function QuestArrows.BestChoiceButton(rewardsFrame)
    if not (rewardsFrame and rewardsFrame.RewardButtons and ns.Scanner and ns.Scanner.Context) then
        return nil
    end
    local ctx = ns.Scanner.Context()
    if not ctx then
        return nil
    end
    local best, bestGain, bestTrained
    -- QuestInfo_ShowRewards (QuestInfo.lua) only calls questItem:SetID(index)
    -- for the quest-log view (QuestInfoFrame.questLog); on the actual
    -- turn-in panel it never does, so button:GetID() can't be trusted here -
    -- it stays whatever a *previous* quest's button pool left it at. What
    -- Blizzard's own code uses instead is the position within the choices
    -- loop (1..numQuestChoices), and since that loop always fills
    -- RewardButtons[1..numQuestChoices] before any other reward type does,
    -- a running count of the "choice" buttons seen in order gives the same
    -- number.
    local choiceIndex = 0
    for _, button in ipairs(rewardsFrame.RewardButtons) do
        if button.type == "choice" and button.objectType == "item" and button:IsShown() then
            choiceIndex = choiceIndex + 1
            local link = GetQuestItemLink(button.type, choiceIndex)
            if link then
                local suggestion = ns.Scanner.EvaluateLink(link, ctx)
                if suggestion then
                    local trained = keepsTrainedWeaponType(ctx, suggestion)
                    local better
                    if not best then
                        better = true
                    elseif suggestion.gain > bestGain + EPSILON then
                        better = true
                    elseif suggestion.gain > bestGain - EPSILON and trained and not bestTrained then
                        better = true -- a near-tie: prefer not switching weapon type
                    end
                    if better then
                        best, bestGain, bestTrained = button, suggestion.gain, trained
                    end
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------

-- Anchored to the button's own Icon sub-region (not the button itself: the
-- large/small quest reward item button templates reserve space to the
-- right of the icon for the item name, unlike a bag button where the icon
-- fills the whole button), same corner Blizzard's own IconBorder overlay
-- uses on that template.
local function textureFor(button)
    local tex = overlays[button]
    if not tex then
        tex = button:CreateTexture(nil, "OVERLAY", nil, 2)
        tex:SetAtlas(ATLAS, true)
        local info = C_Texture.GetAtlasInfo(ATLAS)
        if info and info.width and info.width > 0 then
            tex:SetSize(info.width, info.height)
        end
        tex:SetPoint("TOPLEFT", button.Icon or button, "TOPLEFT", 0, 0)
        overlays[button] = tex
    end
    return tex
end

-- Repaints the reward panel: shows the arrow on the best qualifying choice
-- button, hides it everywhere else. Safe to call whenever - with the panel
-- closed, the setting off, or nothing to show, it just hides every arrow
-- this file has ever drawn.
function QuestArrows.Repaint()
    if not atlasAvailable then
        return
    end
    local panel = QuestFrameRewardPanel
    if not (panel and panel.IsShown and panel:IsShown()) then
        QuestArrows.HideAll()
        return
    end
    local rewardsFrame = QuestInfoRewardsFrame
    if not (rewardsFrame and rewardsFrame.RewardButtons) then
        return
    end
    local s = settings()
    local best
    if s and s.questRewardArrow then
        best = QuestArrows.BestChoiceButton(rewardsFrame)
    end
    for _, button in ipairs(rewardsFrame.RewardButtons) do
        if button.type == "choice" then
            textureFor(button):SetShown(button == best)
        end
    end
end

-- Hides (never destroys) every texture this file has ever created. Used
-- when the panel isn't shown and when settings.questRewardArrow is off.
function QuestArrows.HideAll()
    for _, tex in pairs(overlays) do
        tex:Hide()
    end
end

----------------------------------------------------------------------------
-- Hook installation (PLAYER_LOGIN) + item-data retry
----------------------------------------------------------------------------

-- QuestFrameRewardPanel_OnShow (QuestFrame.lua) is the global function that
-- runs on the actual turn-in dialog's OnShow: it points
-- QuestInfoFrame.rewardsFrame at QuestInfoRewardsFrame and calls
-- QuestInfo_ShowRewards(). Hooking it (rather than the frame's OnShow
-- script) means our repaint runs after Blizzard's own population, every
-- time, including quest-to-quest re-shows of an already-visible panel.
local function installHooks()
    if not (hooksecurefunc and type(QuestFrameRewardPanel_OnShow) == "function") then
        ns:Debug("QuestArrows: QuestFrameRewardPanel_OnShow not available; quest reward arrow disabled")
        return
    end
    hooksecurefunc("QuestFrameRewardPanel_OnShow", QuestArrows.Repaint)
end

ns:RegisterEvent("PLAYER_LOGIN", installHooks)

-- A reward item's name/icon/usability load asynchronously
-- (item:ContinueOnItemLoad in QuestInfo.lua), and so does the data
-- Scanner.EvaluateLink needs (ItemData.FromLink returns "pending" until
-- then). Retry the repaint whenever item data arrives while the panel is
-- actually up; Repaint() is cheap (a handful of buttons) and a no-op once
-- nothing is pending.
local function retryIfShown()
    local panel = QuestFrameRewardPanel
    if panel and panel.IsShown and panel:IsShown() then
        QuestArrows.Repaint()
    end
end
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", retryIfShown)
ns:RegisterEvent("ITEM_DATA_LOAD_RESULT", retryIfShown)

-- React to questRewardArrow, however it was changed (/gs questarrows or the
-- options panel's checkbox; both go through ns.SetSetting), by repainting
-- right away rather than waiting for the next QUEST_COMPLETE.
if ns.OnSettingChanged then
    ns.OnSettingChanged("questRewardArrow", QuestArrows.Repaint)
end

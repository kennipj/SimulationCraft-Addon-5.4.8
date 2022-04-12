local _, Simulationcraft = ...

-- Most of the guts of this addon were based on a variety of other ones, including
-- Statslog, AskMrRobot, and BonusScanner. And a bunch of hacking around with AceGUI.
-- Many thanks to the authors of those addons, and to reia for fixing my awful amateur
-- coding mistakes regarding objects and namespaces.

function Simulationcraft:OnInitialize()
    self.db = LibStub('AceDB-3.0'):New('SimulationcraftDB', self:CreateDefaults(), true)
    AceConfig = LibStub("AceConfigDialog-3.0")
    LibStub("AceConfig-3.0"):RegisterOptionsTable("Simulationcraft", self:CreateOptions())
    AceConfig:AddToBlizOptions("Simulationcraft", "Simulationcraft")
    Simulationcraft:RegisterChatCommand('simc', 'PrintSimcProfile')    
end

function Simulationcraft:OnEnable() 
    SimulationcraftTooltip:SetOwner(_G["UIParent"],"ANCHOR_NONE")
end

function Simulationcraft:OnDisable()

end

local L = LibStub("AceLocale-3.0"):GetLocale("Simulationcraft")

-- load stuff from extras.lua
local SimcStatAbbr  = Simulationcraft.SimcStatAbbr
local upgradeTable  = Simulationcraft.upgradeTable
local slotNames     = Simulationcraft.slotNames
local simcSlotNames = Simulationcraft.simcSlotNames
local enchantNames  = Simulationcraft.enchantNames

-- error string
local simc_err_str = ''

-- debug flag
local SIMC_DEBUG = false

-- debug function
local function simcDebug( s )
  if SIMC_DEBUG then
    print('debug: '.. tostring(s) )    
  end
end

-- SimC tokenize function
local function tokenize(str)
    str = str or ""
    -- convert to lowercase and remove spaces
    str = string.lower(str)
    str = string.gsub(str, ' ', '_')
    
    -- keep stuff we want, dumpster everything else
    local s = ""
    for i=1,str:len() do
        -- keep digits 0-9
        if str:byte(i) >= 48 and str:byte(i) <= 57 then
            s = s .. str:sub(i,i)
        -- keep lowercase letters
        elseif str:byte(i) >= 97 and str:byte(i) <= 122 then
            s = s .. str:sub(i,i)
        -- keep %, +, ., _
        elseif str:byte(i)==37 or str:byte(i)==43 or str:byte(i)==46 or str:byte(i)==95 then
            s = s .. str:sub(i,i)
        end
    end
    -- strip trailing spaces
    if string.sub(s, s:len())=='_' then
        s = string.sub(s, 0, s:len()-1)
    end
    return s
end

-- method for constructing reforge string from item link
local function CreateSimcReforgeString(itemLink)
    local ReforgingInfo = LibStub("LibReforgingInfo-1.0")
    local str = ',reforge='
    local reforgeId = 0
    local reforgeSource = ''
    local reforgeDest = ''
    if ReforgingInfo:IsItemReforged(itemLink) then
        reforgeSource, reforgeDest = ReforgingInfo:GetReforgedStatShortNames(ReforgingInfo:GetReforgeID(itemLink))
        return str .. Simulationcraft.SimcStatAbbr[(reforgeSource:gsub("%s+", "_")):lower()] .. '_' .. Simulationcraft.SimcStatAbbr[(reforgeDest:gsub("%s+", "_")):lower()]
    else
        return ''
    end
end


local function CreateSimcStatsString(itemLink)
    stat_conversions = { ["ITEM_MOD_STAMINA_SHORT"] = "sta",
        ["ITEM_MOD_AGILITY_SHORT"] = "agi",
        ["ITEM_MOD_INTELLECT_SHORT"] = "int",
        ["ITEM_MOD_STRENGTH_SHORT"] = "str",
        ["ITEM_MOD_SPIRIT_SHORT"] = "spi",
        ["ITEM_MOD_HIT_RATING_SHORT"] = "hit",
        ["ITEM_MOD_EXPERTISE_RATING_SHORT"] = "exp",
        ["ITEM_MOD_CRIT_RATING_SHORT"] = "crit",
        ["ITEM_MOD_SPELL_POWER_SHORT"] = "sp",
        ["ITEM_MOD_MASTERY_RATING_SHORT"] = "mastery",
        ["ITEM_MOD_HASTE_RATING_SHORT"] = "haste" }
    stats_begin = ",stats="
    stats_string = ""
    stats = GetItemStats(itemLink)
    for k, v in pairs(stats) do
        stat = stat_conversions[k]
        if stat == nil then
        else
            stats_string   = stats_string .. tostring(v) .. stat .. "_"
        end
    end
    
    if stats_string:len()>0 then
        stats_string = stats_string:sub(1, -2)
        stats_string = stats_begin .. stats_string
    end
    return stats_string
end

-- method for constructing the talent string
local function CreateSimcTalentString() 
    local talentInfo = {}
    local maxTiers = 6
    local maxColumns = 3
    for tier = 1, maxTiers do
        local selected, id = GetTalentRowSelectionInfo(tier)
        if not selected then
            if id % 3 == 0 then talentInfo[tier] = 3 else talentInfo[tier] = id % 3 end
        end
    end
    
    local str = 'talents='
    for i = 1, maxTiers do
        if talentInfo[i] then
            str = str .. talentInfo[i]
        else
            str = str .. '0'
        end
    end     

    return str
end

-- method for removing glyph prefixes
local function StripGlyphPrefixes(name)
    local s = tokenize(name)
    
    s = string.gsub( s, 'glyph__', '')
    s = string.gsub( s, 'glyph_of_the_', '')
    s = string.gsub( s, 'glyph_of_','')
    
    return s
end

-- constructs glyph string from game's glyph info
local function CreateSimcGlyphString()
    local str = 'glyphs='
    for i=1, NUM_GLYPH_SLOTS do
        local _,_,_,spellid = GetGlyphSocketInfo(i, nil)
        if (spellid) then
            name = GetSpellInfo(spellid)
            str = str .. StripGlyphPrefixes(name) ..'/'
        end            
    end
    return str
end

-- function that translates between the game's role values and ours
local function translateRole(str)
    if str == 'TANK' then
         return tokenize(str)
    elseif str == 'DAMAGER' then
         return 'attack'
    elseif str == 'HEALER' then
         return 'healer'
    else
         return ''
    end

end

-- =================== Item stuff========================= 
-- This function converts text-based stat info (from tooltips) into SimC-compatible strings
local function ConvertToStatString( s )
    s = s or ''
    -- grab the value and stat from the string
    local value,stat = string.match(s, "(%d+)%s(%a+%s?%a*)")
    -- convert stat into simc abbreviation
    local statAbbr = SimcStatAbbr[tokenize(stat)]   
    -- return abbreviated combination or nil
    if statAbbr and value then
        return value..statAbbr
    else
        return ''
    end
end

local function ConvertTooltipToStatStr( s )

    local s1=s
    local s2=''
    if s:len()>0 then
        -- check for a split bonus
        if string.find(s, " and ++") then
            s1, s2 = string.match(s, "(%d+%s%a+%s?%a*) and ++?(%d+%s%a+%s?%a*)")
        end
    end

    s1=ConvertToStatString(s1)
    s2=ConvertToStatString(s2)
    
    if s2:len()>0 then
        return  s1 .. '_' .. s2
    else
        return s1
    end
end

-- This scans the tooltip and picks out a socket bonus, if one exists
local function GetSocketBonus(link)
    SimulationcraftTooltip:ClearLines()
    SimulationcraftTooltip:SetHyperlink(link)
    local numLines = SimulationcraftTooltip:NumLines()
    --Check each line of the tooltip until we find a bonus string
    local bonusStr=''
    for i=2, numLines, 1 do
        tmpText = _G["SimulationcraftTooltipTextLeft"..i]
        if (tmpText:GetText()) then
            line = tmpText:GetText()
            if ( string.sub(line, 0, string.len(L["SocketBonusPrefix"])) == L["SocketBonusPrefix"]) then
                bonusStr=string.sub(line,string.len(L["SocketBonusPrefix"])+1)
            end
        end
    end
    
    -- Extract Socket bonus from string
    local socketBonusStr = ''
    if bonusStr:len()>0 then
        socketBonusStr = ConvertToStatString( bonusStr )
    end
    return socketBonusStr
end

local function GetEnchantBonus(link)
    SimulationcraftTooltip:ClearLines()
    SimulationcraftTooltip:SetHyperlink(link)
    local numLines = SimulationcraftTooltip:NumLines()
    --Check each line of the tooltip until we find a bonus string
    local bonusStr=''
    for i=2, numLines, 1 do
        tmpText = _G["SimulationcraftTooltipTextLeft"..i]
        if (tmpText:GetText()) then
            line = tmpText:GetText()
            if ( string.sub(line, 0, string.len(L["EnchantBonusPrefix"])) == L["EnchantBonusPrefix"]) then
                bonusStr=string.sub(line,string.len(L["EnchantBonusPrefix"])+1)
            end
        end
    end
    
    --simcDebug('Bonus String:')
    --simcDebug(bonusStr)
    
    --simcDebug('Start Conversion:')    
    
    -- Extract Enchant bonus from string
    local enchantBonusStr = ''
    if bonusStr:len()>0 then
        enchantBonusStr = ConvertTooltipToStatStr( bonusStr )
    end
    --simcDebug('Result of Conversion:')    
    --simcDebug(enchantBonusStr)
    return enchantBonusStr

end

-- This scans the tooltip to get gem stats
local function GetGemBonus(link)
    if link == nil then return '' end
    SimulationcraftTooltip:ClearLines()
    SimulationcraftTooltip:SetHyperlink(link)
    local numLines = SimulationcraftTooltip:NumLines()
    --print(numLines)
    local bonusStr=''
    for i=2, numLines, 1 do
        tmpText = _G["SimulationcraftTooltipTextLeft"..i]
        if (tmpText:GetText()) then
            line = tmpText:GetText()
            --print(line)
            if ( string.sub(line, 0, 1) == '+') then
                bonusStr=line
                --print('nabbed line: '..bonusStr)
                break
            end
        end
    end
        
    local gemBonusStr = ''
    -- Extract Gem bonus from string
    local enchantBonusStr = ''
    if bonusStr:len()>0 then
        gemBonusStr = ConvertTooltipToStatStr( bonusStr )
    end
    return gemBonusStr
end


local function ParseItemStatsFromTooltip(link)
    SimulationcraftTooltip:ClearLines()
    SimulationcraftTooltip:SetHyperlink(link)
    local numLines = SimulationcraftTooltip:NumLines()

    local stats_conv = {
        ["Stamina"] = "sta",
        ["Agility"] = "agi",
        ["Intellect"] = "int",
        ["Strength"] = "str",
        ["Spirit"] = "spi",
        ["Hit"] = "hit",
        ["Expertise"] = "exp",
        ["Critical Strike"] = "crit",
        ["Spell Power"] = "sp",
        ["Mastery"] = "mastery",
        ["Haste"] = "haste"
    }

    local stat_begin = ",stats="
    local stat_str = ""
    for i=2, numLines, 1 do
        local tmpText = _G["SimulationcraftTooltipTextLeft"..i]
        if (tmpText:GetText()) then
            local line = tmpText:GetText()
            if ( string.sub(line, 0, 1) == '+') then
                -- line = +5,310 Agility
                local stat_seperator = string.find(line, " ")
                local stat_name = string.sub(line, stat_seperator + 1)
                local reforge_idx = string.find(stat_name, "%(Reforged")
                if reforge_idx then stat_name = string.sub(stat_name, 0, reforge_idx - 2) end

                -- num = 5310, stat = agi
                local stat = stats_conv[stat_name]
                if stat then
                    local num = string.gsub(string.sub(line, 2, stat_seperator - 1), ",", "")
                    if string.len(stat_str)>0 then
                        stat_str = stat_str .. "_" .. num .. stat
                    else
                        stat_str = num .. stat
                    end
                end
            end
        end
    end
    return stat_begin .. stat_str
end

local function SynapseCheck()
    local synapseName, _ = GetSpellInfo(141330) 
    if GetItemSpell(GetInventoryItemLink("player", 10)) then
        if string.find(GetItemSpell(GetInventoryItemLink("player", 10)), synapseName) then
            return true
        else 
            return false
        end
    end
end

function Simulationcraft:GetItemStuffs()
    local items = {}
    for slotNum=1, #slotNames do
        local slotId = GetInventorySlotInfo( slotNames[slotNum] )
        local itemLink = GetInventoryItemLink('player', slotId)
        local simcItemStr 
        
        -- if we don't have an item link, we don't care
        if itemLink then
            local itemString = string.match(itemLink, "item[%-?%d:]+")
            simcDebug(itemString)
            local _, itemId, enchantId, gemId1, gemId2, gemId3, gemId4, _, _, _, reforgeId, upgradeId = strsplit(":", itemString)

            local name = GetItemInfo( itemId )
            local upgradeLevel = upgradeTable[tonumber(upgradeId)]
            if upgradeLevel == nil then
              upgradeLevel = 0
              simc_err_str = simc_err_str .. '\n # WARNING: upgradeLevel nil for upgradeId ' .. upgradeId .. ' in itemString ' .. itemString
            end
            
            if not bonusId then
              bonusId = "0"
            end
            
            --=====Gems======
            -- determine number of sockets
            local statTable = GetItemStats(itemLink)
            local numSockets = 0
            for stat, value in pairs(statTable) do
                if string.match(stat, 'SOCKET') then
                    numSockets = numSockets + value
                end                
            end
            
            --simcDebug( itemLink )
            --simcDebug(enchantId)
            
            -- Gems are super easy if item id style is set
            local gemString=''
            if self.db.profile.newStyle then
                local useBonus=true
                if numSockets>0 then
                    SocketInventoryItem(slotId)
                    for i=1, numSockets do
                        local name,_,matches = GetExistingSocketInfo(i)
                        --if name then print(name) else print('no Gem') end
                        --if matches then print(matches) end
                        if not matches then
                            useBonus=false
                        end
                        local name,gemLink = GetItemGem(itemLink,i)
                        --simcDebug(gemLink)
                        if (name and gemLink) then
                            local gemBonus = GetGemBonus(gemLink)
                            --simcDebug(gemBonus)
                            if GetSocketTypes(i) == "Meta" then gemBonus = name:gsub("%s+", "_"):lower():gsub("_diamond", "") end
                            if gemString:len()>0 then
                                gemString=gemString .. '_' .. gemBonus
                            else
                                gemString=gemBonus
                            end
                        end
                    end
                    -- check for an extra socket (BS, belt buckle)
                    local name,gemLink = GetItemGem(itemLink,numSockets+1)
                    --simcDebug(gemLink)
                    if gemLink then
                        gemBonus = GetGemBonus(gemLink)
                        if gemString:len()>0 then 
                            gemString = gemString .. '_' .. gemBonus
                        else
                            gemString = gemBonus
                        end
                    end
                    CloseSocketInfo()
                    if useBonus then
                        socketBonus=GetSocketBonus(itemLink)
                        gemString = gemString .. '_' .. socketBonus
                    end
                    -- construct final gem string
                    gemString = ',gems=' .. gemString
                end
                --simcDebug(gemString)
              -- and a giant pain in the ass otherwise. Lots of tooltip parsing
            else
                -- check for socket bonus activation and gems
                local useBonus=true
                if numSockets>0 then
                    SocketInventoryItem(slotId)
                    for i=1, numSockets do
                        local name,_,matches = GetExistingSocketInfo(i)
                        --if name then print(name) else print('no Gem') end
                        --if matches then print(matches) end
                        if not matches then
                            useBonus=false
                        end
                        local name,gemLink = GetItemGem(itemLink,i)
                        --simcDebug(gemLink)
                        local gemBonus = GetGemBonus(gemLink)
                        --simcDebug(gemBonus)
                        if gemString:len()>0 then
                            gemString=gemString .. '_' .. gemBonus
                        else
                            gemString=gemBonus
                        end
                    end
                    -- check for an extra socket (BS, belt buckle)
                    local name,gemLink = GetItemGem(itemLink,numSockets+1)
                    --simcDebug(gemLink)
                    if gemLink then
                        gemBonus = GetGemBonus(gemLink)
                        if gemString:len()>0 then 
                            gemString = gemString .. '_' .. gemBonus
                        else
                            gemString = gemBonus
                        end
                    end
                    CloseSocketInfo()
                    if useBonus then
                        socketBonus=GetSocketBonus(itemLink)
                        gemString = gemString .. '_' .. socketBonus
                    end
                    -- construct final gem string
                    gemString = ',gems=' .. gemString
                end
            end
            
            --simcDebug('Starting Enchant Section')
            --simcDebug(enchantId)
            --=====Enchants======
            -- Enchants are super easy if item id style is set
            local enchantString=''
            if self.db.profile.newStyle then
                --simcDebug('New Style')
                --simcDebug(enchantId)
                enchantBonus=GetEnchantBonus(itemLink)
                if enchantBonus:len()>0 then
                    enchantString = ',enchant=' .. enchantBonus
                else
                    enchantString = ',enchant=' .. tokenize(enchantNames[tonumber(enchantId)])
                end
                --simcDebug(enchantString)
            else
                -- if this is a 'special' enchant, it's in enchantNames and we can just use that
                --simcDebug('Checking Special')
                --simcDebug(enchantId)
                if enchantNames[tonumber(enchantId)] then
                    --simcDebug('enchantNames[tonumber(enchantId)] is:')
                    --simcDebug(enchantNames[tonumber(enchantId)])
                    enchantString = ',enchant=' .. tokenize(enchantNames[tonumber(enchantId)])
                else
                -- otherwise we need some tooltip scanning
                    --simcDebug('Scanning Tooltip')
                    enchantBonus=GetEnchantBonus(itemLink)
                    if enchantBonus:len()>0 then
                        enchantString= ',enchant=' .. enchantBonus
                    end
                end
            end
            
            local reforgeString = CreateSimcReforgeString(itemLink)
            local statsString = ParseItemStatsFromTooltip(itemLink)
            --gemString ..
        --printable_link = gsub(itemLink, "\124", "\124\124");
        --print(printable_link);
        simcItemStr = simcSlotNames[slotNum] .. "=" .. tokenize(name) .. ",id=" .. itemId --[[.. ",upgrade=" .. upgradeLevel]] .. statsString .. gemString .. enchantString --[[..reforgeString]]
          --print('#sockets = '..numSockets .. ', bonus = ' .. tostring(useBonus))
          --print( simcItemStr )
        end

        if slotNum == 9 and SynapseCheck() then 
            simcItemStr = simcItemStr .. ",addon=synapse_springs_mark_ii"
        end

        items[slotNum] = simcItemStr
    end
    
    return items
end

-- This is the workhorse function that constructs the profile
function Simulationcraft:PrintSimcProfile()
    -- get basic player info
    local playerName = UnitName('player')
    local _, playerClass = UnitClass('player')
    local playerLevel = UnitLevel('player')
    local _, playerRace = UnitRace('player')
    local playerSpec, role
    local specId = GetSpecialization()
    -- change elf race strings to be compatible with simc parsing
    if (string.lower(playerRace) == 'bloodelf') then
        playerRace = 'blood_elf'
    end
    if (string.lower(playerRace) == 'nightelf') then
        playerRace = 'night_elf'
    end
    if specId then
      _, playerSpec,_,_,_,role = GetSpecializationInfo(specId)
    end
    
    local p1, p2 = GetProfessions()
    local playerProfessionOne, playerProfessionOneRank, playerProfessionTwo, playerProfessionTwoRank
    if p1 then
      playerProfessionOne,_,playerProfessionOneRank = GetProfessionInfo(p1)
    end
    if p2 then
      playerProfessionTwo,_,playerProfessionTwoRank = GetProfessionInfo(p2)
    end
    local realm = GetRealmName() -- not used yet (possibly for origin)

    -- get player info that's a little more involved
    local playerTalents = CreateSimcTalentString()
    local playerGlyphs = CreateSimcGlyphString()
    
    -- construct some strings from the basic information
    local player = tokenize(playerClass) .. '=' .. tokenize(playerName)
    playerLevel = 'level=' .. playerLevel
    playerRace = 'race=' .. tokenize(playerRace)
    playerRole = 'role=' .. translateRole(role)
    playerSpec = 'spec=' .. tokenize(playerSpec)
    local playerProfessions = ''
    if p1 or p2 then
      playerProfessions = 'professions='
      if p1 then
        playerProfessions = playerProfessions..tokenize(playerProfessionOne)..'='..tostring(playerProfessionOneRank)..'/'
      end
      if p2 then
        playerProfessions = playerProfessions..tokenize(playerProfessionTwo)..'='..tostring(playerProfessionTwoRank)
      end  
    else
      playerProfessions = ''    
    end
    
    
    -- output construction
    local simulationcraftProfile = player .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerLevel .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerRace .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerRole .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerProfessions .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerTalents .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerGlyphs .. '\n'
    simulationcraftProfile = simulationcraftProfile .. playerSpec .. '\n\n'
        
    -- get gear info
    local items = Simulationcraft:GetItemStuffs()
    -- output gear 
    for slotNum=1, #slotNames do
        if items[slotNum] then
            simulationcraftProfile = simulationcraftProfile .. items[slotNum] .. '\n'
        end
    end
    
    -- sanity checks - if there's anything that makes the output completely invalid, punt!
    if specId==nil then
      simulationcraftProfile = "Error: You need to pick a spec!"
    end
    
    -- append any error info
    simulationcraftProfile = simulationcraftProfile .. '\n\n' ..simc_err_str
         
    -- show the appropriate frames
    SimcCopyFrame:Show()
    SimcCopyFrameScroll:Show()
    SimcCopyFrameScrollText:Show()
    SimcCopyFrameScrollText:SetText(simulationcraftProfile)
    SimcCopyFrameScrollText:HighlightText()
    -- Abandoned GUI code from earlier implementations
    --[[
    self.exportFrame:Show()
    self.ebox:Show()
    -- put the text in the editbox and highlight it for copy/paste
    self.ebox.EditBox:SetText(simulationcraftProfile)
    --self.ebox.editBox:HighlightText()
    self.ebox.EditBox:SetFocus()
    self.ebox.EditBox:HighlightText()
    --]]
    
end
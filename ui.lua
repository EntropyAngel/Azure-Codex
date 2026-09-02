require('common');
local imgui = require('imgui');
local json = require('json');
local settings = require('settings');
local ffi = require('ffi');
local codex_sets = require('codex_sets');
local chat = require('chat');

local default_ui_settings = T{
    background_opacity = T{ 0.88 },
    panel_opacity = T{ 0.92 },
    card_opacity = T{ 0.93 },
    unknown_spell_popup = T{ true },
    learned_spell_popup = T{ true },
    popup_duration = T{ 8.0 },
    learned_popup_duration = T{ 6.0 },
    learned_spell_sound = T{ true },
    learned_spell_volume = T{ 75.0 },
};
local saved_ui_settings = settings.load(default_ui_settings);

local ui = {
    counts = T{
        known   = 0,
        missing = 0,
        total   = 0,
    },
    data = T{},
    spells = T{},
    zone = T{},

    is_open = { false, },
    active_tab = 1,
    settings = saved_ui_settings,

    theme = {
        bg          = { 0.035, 0.045, 0.060, 0.96 },
        panel       = { 0.065, 0.080, 0.105, 0.94 },
        panel_alt   = { 0.085, 0.105, 0.135, 0.94 },
        border      = { 0.20, 0.30, 0.40, 0.85 },
        accent      = { 0.20, 0.72, 0.95, 1.00 },
        accent_dim  = { 0.12, 0.34, 0.48, 1.00 },
        gold        = { 1.00, 0.72, 0.22, 1.00 },
        green       = { 0.30, 0.90, 0.48, 1.00 },
        red         = { 1.00, 0.34, 0.34, 1.00 },
        text        = { 0.92, 0.95, 1.00, 1.00 },
        muted       = { 0.58, 0.66, 0.74, 1.00 },
    },

    tab_spells = {
        selected = { -1, },
    },

    tab_zonehelper = {
        selected = { -1, },
    },

    tab_traits = {
        selected = { 1, },
    },

    tab_sets = {
        selected = { 1, },
        files = T{},
        last_refresh = 0,
        status = '',
        edit_spells = T{},
        edit_name = { '' },
        edit_name_size = 128,
        spell_search = { '' },
        spell_search_size = 128,
        edit_slot = { 1, },
        learned_spells = T{},
        learned_count = 0,
        dirty = false,
        detail_skillchain = nil,
        active_name = '',
        last_active_check = 0,
    },
 };

ffi.cdef[[
    int PlaySoundA(const char* pszSound, void* hmod, unsigned int fdwSound);
]];

local winmm = nil;
pcall(function () winmm = ffi.load('winmm'); end);

ui.learn_sound_missing_warned = false;

function ui.get_learn_sound_path()
    local volume = 75.0;
    if ui.settings.learned_spell_volume ~= nil then
        volume = tonumber(ui.settings.learned_spell_volume[1]) or 75.0;
    end
    volume = math.max(0.0, math.min(100.0, volume));
    if volume <= 0.0 then return nil; end

    local step = math.floor((volume + 5.0) / 10.0) * 10;
    step = math.max(10, math.min(100, step));
    return ('%s\\addons\\AzureCodex\\sounds\\volume\\chocobo_kweh_%03d.wav'):fmt(AshitaCore:GetInstallPath(), step);
end

function ui.play_learned_spell_sound()
    if ui.settings.learned_spell_sound and ui.settings.learned_spell_sound[1] == false then
        return false;
    end
    if winmm == nil then return false; end

    local path = ui.get_learn_sound_path();
    if path == nil then return false; end
    if not ashita.fs.exists(path) then
        if not ui.learn_sound_missing_warned then
            ui.learn_sound_missing_warned = true;
        end
        return false;
    end

    winmm.PlaySoundA(path, nil, 0x00020003);
    return true;
end

ui.spell_alert = {
    visible = false,
    spell = nil,
    mob = 'Monster',
    target = 'Party / Alliance',
    started = 0,
    last_key = '',
    last_time = 0,
};

ui.learn_alert = {
    visible = false,
    spell = nil,
    started = 0,
    last_key = '',
    last_time = 0,
};

function ui.find_spell_by_id(spellId)
    for _, sp in ipairs(ui.spells or {}) do
        if tonumber(sp.index) == tonumber(spellId) then
            return sp;
        end
    end
    return nil;
end

function ui.show_learned_spell_alert(spell)
    if spell == nil then return false; end
    if ui.settings.learned_spell_popup and ui.settings.learned_spell_popup[1] == false then return false; end

    local now = os.clock();
    local key = tostring(spell.index or spell.name or '');
    if ui.learn_alert.last_key == key and (now - (ui.learn_alert.last_time or 0)) < 1.50 then
        return false;
    end

    ui.learn_alert.visible = true;
    ui.learn_alert.spell = spell;
    ui.learn_alert.started = now;
    ui.learn_alert.last_key = key;
    ui.learn_alert.last_time = now;
    ui.play_learned_spell_sound();
    return true;
end

ui.ability_aliases = {
    ['evryone grudge'] = 'everyone grudge',
    ['nat meditation'] = 'nature meditation',
    ['o counterstance'] = 'orcish counterstance',
    ['tem upheaval'] = 'tempestuous upheaval',
};

function ui.normalize_ability_name(name)
    local s = tostring(name or ''):lower();
    s = s:gsub('[’`]', "'");
    s = s:gsub("'s", '');
    s = s:gsub('[^%w]+', ' ');
    s = s:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ');
    return ui.ability_aliases[s] or s;
end

function ui.find_unknown_spell_for_ability(abilityName)
    local key = ui.normalize_ability_name(abilityName);
    if key == '' then return nil; end
    for _, sp in ipairs(ui.spells) do
        if not sp.known and ui.normalize_ability_name(sp.name) == key then
            return sp;
        end
    end
    return nil;
end

function ui.get_party_alliance_lookup()
    local lookup = {};
    local names = {};
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party == nil then return lookup, names; end
    for i = 0, 17 do
        local sid = tonumber(party:GetMemberServerId(i)) or 0;
        if sid ~= 0 then
            lookup[sid] = true;
            names[sid] = party:GetMemberName(i) or ('Member %d'):fmt(i + 1);
        end
    end
    return lookup, names;
end

function ui.get_entity_name_by_server_id(serverId)
    local sid = tonumber(serverId) or 0;
    if sid == 0 then return 'Monster'; end
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if entity == nil then return 'Monster'; end

    local idx = bit.band(sid, 0x0FFF);
    if idx > 0 and entity:GetServerId(idx) == sid then
        local name = entity:GetName(idx);
        if name ~= nil and name ~= '' then return name; end
    end

    for i = 1, 2303 do
        if entity:GetServerId(i) == sid then
            local name = entity:GetName(i);
            if name ~= nil and name ~= '' then return name; end
            break;
        end
    end
    return 'Monster';
end

function ui.show_unknown_spell_alert(spell, actorId, targetId, targetNames, mobName)
    local now = os.clock();
    local duplicateKey = tostring(spell and spell.name or '');
    if ui.spell_alert.last_key == duplicateKey and (now - (ui.spell_alert.last_time or 0)) < 2.0 then
        return;
    end
    ui.spell_alert.last_key = duplicateKey;
    ui.spell_alert.last_time = now;
    if spell == nil or spell.known then return; end
    if ui.settings.unknown_spell_popup and ui.settings.unknown_spell_popup[1] == false then return; end

    local mob = mobName or ui.get_entity_name_by_server_id(actorId);
    local target = (targetNames and targetNames[targetId]) or 'Party / Alliance';
    local key = tostring(actorId) .. ':' .. tostring(spell.index);
    local now = os.clock();

    if ui.spell_alert.last_key == key and (now - ui.spell_alert.last_time) < 0.75 then
        return;
    end

    ui.spell_alert.visible = true;
    ui.spell_alert.spell = spell;
    ui.spell_alert.mob = mob;
    ui.spell_alert.target = target;
    ui.spell_alert.started = now;
    ui.spell_alert.last_key = key;
    ui.spell_alert.last_time = now;
end

local function packet_has_bits(data, bitOffset, bitCount)
    if type(data) ~= 'string' then return false; end
    local startBit = tonumber(bitOffset) or -1;
    local count = tonumber(bitCount) or 0;
    if startBit < 0 or count < 1 then return false; end
    return (startBit + count) <= (#data * 8);
end

local function safe_unpack_be(data, bitOffset, bitCount)
    if not packet_has_bits(data, bitOffset, bitCount) then return nil; end
    return ashita.bits.unpack_be(data, bitOffset, bitCount);
end

local function safe_struct_unpack(fmt, data, byteOffset)
    if type(data) ~= 'string' then return nil; end
    local sizes = { b = 1, B = 1, h = 2, H = 2, l = 4, L = 4, i = 4, I = 4 };
    local size = sizes[fmt];
    local offset = tonumber(byteOffset) or -1;
    if size == nil or offset < 1 or (offset + size - 1) > #data then return nil; end
    return struct.unpack(fmt, data, offset);
end

function ui.handle_battle_action(e)
    if e == nil or e.id ~= 0x0028 then return; end

    local data = e.data_raw;
    if type(data) ~= 'string' or #data < 22 then return; end

    local actorId = safe_unpack_be(data, 40, 32);
    local targetCount = safe_unpack_be(data, 72, 6);
    local actionType = safe_unpack_be(data, 82, 4);
    local actionId = safe_unpack_be(data, 86, 17);
    if actorId == nil or targetCount == nil or actionType == nil or actionId == nil then return; end
    if targetCount < 1 or targetCount > 32 then return; end
    if actionType ~= 7 or actionId == 0 then return; end
    if not ui.is_enemy_monster_server_id(actorId) then return; end

    local monsterAbilityId = actionId - 256;
    if monsterAbilityId < 0 then return; end
    local abilityName = AshitaCore:GetResourceManager():GetString('monsters.abilities', monsterAbilityId);
    if abilityName == nil or abilityName == '' then return; end

    local spell = ui.find_unknown_spell_for_ability(abilityName);
    if spell == nil then return; end

    local partyLookup, partyNames = ui.get_party_alliance_lookup();
    local bitOffset = 150;

    for _ = 1, targetCount do
        local targetId = safe_unpack_be(data, bitOffset, 32);
        if targetId == nil then return; end
        bitOffset = bitOffset + 32;

        local encodedActionCount = safe_unpack_be(data, bitOffset, 4);
        if encodedActionCount == nil then return; end
        local actionCount = encodedActionCount + 1;
        bitOffset = bitOffset + 4;
        if actionCount < 1 or actionCount > 16 then return; end

        if partyLookup[targetId] then
            ui.show_unknown_spell_alert(spell, actorId, targetId, partyNames);
            return;
        end

        for _ = 1, actionCount do
            local fixedBits = 5 + 12 + 7 + 3 + 17 + 10 + 31;
            if not packet_has_bits(data, bitOffset, fixedBits + 1) then return; end
            bitOffset = bitOffset + fixedBits;

            local hasAdditional = safe_unpack_be(data, bitOffset, 1);
            if hasAdditional == nil then return; end
            bitOffset = bitOffset + 1;
            if hasAdditional == 1 then
                local additionalBits = 10 + 17 + 10;
                if not packet_has_bits(data, bitOffset, additionalBits) then return; end
                bitOffset = bitOffset + additionalBits;
            end

            local hasSpikes = safe_unpack_be(data, bitOffset, 1);
            if hasSpikes == nil then return; end
            bitOffset = bitOffset + 1;
            if hasSpikes == 1 then
                local spikesBits = 10 + 14 + 10;
                if not packet_has_bits(data, bitOffset, spikesBits) then return; end
                bitOffset = bitOffset + spikesBits;
            end
        end
    end
end

function ui.clean_log_text(message)
    local s = tostring(message or '');
    s = s:gsub('[%z\1-\8\11\12\14-\31]', '');
    s = s:gsub('[\r\n\t]', ' ');
    s = s:gsub('%s+', ' ');
    s = s:gsub('^%s+', ''):gsub('%s+$', '');
    return s;
end

function ui.mark_spell_learned(spell)
    if spell == nil then return false; end
    local changed = false;
    ui.spells:each(function (v)
        if tonumber(v.index) == tonumber(spell.index) then
            if not v.known then changed = true; end
            v.known = true;
            spell = v;
        end
    end);
    ui.show_learned_spell_alert(spell);
    ui.get_spell_counts();
    ui.refresh_zone_helper();
    return changed;
end

function ui.get_entity_index_by_server_id(serverId)
    local sid = tonumber(serverId) or 0;
    if sid == 0 then return nil; end
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if entity == nil then return nil; end

    local idx = bit.band(sid, 0x0FFF);
    if idx > 0 and entity:GetServerId(idx) == sid then return idx; end

    for i = 1, 2303 do
        if entity:GetServerId(i) == sid then return i; end
    end
    return nil;
end

function ui.get_entity_index_by_name(name)
    local wanted = tostring(name or ''):lower();
    if wanted == '' then return nil; end
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if entity == nil then return nil; end

    for i = 1, 2303 do
        local n = entity:GetName(i);
        if n ~= nil and tostring(n):lower() == wanted then return i; end
    end
    return nil;
end

function ui.is_enemy_monster_entity(index)
    if index == nil then return false; end
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    if entity == nil then return false; end
    local flags = tonumber(entity:GetSpawnFlags(index)) or 0;

    if bit.band(flags, 0x0010) ~= 0x0010 then return false; end
    if bit.band(flags, 0x0100) == 0x0100 then return false; end
    return true;
end

function ui.is_enemy_monster_server_id(serverId)
    return ui.is_enemy_monster_entity(ui.get_entity_index_by_server_id(serverId));
end

function ui.is_enemy_monster_name(name)
    return ui.is_enemy_monster_entity(ui.get_entity_index_by_name(name));
end

function ui.text_in(e)
    if e == nil or e.injected then return; end

    local raw = e.message_modified;
    if raw == nil or raw == '' then raw = e.message; end
    local clean = ui.clean_log_text(raw);
    if clean == '' then return; end

    local lower = clean:lower();

    if lower:find('you learn', 1, true) or lower:find('learned blue magic', 1, true) then
        for _, sp in ipairs(ui.spells or {}) do
            local spellName = tostring(sp.name or ''):lower();
            if spellName ~= '' and lower:find(spellName, 1, true) then
                ui.mark_spell_learned(sp);
                return;
            end
        end
    end

    if lower:find('readies', 1, true) or lower:find(' uses ', 1, true) then
        local actor = clean:match('^(.-)%s+[Rr][Ee][Aa][Dd][Ii][Ee][Ss]%s+');
        if actor == nil then actor = clean:match('^(.-)%s+[Uu][Ss][Ee][Ss]%s+'); end
        if actor == nil or actor == '' then return; end
        actor = actor:gsub('^[Tt]he%s+', '');

        if not ui.is_enemy_monster_name(actor) then return; end

        for _, sp in ipairs(ui.spells or {}) do
            if not sp.known then
                local spellName = tostring(sp.name or '');
                local key = spellName:lower();
                if key ~= '' and lower:find(key, 1, true) then
                    ui.show_unknown_spell_alert(sp, 0, 0, nil, actor);
                    return;
                end
            end
        end
    end
end

ui.blu_points = {
    ptr = ffi.cast('uint8_t***', ashita.memory.find(0, 0,
        'A1????????33C98A4E5E33D28A565D5F5E8950148948185B83C414C20400', 1, 0)),
};

ui.blu_spell_costs = {
    [513]=3,[515]=5,[517]=1,[519]=3,[521]=4,[522]=2,[524]=2,[527]=3,
    [529]=2,[530]=4,[531]=3,[532]=4,[533]=3,[534]=4,[535]=1,[536]=1,
    [537]=2,[538]=4,[539]=3,[540]=4,[541]=3,[542]=2,[543]=2,[544]=2,
    [545]=4,[547]=1,[548]=3,[549]=1,[551]=1,[554]=5,[555]=3,[557]=4,
    [560]=3,[561]=3,[563]=3,[564]=4,[565]=4,[567]=2,[569]=4,[570]=2,
    [572]=1,[573]=3,[574]=2,[575]=4,[576]=3,[577]=2,[578]=3,[579]=4,
    [581]=4,[582]=2,[584]=2,[585]=4,[587]=2,[588]=2,[589]=5,[591]=4,
    [592]=2,[593]=3,[594]=3,[595]=5,[596]=2,[597]=2,[598]=4,[599]=2,
    [603]=3,[604]=5,[605]=3,[606]=2,[608]=3,[610]=4,[611]=5,[612]=4,
    [613]=5,[614]=3,[615]=5,[616]=5,[617]=3,[618]=2,[620]=3,[621]=2,
    [622]=2,[623]=3,[626]=3,[628]=3,[629]=3,[631]=3,[632]=3,[633]=5,
    [634]=5,[636]=4,[637]=5,[638]=3,[640]=4,[641]=5,[642]=3,[643]=3,
    [644]=4,[645]=4,[646]=4,[647]=2,[648]=1,[650]=2,[651]=4,[652]=3,
    [653]=2,[654]=4,[655]=3,[656]=3,[657]=3,[658]=4,[659]=4,[660]=3,
    [661]=5,[662]=3,[663]=4,[664]=2,[665]=1,[666]=3,[667]=2,[668]=3,
    [669]=2,[670]=4,[671]=4,[672]=5,[673]=4,[674]=1,[675]=3,[677]=3,
    [678]=3,[679]=3,[680]=4,[681]=5,[682]=2,[683]=4,[684]=4,[685]=3,
    [686]=4,[687]=2,[688]=2,[689]=3,[690]=5,[692]=4,[693]=5,[694]=3,
    [695]=4,[696]=5,[697]=4,[698]=2,[699]=2,[700]=6,[701]=6,[702]=6,
    [703]=6,[704]=6,[705]=3,[706]=2,[707]=5,[708]=6,[709]=7,[710]=6,
    [711]=7,[712]=6,[713]=6,[714]=6,[715]=6,[716]=6,[717]=6,[718]=6,
    [719]=8,[720]=8,[721]=8,[722]=8,[723]=7,[724]=7,[725]=8,[726]=8,
    [727]=8,[728]=8,
};


ui.horizon_blu_spell_costs = {
    ['sandspin']=2, ['pollen']=1, ['foot kick']=2,
    ['power attack']=1, ['sprout smack']=2, ['wild oats']=3,
    ['metallic body']=3, ['cocoon']=1, ['queasyshroom']=2,
    ['battle dance']=3, ['head butt']=3, ['feather storm']=3,
    ['helldive']=2, ['healing breeze']=4, ['sheep song']=2,
    ['bludgeon']=2, ['cursed sphere']=2, ['blastbomb']=2,
    ['blood drain']=2, ['claw cyclone']=2, ['poison breath']=1,
    ['soporific']=4, ['screwdriver']=3, ['vanity dive']=2,
    ['bomb toss']=3, ['grand slam']=2, ['wild carrot']=3,
    ['empty thrash']=3, ['chaotic eye']=2, ['sound blast']=1,
    ['death ray']=2, ['smite of rage']=3, ['digest']=2,
    ['pinecone bomb']=2, ['occultation']=3, ['blank gaze']=2,
    ['jet stream']=4, ['uppercut']=3, ['mysterious light']=4,
    ['terror touch']=3, ['auroral drape']=4, ['mp drainkiss']=4,
    ['venom shell']=3, ['blitzstrahl']=4, ['mandibular bite']=2,
    ['stinking gas']=2, ['awful eye']=2, ['geist wall']=4,
    ['magnetite cloud']=3, ['blood saber']=3, ['jettatura']=4,
    ['refueling']=4, ['sickle slash']=4, ['frightful roar']=3,
    ['ice break']=3, ['self-destruct']=3, ['cold wave']=1,
    ['filamented hold']=3, ['quadratic continuum']=4,
    ['hecatomb wave']=3, ['radiant breath']=4,
    ['winds of promyvion']=5, ['feather barrier']=2,
    ['flying hip press']=3, ['light of penance']=5, ['magic fruit']=3,
    ['death scissors']=5, ['dimensional death']=5, ['spiral spin']=3,
    ['bad breath']=5, ['eyes on me']=4, ['maelstrom']=5,
    ['seedspray']=2, ['1000 needles']=5, ['body slam']=4,
    ['memento mori']=4, ['frenetic rip']=3, ['frypan']=3,
    ['hydro shot']=3, ['spinal cleave']=4, ['feather tickle']=2,
    ['voracious trunk']=4, ['yawn']=3, ['infrasonics']=4,
    ['zephyr mantle']=2, ['frost breath']=3, ['sandspray']=2,
    ['corrosive ooze']=4, ['diamondhide']=3, ['enervation']=5,
    ['firespit']=5, ['warm-up']=4, ['hysteric barrage']=5,
    ['tail slap']=4, ['regurgitation']=1, ['amplification']=3,
    ['cannonball']=3, ['asuran claws']=2, ['heat breath']=4,
    ['lowing']=2, ['triumphant roar']=3, ['disseverment']=5,
    ['sub-zero smash']=4, ['saline coat']=3, ['mind blast']=4,
    ['ram charge']=4, ['temporal shift']=5, ['actinic burst']=4,
    ['magic hammer']=4, ['reactor cool']=5, ['exuviation']=4,
    ['plasma charge']=4, ['vertical cleave']=3,
};

local function normalize_blu_spell_name(name)
    return tostring(name or ''):lower():gsub('^%s+', ''):gsub('%s+$', '');
end

ui.live_blu_spell_costs = ui.live_blu_spell_costs or {};

function ui.get_blu_cost_cache_path()
    local base = ('%s\\config\\addons\\AzureCodex\\'):fmt(AshitaCore:GetInstallPath());
    if not ashita.fs.exists(base) then ashita.fs.create_dir(base); end
    return base .. 'blu_costs.txt';
end

function ui.load_live_blu_costs()
    ui.live_blu_spell_costs = {};
    local f = io.open(ui.get_blu_cost_cache_path(), 'r');
    if f == nil then return; end
    for line in f:lines() do
        local name, cost = tostring(line):match('^(.-)%s+(%d+)$');
        cost = tonumber(cost);
        if name ~= nil and name ~= '' and cost ~= nil and cost > 0 and cost <= 20 then
            ui.live_blu_spell_costs[normalize_blu_spell_name(name)] = cost;
        end
    end
    f:close();
end

function ui.save_live_blu_costs()
    local f = io.open(ui.get_blu_cost_cache_path(), 'w+');
    if f == nil then return false; end
    local keys = {};
    for name,_ in pairs(ui.live_blu_spell_costs or {}) do table.insert(keys, name); end
    table.sort(keys);
    for _,name in ipairs(keys) do
        f:write(name, '\t', tostring(ui.live_blu_spell_costs[name]), '\n');
    end
    f:close();
    return true;
end

function ui.learn_live_blu_spell_cost(name, cost)
    local key = normalize_blu_spell_name(name);
    cost = tonumber(cost);
    if key == '' or cost == nil or cost <= 0 or cost > 20 then return; end
    if ui.live_blu_spell_costs[key] ~= cost then
        ui.live_blu_spell_costs[key] = cost;
        ui.save_live_blu_costs();
    end
end

function ui.get_blu_spell_cost(name_or_id)
    if type(name_or_id) == 'string' then
        local live = ui.live_blu_spell_costs[normalize_blu_spell_name(name_or_id)];
        if live ~= nil then return live; end
        local byName = ui.horizon_blu_spell_costs[normalize_blu_spell_name(name_or_id)];
        if byName ~= nil then return byName; end
    end

    local id = tonumber(name_or_id);
    if id == nil then
        local sp = ui.find_spell_by_name and ui.find_spell_by_name(name_or_id) or nil;
        if sp ~= nil then
            local live = ui.live_blu_spell_costs[normalize_blu_spell_name(sp.name)];
            if live ~= nil then return live; end
            local byName = ui.horizon_blu_spell_costs[normalize_blu_spell_name(sp.name)];
            if byName ~= nil then return byName; end
            id = sp.index;
        end
    else
        local spell = AshitaCore:GetResourceManager():GetSpellById(id);
        if spell ~= nil and spell.Name ~= nil then
            local nm = spell.Name[1] or spell.Name[0];
            local live = ui.live_blu_spell_costs[normalize_blu_spell_name(nm)];
            if live ~= nil then return live; end
            local byName = ui.horizon_blu_spell_costs[normalize_blu_spell_name(nm)];
            if byName ~= nil then return byName; end
        end
    end
    return id and (ui.blu_spell_costs[id] or 0) or 0;
end

function ui.get_editor_set_points(spells)
    local total = 0;
    for i=1,20 do
        local name = tostring((spells or {})[i] or '');
        if name ~= '' then total = total + ui.get_blu_spell_cost(name); end
    end
    return total;
end

function ui.get_current_blu_level()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local party = AshitaCore:GetMemoryManager():GetParty();
    if player == nil then return 75; end

    local lvl = 75;
    if party ~= nil then
        local ok, v = pcall(function()
            if player:GetMainJob() == 16 then return party:GetMemberMainJobLevel(0); end
            if player:GetSubJob() == 16 then return party:GetMemberSubJobLevel(0); end
            return 75;
        end);
        if ok and tonumber(v) and tonumber(v) > 0 then lvl = tonumber(v); end
    end
    return math.max(1, math.min(75, lvl));
end

function ui.get_blu_point_cap()
    local ok, liveMax = pcall(function()
        if ui.blu_points ~= nil and ui.blu_points[0] ~= nil and ui.blu_points[0][0] ~= nil then
            return tonumber(ui.blu_points[0][0][0x18]);
        end
        return nil;
    end);
    if ok and liveMax ~= nil and liveMax >= 1 and liveMax <= 100 then
        return liveMax;
    end

    local lvl = ui.get_current_blu_level();
    if lvl <= 10 then return 10 elseif lvl <= 20 then return 15 elseif lvl <= 30 then return 20
    elseif lvl <= 40 then return 25 elseif lvl <= 50 then return 30 elseif lvl <= 60 then return 35
    elseif lvl <= 70 then return 40 else return 45 end
end

function ui.get_blu_spell_slot_cap()
    local lvl = ui.get_current_blu_level();
    if lvl <= 10 then return 6 elseif lvl <= 20 then return 8 elseif lvl <= 30 then return 10
    elseif lvl <= 40 then return 12 elseif lvl <= 50 then return 14 elseif lvl <= 60 then return 16
    elseif lvl <= 70 then return 18 else return 20 end
end

function ui.validate_editor_blu_budget(spells)
    local usedPoints = ui.get_editor_set_points(spells);
    local pointCap = ui.get_blu_point_cap();
    local usedSlots = 0;
    for i = 1, 20 do
        if tostring((spells or {})[i] or '') ~= '' then usedSlots = usedSlots + 1; end
    end
    local slotCap = ui.get_blu_spell_slot_cap();
    if usedPoints > pointCap then
        return false, ('Set is over Horizon Blue Points: %d / %d BP.'):fmt(usedPoints, pointCap);
    end
    if usedSlots > slotCap then
        return false, ('Set is over Horizon spell slots: %d / %d.'):fmt(usedSlots, slotCap);
    end
    return true, '';
end

local ROMAN_TIERS = { 'I','II','III','IV','V','VI','VII','VIII' };
function ui.get_trait_tier_label(tier)
    return ROMAN_TIERS[tonumber(tier) or 0] or tostring(tier or '');
end

ui.blu_set = {
    offset = ffi.cast('uint32_t*', ashita.memory.find(0, 0,
        'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0)),
    names = T{},
    lookup = {},
    last_refresh = 0,
    valid = false,
};

function ui.refresh_equipped_blu_spells(force)
    local now = os.clock();
    if not force and (now - (ui.blu_set.last_refresh or 0)) < 0.35 then return; end
    ui.blu_set.last_refresh = now;
    ui.blu_set.names = T{};
    ui.blu_set.lookup = {};
    ui.blu_set.valid = false;

    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return; end
    local mainBlu = player:GetMainJob() == 16;
    local subBlu = player:GetSubJob() == 16;
    if not mainBlu and not subBlu then return; end
    if ui.blu_set.offset == nil or tonumber(ffi.cast('uintptr_t', ui.blu_set.offset)) == 0 then return; end

    local inv = AshitaCore:GetPointerManager():Get('inventory');
    if inv == nil or inv == 0 then return; end
    local ptr = ashita.memory.read_uint32(inv);
    if ptr == 0 then return; end
    ptr = ashita.memory.read_uint32(ptr);
    if ptr == 0 then return; end

    local base = (ptr + ui.blu_set.offset[0]) + (mainBlu and 0x04 or 0xA0);
    local raw = ashita.memory.read_array(base, 0x14);
    if raw == nil then return; end

    for i = 1, #raw do
        local v = tonumber(raw[i]) or 0;
        if v ~= 0 then
            local res = AshitaCore:GetResourceManager():GetSpellById(v + 512);
            if res ~= nil and res.Name ~= nil and res.Name[1] ~= nil then
                local name = res.Name[1];
                ui.blu_set.names:append(name);
                ui.blu_set.lookup[name] = true;
            end
        end
    end
    ui.blu_set.valid = true;
end

function ui.is_spell_equipped(name)
    return ui.blu_set.lookup[name] == true;
end

function ui.get_trait_thresholds(trait)
    local out = {};
    for n in tostring(trait.tiers or ''):gmatch(':%s*(%d+)') do
        table.insert(out, tonumber(n));
    end
    if #out == 0 then table.insert(out, trait.special and 8 or 2); end
    return out;
end

function ui.get_trait_equipped_points(trait)
    local pts, count = 0, 0;
    local equipped = {};
    for _, ts in ipairs(trait.spells) do
        if ui.is_spell_equipped(ts.name) then
            count = count + 1;
            pts = pts + (ts.weight or 1);
            table.insert(equipped, ts.name);
        end
    end
    return count, pts, equipped;
end

function ui.get_trait_active_tier(trait)
    local _, pts = ui.get_trait_equipped_points(trait);
    local tier = 0;
    for _, threshold in ipairs(ui.get_trait_thresholds(trait)) do
        if pts >= threshold then tier = tier + 1; end
    end
    return tier, pts;
end

function ui.get_active_trait_count()
    local count = 0;
    for _, trait in ipairs(ui.traits or {}) do
        local tier = ui.get_trait_active_tier(trait);
        if tier > 0 then count = count + 1; end
    end
    return count;
end

ui.traits = {
    { name='Accuracy Bonus', tiers='I: 2 trait pts', spells={
        {name='Dimensional Death', level=60, set=5, weight=1},
        {name='Frenetic Rip', level=63, set=3, weight=1},
        {name='Disseverment', level=72, set=5, weight=1},
    }},
    { name='Attack Bonus', tiers='I: 2  |  II: 4 trait pts', spells={
        {name='Battle Dance', level=12, set=3, weight=1},
        {name='Uppercut', level=38, set=3, weight=1},
        {name='Death Scissors', level=60, set=5, weight=1},
        {name='Spinal Cleave', level=63, set=4, weight=1},
        {name='Temporal Shift', level=73, set=5, weight=1},
    }},
    { name='Auto Regen', tiers='I: 2 trait pts', spells={
        {name='Sheep Song', level=16, set=2, weight=1},
        {name='Healing Breeze', level=16, set=4, weight=1},
    }},
    { name='Auto Refresh', tiers='I: 8 Auto Refresh pts', special=true, spells={
        {name='Stinking Gas', level=44, set=2, weight=1},
        {name='Geist Wall', level=46, set=4, weight=3},
        {name='Frightful Roar', level=50, set=3, weight=2},
        {name='Self-Destruct', level=50, set=3, weight=2},
        {name='Cold Wave', level=52, set=1, weight=1},
        {name='Light of Penance', level=58, set=5, weight=3},
        {name='Voracious Trunk', level=64, set=4, weight=3},
        {name='Actinic Burst', level=74, set=4, weight=4},
        {name='Plasma Charge', level=75, set=5, weight=4},
    }},
    { name='Beast Killer', tiers='I: 2  |  II: 4 trait pts', spells={
        {name='Wild Oats', level=4, set=3, weight=1},
        {name='Sprout Smack', level=4, set=2, weight=1},
        {name='Seedspray', level=61, set=2, weight=1},
        {name='1000 Needles', level=62, set=5, weight=1},
    }},
    { name='Clear Mind', tiers='I: 2  |  II: 4  |  III: 6  |  IV: 8 trait pts', spells={
        {name='Poison Breath', level=22, set=1, weight=1},
        {name='Soporific', level=24, set=4, weight=1},
        {name='Venom Shell', level=42, set=3, weight=1},
        {name='Awful Eye', level=46, set=2, weight=1},
        {name='Filamented Hold', level=52, set=3, weight=1},
        {name='Maelstrom', level=61, set=5, weight=1},
        {name='Feather Tickle', level=64, set=3, weight=1},
        {name='Sandspray', level=66, set=2, weight=1},
        {name='Corrosive Ooze', level=66, set=4, weight=1},
        {name='Warm-Up', level=68, set=4, weight=1},
        {name='Lowing', level=71, set=2, weight=1},
        {name='Mind Blast', level=73, set=4, weight=1},
    }},
    { name='Conserve MP', tiers='I: 2  |  II: 4 trait pts', spells={
        {name='Chaotic Eye', level=32, set=2, weight=1},
        {name='Zephyr Mantle', level=65, set=2, weight=1},
        {name='Frost Breath', level=66, set=3, weight=1},
        {name='Firespit', level=68, set=5, weight=1},
    }},
    { name='Counter', tiers='I: 2 trait pts', spells={
        {name='Enervation', level=67, set=5, weight=1},
        {name='Asuran Claws', level=70, set=2, weight=1},
    }},
    { name='Defense Bonus', tiers='I: 2  |  II: 4 trait pts', spells={
        {name='Grand Slam', level=30, set=2, weight=1},
        {name='Terror Touch', level=40, set=3, weight=1},
        {name='Saline Coat', level=72, set=3, weight=1},
        {name='Vertical Cleave', level=75, set=3, weight=1},
    }},
    { name='Evasion Bonus', tiers='I: 2 trait pts', spells={
        {name='Screwdriver', level=26, set=3, weight=1},
        {name='Hysteric Barrage', level=69, set=5, weight=1},
    }},
    { name='Fast Cast', tiers='I: 2 trait pts', spells={
        {name='Bad Breath', level=61, set=5, weight=1},
        {name='Sub-Zero Smash', level=72, set=4, weight=1},
    }},
    { name='Lizard Killer', tiers='I: 2 trait pts', spells={
        {name='Foot Kick', level=1, set=2, weight=1},
        {name='Claw Cyclone', level=20, set=2, weight=1},
        {name='Ram Charge', level=73, set=4, weight=1},
    }},
    { name='Magic Attack Bonus', tiers='I: 2  |  II: 4  |  III: 6 trait pts', spells={
        {name='Cursed Sphere', level=18, set=2, weight=1},
        {name='Sound Blast', level=32, set=1, weight=1},
        {name='Eyes On Me', level=61, set=4, weight=1},
        {name='Memento Mori', level=62, set=4, weight=1},
        {name='Heat Breath', level=71, set=4, weight=1},
        {name='Magic Hammer', level=74, set=4, weight=1},
        {name='Reactor Cool', level=75, set=5, weight=1},
    }},
    { name='Magic Defense Bonus', tiers='I: 2 trait pts', spells={
        {name='Magnetite Cloud', level=46, set=3, weight=1},
        {name='Ice Break', level=50, set=3, weight=1},
    }},
    { name='Max HP Boost', tiers='I: 2 trait pts', spells={
        {name='Flying Hip Press', level=58, set=3, weight=1},
        {name='Body Slam', level=62, set=4, weight=1},
        {name='Frypan', level=63, set=3, weight=1},
    }},
    { name='Max MP Boost', tiers='I: 2 trait pts', spells={
        {name='Metallic Body', level=8, set=3, weight=1},
        {name='Mysterious Light', level=40, set=4, weight=1},
        {name='Hecatomb Wave', level=54, set=3, weight=1},
    }},
    { name='Plantoid Killer', tiers='I: 2 trait pts', spells={
        {name='Power Attack', level=4, set=1, weight=1},
        {name='Mandibular Bite', level=44, set=2, weight=1},
        {name='Spiral Spin', level=60, set=3, weight=1},
    }},
    { name='Rapid Shot', tiers='I: 2 trait pts', spells={
        {name='Feather Storm', level=12, set=3, weight=1},
        {name='Jet Stream', level=38, set=4, weight=1},
        {name='Hydro Shot', level=63, set=3, weight=1},
    }},
    { name='Resist Gravity', tiers='I: 2 trait pts', spells={
        {name='Feather Barrier', level=56, set=2, weight=1},
        {name='Regurgitation', level=69, set=1, weight=1},
    }},
    { name='Resist Sleep', tiers='I: 2  |  II: 4 trait pts', spells={
        {name='Pollen', level=1, set=1, weight=1},
        {name='Wild Carrot', level=30, set=3, weight=1},
        {name='Magic Fruit', level=58, set=3, weight=1},
        {name='Yawn', level=64, set=3, weight=1},
        {name='Exuviation', level=75, set=4, weight=1},
    }},
    { name='Store TP', tiers='I: 2 trait pts', spells={
        {name='Sickle Slash', level=48, set=4, weight=1},
        {name='Tail Slap', level=69, set=4, weight=1},
    }},
    { name='Undead Killer', tiers='I: 2 trait pts', spells={
        {name='Bludgeon', level=18, set=2, weight=1},
        {name='Smite of Rage', level=34, set=3, weight=1},
    }},
};


function ui.get_codex_sets_path()
    return ('%s\\config\\addons\\AzureCodex\\sets\\'):fmt(AshitaCore:GetInstallPath());
end

function ui.get_legacy_blusets_path()
    return ('%s\\config\\addons\\blusets\\'):fmt(AshitaCore:GetInstallPath());
end

function ui.ensure_codex_sets_path()
    local base = ('%s\\config\\addons\\AzureCodex\\'):fmt(AshitaCore:GetInstallPath());
    local path = ui.get_codex_sets_path();
    if not ashita.fs.exists(base) then ashita.fs.create_dir(base); end
    if not ashita.fs.exists(path) then ashita.fs.create_dir(path); end
end

function ui.read_blu_set_path(path)
    local f = io.open(path, 'r');
    if f == nil then return T{}; end
    local spells = T{};
    for line in f:lines() do spells:append(tostring(line or ''):trim()); end
    f:close();
    while #spells < 20 do spells:append(''); end
    while #spells > 20 do table.remove(spells); end
    return spells;
end

function ui.copy_set_spells(spells)
    local out = T{};
    for i = 1, 20 do out:append(tostring((spells or {})[i] or '')); end
    return out;
end

function ui.load_set_into_editor(entry)
    if entry == nil then return; end
    ui.tab_sets.edit_name[1] = entry.name;
    ui.tab_sets.edit_spells = ui.copy_set_spells(entry.spells);
    ui.tab_sets.edit_slot[1] = math.max(1, math.min(20, ui.tab_sets.edit_slot[1] or 1));
    ui.tab_sets.dirty = false;
end

function ui.refresh_blu_set_files(force)
    local now = os.clock();
    if not force and (now - (ui.tab_sets.last_refresh or 0)) < 1.0 then return; end
    ui.tab_sets.last_refresh = now;
    ui.ensure_codex_sets_path();
    local path = ui.get_codex_sets_path();
    local files = ashita.fs.get_dir(path, '.*.txt', true) or {};

    local source = 'codex';
    if #files == 0 then
        local legacy = ui.get_legacy_blusets_path();
        if ashita.fs.exists(legacy) then
            files = ashita.fs.get_dir(legacy, '.*.txt', true) or {};
            if #files > 0 then path = legacy; source = 'legacy'; end
        end
    end

    table.sort(files, function(a,b) return tostring(a):lower() < tostring(b):lower(); end);
    ui.tab_sets.files = T{};
    for _, file in ipairs(files) do
        local name = tostring(file):gsub('%.txt$', '');
        ui.tab_sets.files:append({ name=name, spells=ui.read_blu_set_path(path .. file), source=source });
    end
    if #ui.tab_sets.files == 0 then
        ui.tab_sets.selected[1] = -1;
    elseif ui.tab_sets.selected[1] < 1 or ui.tab_sets.selected[1] > #ui.tab_sets.files then
        ui.tab_sets.selected[1] = 1;
    end
    if ui.tab_sets.selected[1] > 0 and not ui.tab_sets.dirty then
        ui.load_set_into_editor(ui.tab_sets.files[ui.tab_sets.selected[1]]);
    end
end

function ui.refresh_active_blu_set(force)
    local now = os.clock();
    if not force and (now - (ui.tab_sets.last_active_check or 0)) < 0.50 then return; end
    ui.tab_sets.last_active_check = now;
    ui.tab_sets.active_name = '';

    local current = codex_sets.get_current_spell_ids();
    if current == nil then
        codex_sets.active_name = '';
        return;
    end

    for _, entry in ipairs(ui.tab_sets.files or {}) do
        local matches = true;
        for i = 1, 20 do
            local expected = codex_sets.get_spell_id(entry.spells[i]);
            if expected == nil or (tonumber(current[i]) or 0) ~= (tonumber(expected) or 0) then
                matches = false;
                break;
            end
        end
        if matches then
            ui.tab_sets.active_name = entry.name;
            codex_sets.active_name = entry.name;
            return;
        end
    end

    codex_sets.active_name = '';
end

function ui.sanitize_set_name(name)
    name = tostring(name or ''):trim('\0'):trim();
    name = name:gsub('[\\/:*?"<>|]', '_');
    return name;
end

function ui.save_editor_set(save_as_new)
    ui.ensure_codex_sets_path();
    local name = ui.sanitize_set_name(ui.tab_sets.edit_name[1]);
    if name == '' then
        ui.tab_sets.status = 'Enter a set name first.';
        return false;
    end
    local budgetOk, budgetMsg = ui.validate_editor_blu_budget(ui.tab_sets.edit_spells);
    if not budgetOk then
        ui.tab_sets.status = budgetMsg;
        return false;
    end
    local path = ui.get_codex_sets_path() .. name .. '.txt';
    if save_as_new and ashita.fs.exists(path) then
        ui.tab_sets.status = 'That AzureCodex set already exists.';
        return false;
    end
    local f = io.open(path, 'w+');
    if f == nil then ui.tab_sets.status = 'Could not save the set file.'; return false; end
    for i = 1, 20 do
        f:write(tostring(ui.tab_sets.edit_spells[i] or ''));
        if i < 20 then f:write('\n'); end
    end
    f:close();
    ui.tab_sets.status = ('Saved "%s" in AzureCodex.'):fmt(name);
    ui.tab_sets.dirty = false;
    ui.refresh_blu_set_files(true);
    for i,e in ipairs(ui.tab_sets.files) do
        if e.name == name then ui.tab_sets.selected[1] = i; ui.load_set_into_editor(e); break; end
    end
    return true;
end

function ui.new_editor_set()
    ui.tab_sets.selected[1] = -1;
    ui.tab_sets.edit_name[1] = 'New Set';
    ui.tab_sets.edit_spells = T{};
    for i = 1, 20 do ui.tab_sets.edit_spells:append(''); end
    ui.tab_sets.edit_slot[1] = 1;
    ui.tab_sets.spell_search[1] = '';
    ui.tab_sets.dirty = true;
    ui.tab_sets.detail_skillchain = nil;
    ui.tab_sets.status = 'New set ready. Pick spells, name it, then Save.';
end

function ui.delete_selected_set()
    local idx = ui.tab_sets.selected[1] or -1;
    local entry = idx > 0 and ui.tab_sets.files[idx] or nil;
    if entry == nil or entry.source ~= 'codex' then
        ui.tab_sets.status = 'Legacy BluSets files are read-only here; save it into AzureCodex first.';
        return;
    end
    local deletedName = entry.name;
    local path = ui.get_codex_sets_path() .. deletedName .. '.txt';
    if ashita.fs.exists(path) then ashita.fs.remove(path); end

    ui.tab_sets.selected[1] = -1;
    ui.tab_sets.edit_name[1] = '';
    ui.tab_sets.edit_spells = T{};
    for i = 1, 20 do ui.tab_sets.edit_spells:append(''); end
    ui.tab_sets.edit_slot[1] = 1;
    ui.tab_sets.spell_search[1] = '';
    ui.tab_sets.dirty = false;

    ui.refresh_blu_set_files(true);
    ui.tab_sets.status = ('Deleted "%s" and cleared the editor.'):fmt(deletedName);
end

function ui.get_set_lookup(spells)
    local lookup = {};
    for _, name in ipairs(spells or {}) do
        if name ~= nil and name ~= '' then lookup[name] = true; end
    end
    return lookup;
end

function ui.get_trait_points_for_lookup(trait, lookup)
    local pts = 0;
    for _, ts in ipairs(trait.spells or {}) do
        if lookup[ts.name] then pts = pts + (ts.weight or 1); end
    end
    local tier = 0;
    for _, threshold in ipairs(ui.get_trait_thresholds(trait)) do
        if pts >= threshold then tier = tier + 1; end
    end
    return tier, pts;
end

function ui.get_active_traits_for_set(spells)
    local lookup = ui.get_set_lookup(spells);
    local active = {};
    for _, trait in ipairs(ui.traits or {}) do
        local tier, pts = ui.get_trait_points_for_lookup(trait, lookup);
        if tier > 0 then table.insert(active, { name=trait.name, tier=tier, points=pts }); end
    end
    return active;
end

ui.azure_sc_elements = {
    Transfixion={'Light'}, Liquefaction={'Fire'}, Impaction={'Lightning'}, Detonation={'Wind'},
    Compression={'Dark'}, Scission={'Earth'}, Reverberation={'Water'}, Induration={'Ice'},
    Fusion={'Light','Fire'}, Fragmentation={'Lightning','Wind'}, Gravitation={'Dark','Earth'},
    Distortion={'Water','Ice'}, Light={'Light','Fire','Lightning','Wind'}, Darkness={'Dark','Earth','Water','Ice'},
};

ui.azure_sc_links = {
    Impaction={Liquefaction='Liquefaction',Detonation='Detonation'},
    Scission={Liquefaction='Liquefaction',Detonation='Detonation',Reverberation='Reverberation'},
    Reverberation={Impaction='Impaction',Induration='Induration'},
    Induration={Impaction='Impaction',Compression='Compression',Reverberation='Fragmentation'},
    Compression={Detonation='Detonation',Transfixion='Transfixion'},
    Liquefaction={Scission='Scission',Impaction='Fusion'},
    Detonation={Scission='Scission',Compression='Gravitation'},
    Transfixion={Reverberation='Reverberation',Compression='Compression',Scission='Distortion'},
    Distortion={Fusion='Fusion',Gravitation='Darkness'},
    Gravitation={Fragmentation='Fragmentation',Distortion='Darkness'},
    Fusion={Gravitation='Gravitation',Fragmentation='Light'},
    Fragmentation={Distortion='Distortion',Fusion='Light'},
    Light={Light='Light'}, Darkness={Darkness='Darkness'},
};

ui.azure_blu_sc = {
    ['Foot Kick']={'Detonation'}, ['Power Attack']={'Reverberation'}, ['Sprout Smack']={'Reverberation'},
    ['Wild Oats']={'Transfixion'}, ['Queasyshroom']={'Compression'}, ['Battle Dance']={'Impaction'},
    ['Feather Storm']={'Transfixion'}, ['Head Butt']={'Impaction'}, ['Helldive']={'Transfixion'},
    ['Bludgeon']={'Liquefaction'}, ['Claw Cyclone']={'Scission'}, ['Screwdriver']={'Transfixion','Scission'},
    ['Grand Slam']={'Induration'}, ['Smite of Rage']={'Detonation'}, ['Pinecone Bomb']={'Liquefaction'},
    ['Jet Stream']={'Impaction'}, ['Uppercut']={'Liquefaction','Impaction'}, ['Terror Touch']={'Compression','Reverberation'},
    ['Mandibular Bite']={'Induration'}, ['Sickle Slash']={'Compression'}, ['Death Scissors']={'Compression','Reverberation'},
    ['Dimensional Death']={'Transfixion','Impaction'}, ['Spiral Spin']={'Transfixion'}, ['Seedspray']={'Induration','Detonation'},
    ['Body Slam']={'Impaction'}, ['Frenetic Rip']={'Induration'}, ['Frypan']={'Impaction'}, ['Hydro Shot']={'Reverberation'},
    ['Spinal Cleave']={'Scission'}, ['Hysteric Barrage']={'Detonation'}, ['Tail Slap']={'Reverberation'},
    ['Asuran Claws']={'Liquefaction','Impaction'}, ['Cannonball']={'Fusion'}, ['Disseverment']={'Distortion'},
    ['Ram Charge']={'Fragmentation'}, ['Vertical Cleave']={'Gravitation'},
};

ui.azure_blu_ws = {
    {id=32,name='Fast Blade',weapon='Sword',props={'Scission'}},
    {id=33,name='Burning Blade',weapon='Sword',props={'Liquefaction'}},
    {id=34,name='Red Lotus Blade',weapon='Sword',props={'Liquefaction','Detonation'}},
    {id=35,name='Flat Blade',weapon='Sword',props={'Impaction'}},
    {id=36,name='Shining Blade',weapon='Sword',props={'Scission'}},
    {id=37,name='Seraph Blade',weapon='Sword',props={'Scission','Transfixion'}},
    {id=38,name='Circle Blade',weapon='Sword',props={'Reverberation','Impaction'}},
    {id=40,name='Vorpal Blade',weapon='Sword',props={'Scission','Impaction'}},
    {id=41,name='Swift Blade',weapon='Sword',props={'Gravitation'}},
    {id=42,name='Savage Blade',weapon='Sword',props={'Fragmentation','Scission'}},
    {id=43,name='Knights of Round',weapon='Sword',props={'Light','Fusion'}},
    {id=160,name='Shining Strike',weapon='Club',props={'Transfixion'}},
    {id=161,name='Seraph Strike',weapon='Club',props={'Scission'}},
    {id=162,name='Brainshaker',weapon='Club',props={'Reverberation'}},
    {id=165,name='Skullbreaker',weapon='Club',props={'Induration','Reverberation'}},
    {id=166,name='True Strike',weapon='Club',props={'Detonation','Impaction'}},
    {id=167,name='Judgment',weapon='Club',props={'Impaction'}},
    {id=168,name='Hexa Strike',weapon='Club',props={'Fusion'}},
    {id=169,name='Black Halo',weapon='Club',props={'Fragmentation','Compression'}},
    {id=170,name='Randgrith',weapon='Club',props={'Light','Fragmentation'}},
};

ui.azure_magic_damage_spells = {
    ['Sandspin']=true, ['Cursed Sphere']=true, ['Blastbomb']=true, ['Bomb Toss']=true,
    ['Poison Breath']=true, ['Death Ray']=true, ['Maelstrom']=true, ['Mysterious Light']=true,
    ['Eyes On Me']=true, ['Hecatomb Wave']=true, ['Radiant Breath']=true, ['Flying Hip Press']=true,
    ['Frost Breath']=true, ['Heat Breath']=true, ['Firespit']=true, ['Regurgitation']=true,
    ['Mind Blast']=true, ['Magic Hammer']=true,
};

function ui.azure_get_sc_result(open_props, close_props)
    for _, opener in ipairs(open_props or {}) do
        local links = ui.azure_sc_links[opener];
        if links ~= nil then
            for _, closer in ipairs(close_props or {}) do
                local result = links[closer];
                if result ~= nil then return result; end
            end
        end
    end
    return nil;
end

function ui.azure_is_spell_known(name)
    local sp = ui.find_spell_by_name(name);
    return sp ~= nil and sp.known == true;
end

function ui.azure_get_burst_spells_for_set(spells, sc_name)
    local elements = ui.azure_sc_elements[sc_name] or {};
    local wanted = {};
    for _, e in ipairs(elements) do wanted[e] = true; end
    local out = {};
    for _, name in ipairs(spells or {}) do
        if name ~= nil and name ~= '' and ui.azure_magic_damage_spells[name] then
            local sp = ui.find_spell_by_name(name);
            if sp ~= nil and sp.known == true then
                local element = ui.get_spell_element(sp.element);
                if wanted[element] then table.insert(out, name); end
            end
        end
    end
    return out, elements;
end

function ui.azure_get_known_burst_spells(sc_name)
    local elements = ui.azure_sc_elements[sc_name] or {};
    local wanted = {};
    for _, e in ipairs(elements) do wanted[e] = true; end
    local out = {};
    local seen = {};
    for _, sp in ipairs(ui.spells or {}) do
        if sp ~= nil and sp.known == true and sp.name ~= nil and ui.azure_magic_damage_spells[sp.name] then
            local element = ui.get_spell_element(sp.element);
            if wanted[element] and not seen[sp.name] then
                seen[sp.name] = true;
                table.insert(out, sp.name);
            end
        end
    end
    table.sort(out);
    return out, elements;
end

function ui.azure_find_blu_sc(name)
    local wanted = tostring(name or ''):trim():lower();
    if wanted == '' then return nil, nil; end
    for spellName, props in pairs(ui.azure_blu_sc) do
        if tostring(spellName):lower() == wanted then return spellName, props; end
    end
    return nil, nil;
end

function ui.azure_get_equipped_weapon()
    local ok, weapon, name = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory();
        if inv == nil then return nil, nil; end

        local equipped = inv:GetEquippedItem(0);
        if equipped == nil or equipped.Index == nil or equipped.Index == 0 then
            return nil, nil;
        end

        local container = bit.band(equipped.Index, 0xFF00) / 0x0100;
        local index = bit.band(equipped.Index, 0x00FF);
        if index == 0 then return nil, nil; end

        local item = inv:GetContainerItem(container, index);
        if item == nil or item.Id == nil or item.Id == 0 then
            return nil, nil;
        end

        local res = AshitaCore:GetResourceManager():GetItemById(item.Id);
        if res == nil then return nil, nil; end

        local weaponType = nil;
        if tonumber(res.Skill) == 3 then
            weaponType = 'Sword';
        elseif tonumber(res.Skill) == 11 then
            weaponType = 'Club';
        end

        local itemName = nil;
        if res.Name ~= nil then
            if type(res.Name) == 'string' then
                itemName = tostring(res.Name);
            elseif res.Name[1] ~= nil and tostring(res.Name[1]) ~= '' then
                itemName = tostring(res.Name[1]);
            elseif res.Name[2] ~= nil and tostring(res.Name[2]) ~= '' then
                itemName = tostring(res.Name[2]);
            elseif res.Name[0] ~= nil and tostring(res.Name[0]) ~= '' then
                itemName = tostring(res.Name[0]);
            end
        end
        if itemName == nil or itemName == '' or itemName == '???' then
            itemName = weaponType or ('Item %d'):fmt(item.Id);
        end
        return weaponType, itemName;
    end);

    if not ok then return nil, nil; end
    return weapon, name;
end

function ui.azure_has_weapon_skill(ws_id)
    local ok, known = pcall(function()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if player == nil or player.HasWeaponSkill == nil then return false; end
        return player:HasWeaponSkill(tonumber(ws_id) or 0) == true;
    end);
    return ok and known == true;
end

function ui.azure_get_set_skillchains(spells)
    local out = {};
    local weaponType = ui.azure_get_equipped_weapon();
    if weaponType == nil then return out; end

    for _, raw_name in ipairs(spells or {}) do
        local blu_name, blu_props = ui.azure_find_blu_sc(raw_name);
        if blu_props ~= nil and ui.azure_is_spell_known(blu_name) then
            for _, ws in ipairs(ui.azure_blu_ws) do
                if ws.weapon == weaponType and ui.azure_has_weapon_skill(ws.id) then
                    local result = ui.azure_get_sc_result(ws.props, blu_props);
                    if result ~= nil then
                        local bursts, elements = ui.azure_get_burst_spells_for_set(spells, result);
                        table.insert(out, {
                            ws=ws.name, weapon=ws.weapon, blu=blu_name, result=result,
                            bursts=bursts, elements=elements, direction='WS -> BLU'
                        });
                    end

                    local reverse = ui.azure_get_sc_result(blu_props, ws.props);
                    if reverse ~= nil then
                        local bursts, elements = ui.azure_get_burst_spells_for_set(spells, reverse);
                        table.insert(out, {
                            ws=ws.name, weapon=ws.weapon, blu=blu_name, result=reverse,
                            bursts=bursts, elements=elements, direction='BLU -> WS'
                        });
                    end
                end
            end
        end
    end

    table.sort(out, function(a,b)
        local rank = {Light=4,Darkness=4,Fusion=3,Fragmentation=3,Gravitation=3,Distortion=3,
            Transfixion=2,Liquefaction=2,Impaction=2,Detonation=2,Compression=2,Scission=2,Reverberation=2,Induration=2};
        local ar, br = rank[a.result] or 1, rank[b.result] or 1;
        if ar ~= br then return ar > br; end
        if a.ws ~= b.ws then return a.ws < b.ws; end
        if a.blu ~= b.blu then return a.blu < b.blu; end
        return a.direction < b.direction;
    end);
    return out;
end

function ui.azure_get_all_skillchains_for_result(sc_name, weapon_type)
    local out = {};
    local seen = {};
    if sc_name == nil or sc_name == '' or weapon_type == nil then return out; end

    for blu_name, blu_props in pairs(ui.azure_blu_sc or {}) do
        if ui.azure_is_spell_known(blu_name) then
        for _, ws in ipairs(ui.azure_blu_ws or {}) do
            if ws.weapon == weapon_type and ui.azure_has_weapon_skill(ws.id) then
                local result = ui.azure_get_sc_result(ws.props, blu_props);
                if result == sc_name then
                    local key = ws.name .. '|WS -> BLU|' .. blu_name;
                    if not seen[key] then
                        seen[key] = true;
                        table.insert(out, { ws=ws.name, blu=blu_name, result=result, direction='WS -> BLU' });
                    end
                end

                local reverse = ui.azure_get_sc_result(blu_props, ws.props);
                if reverse == sc_name then
                    local key = ws.name .. '|BLU -> WS|' .. blu_name;
                    if not seen[key] then
                        seen[key] = true;
                        table.insert(out, { ws=ws.name, blu=blu_name, result=reverse, direction='BLU -> WS' });
                    end
                end
            end
        end
        end
    end

    table.sort(out, function(a, b)
        if a.ws ~= b.ws then return a.ws < b.ws; end
        if a.blu ~= b.blu then return a.blu < b.blu; end
        return a.direction < b.direction;
    end);
    return out;
end

function ui.azure_is_spell_in_set(spells, wanted_name)
    local wanted = tostring(wanted_name or ''):lower();
    if wanted == '' then return false; end
    for _, name in ipairs(spells or {}) do
        if tostring(name or ''):lower() == wanted then return true; end
    end
    return false;
end

function ui.apply_saved_blu_set(entry)
    if entry == nil then return; end
    if codex_sets.applying then
        ui.tab_sets.status = 'A set is already being applied.';
        return;
    end
    if not codex_sets.can_apply() then
        ui.tab_sets.status = 'BLU must be your main job or support job.';
        return;
    end
    local budgetOk, budgetMsg = ui.validate_editor_blu_budget(entry.spells);
    if not budgetOk then
        ui.tab_sets.status = budgetMsg;
        return;
    end
    ui.tab_sets.status = ('Applying "%s"...'):fmt(entry.name);
    local ok = codex_sets.apply(entry.name, entry.spells, function(success, failed)
        ui.refresh_equipped_blu_spells(true);
        ui.refresh_active_blu_set(true);
        if success then
            ui.tab_sets.status = ('Applied "%s" and verified all spell slots.'):fmt(entry.name);
            print(chat.header(addon.name):append(chat.message('Applied and verified BLU spell set: ')):append(chat.success(entry.name)));
        else
            local detail = (failed ~= nil and #failed > 0) and table.concat(failed, ', ') or 'unknown slot';
            ui.tab_sets.status = ('Set apply incomplete after retries: %s'):fmt(detail);
            print(chat.header(addon.name):append(chat.error('BLU spell set apply incomplete after retries: ')):append(chat.warning(detail)));
        end
    end, function(spell_name, actual_cost)
        ui.learn_live_blu_spell_cost(spell_name, actual_cost);
    end);
    if not ok then ui.tab_sets.status = 'Could not start set application.'; end
end

function ui.apply_editor_set()
    local name = ui.sanitize_set_name(ui.tab_sets.edit_name[1]);
    if name == '' then name = 'Unsaved Set'; end
    ui.apply_saved_blu_set({ name=name, spells=ui.copy_set_spells(ui.tab_sets.edit_spells) });
end

function ui.find_spell_by_name(name)
    for _, sp in ipairs(ui.spells) do
        if sp.name == name then return sp; end
    end
    return nil;
end

function ui.get_trait_known_points(trait)
    local pts = 0;
    local known = 0;
    for _, ts in ipairs(trait.spells) do
        local sp = ui.find_spell_by_name(ts.name);
        if sp ~= nil and sp.known then
            known = known + 1;
            pts = pts + (ts.weight or 1);
        end
    end
    return known, pts;
end

function ui.get_spell_element(t)
    return switch(t, {
        [0] = function () return 'Fire'; end,
        [1] = function () return 'Ice'; end,
        [2] = function () return 'Wind'; end,
        [3] = function () return 'Earth'; end,
        [4] = function () return 'Lightning'; end,
        [5] = function () return 'Water'; end,
        [6] = function () return 'Light'; end,
        [7] = function () return 'Dark'; end,
        [15] = function () return '(None)'; end,
        [switch.default] = function () return tostring(t); end
    });
end

function ui.get_spell_data(id)
    local _, v = ui.data:findkey(tostring(id));
    return v or T{};
end

ui.horizon_verified_mobs = {
    ['Foot Kick']       = { 'Wild Rabbit', 'Forest Hare', 'Savanna Rarab', 'Pit Hare', 'Hoarder Hare', 'Steppe Hare', 'Canyon Rarab' },
    ['Pollen']          = { 'Huge Hornet', 'Bumblebee', 'Maneating Hornet', 'Giddeus Bee', 'Giant Bee', 'Huge Wasp', 'Killer Bee', 'Digger Wasp' },
    ['Sandspin']        = { 'Tunnel Worm', 'Carrion Worm', 'Stone Eater', 'Dirt Eater', 'Rock Eater', 'Bigmouth Billy', 'Giant Grub', 'Earth Eater', 'Maze Maker', 'Land Worm', 'Desert Worm' },
    ['Power Attack']    = { 'Scarab Beetle', 'Fungus Beetle', 'Copper Beetle', 'Beady Beetle', 'Stag Beetle', "Goblin's Beetle", 'Dung Beetle', 'Diving Beetle', 'Goliath Beetle', 'Flying Beetle', 'Sand Beetle', 'Borer Beetle', 'Nest Beetle', 'Desert Beetle', 'Helm Beetle', 'Blazer Beetle', 'Den Beetle', 'Chamber Beetle', 'Armet Beetle', 'Starmite' },
    ['Sprout Smack']    = { 'Walking Sapling', 'Strolling Sapling', 'Wandering Sapling', 'Stalking Sapling', 'Slash Pine', 'Sobbing Sapling', 'Caveberry', 'Leshachikha' },
    ['Wild Oats']       = { 'Tiny Mandragora', 'Mandragora', 'Pygmaioi', 'Sylvestre', 'Yuhtunga Mandragora', 'Yhoator Mandragora', 'Alraune', 'Mourioche', 'Korrigan', 'Puck' },
    ['Cocoon']          = { 'Crawler', 'Spiny Spipi', 'Canyon Crawler', 'Carnivorous Crawler', 'Caterpillar', 'Berry Grub', 'Silk Caterpillar', 'Worker Crawler' },
    ['Metallic Body']   = { 'River Crab' },
    ['Queasyshroom']    = { 'Forest Funguar', 'Toadstool', 'Cave Funguar', 'Grass Funguar', 'Poison Funguar', 'Fly Agaric', 'Marsh Funguar', 'Jugner Funguar', 'Shrieker', 'Myconid' },
    ['Battle Dance']    = { 'Orcish Fodder', 'Orcish Grappler', 'Orcish Mesmerizer' },
    ['Feather Storm']   = { 'Yagudo Acolyte', 'Yagudo Initiate', 'Yagudo Scribe', 'Yagudo Mendicant' },
    ['Head Butt']       = { 'Amber Quadav', 'Amethyst Quadav' },
    ['Healing Breeze']  = { 'Wild Dhalmel', 'Bull Dhalmel', 'Cape Dhalmel', 'Marine Dhalmel', 'Desert Dhalmel' },
    ['Helldive']        = { 'Carrion Crow', 'Vulture', 'Akbaba', 'Jubjub', 'Screamer', 'Zu', 'Ba', 'Raven', 'Toucan', 'Riverne Vulture', 'Tragopan', 'Flamingo' },
    ['Sheep Song']      = { 'Wild Sheep', 'Ornery Sheep', 'Mad Sheep', 'Brutal Sheep', 'Charging Sheep', 'Tavnazian Sheep', "Gigas's Sheep", 'Broo', 'Wild Karakul' },
    ['Cursed Sphere']   = { 'Gadfly', 'Crane Fly', 'Damselfly', 'May Fly', 'Sadfly', 'Gallinipper' },
    ['Poison Breath']   = { 'Mad Fox', 'Tainted Hound', 'Black Wolf', 'Wolf Zombie', 'Barghest', 'Bog Dog', 'Scavenging Hound', 'Bandersnatch', 'Mauthe Doog', 'Drooling Hound', 'Marchosias', 'Hell Hound', 'Tomb Wolf', 'Hecatomb Hound', 'Cwn Annwn', 'Garm', 'Hati' },
    ['Soporific']       = { 'Flytrap', 'Battrap', 'Fishtrap', 'Birdtrap', 'Hawkertrap', 'Mantrap', 'Puktrap' },
    ['Screwdriver']     = { 'Pugil', 'Giddeus Pugil', 'Ghelsba Pugil', 'Pug Pugil', 'Giant Pugil', 'Land Pugil' },
    ['Bomb Toss']       = { 'Goblin Ambusher', 'Goblin Butcher' },
    ['Wild Carrot']     = { "Goblin's Rarab", 'Island Rarab', 'Variable Hare', 'Polar Hare' },
    ['Sound Blast']     = { 'Axe Beak', 'Tabar Beak', 'Deadly Dodo', 'Cockatrice', 'Skewer Sam', 'Waraxe Beak', 'Sand Cockatrice', 'Ziz', 'Greater Cockatrice' },
    ['Chaotic Eye']     = { 'Coeurl', 'Puma', 'Champaign Coeurl', 'Jungle Coeurl', 'Attohwa Coeurl', 'Master Coeurl', 'Rime Lynx', 'Torama', 'Boreal Coeurl' },
    ['Death Ray']       = { 'Hecteyes', 'Taisai', 'Argus', 'Sobbing Eyes', 'Compound Eyes', 'Gazer' },
    ['Ram Charge']      = { 'Battering Ram', 'Lumbering Lambert', 'Bloodtear Baldurf', 'Tremor Ram', 'Rampaging Ram', 'Steelfleece Baldarich', 'Tavnazian Ram', 'Mosshorn' },
    ['Sandspray']       = { 'Qiqirn Mireguide', 'Qiqirn Rock Hound', 'Qiqirn Enterpriser', 'Qiqirn Lieuter', 'Qiqirn Mosstrooper', 'Qiqirn Goldsmith' },
    ['Cannonball']      = { 'Wamouracampa', 'Wamoura Prince' },
    ['Disseverment']    = { "Ul'aern", "Om'aern", "Eo'aern", "Aw'aern" },
    ['Mind Blast']      = { 'Nepionic Soulflayer', 'Soulflayer', 'Mahjlaef the Paintorn' },
    ['Magic Hammer']    = { 'Poroggo', 'Iriri Samariri' },
};

function ui.is_horizon_verified_mob(spellName, mobName)
    local allowed = ui.horizon_verified_mobs[spellName];
    if allowed == nil then return false; end
    for _, name in ipairs(allowed) do
        if tostring(name) == tostring(mobName) then return true; end
    end
    return false;
end

function ui.get_verified_sources(spell)
    local out = {};
    if spell == nil or spell.zones == nil then return out; end
    if ui.horizon_verified_mobs[spell.name] == nil then return out; end

    for zoneId, mobs in pairs(spell.zones) do
        local zid = tonumber(zoneId);
        if zid ~= nil then
            if type(mobs) == 'table' then
                for _, mob in pairs(mobs) do
                    local name = tostring(mob);
                    if ui.is_horizon_verified_mob(spell.name, name) then
                        table.insert(out, { zoneId = zid, mob = name });
                    end
                end
            else
                local name = tostring(mobs);
                if ui.is_horizon_verified_mob(spell.name, name) then
                    table.insert(out, { zoneId = zid, mob = name });
                end
            end
        end
    end
    return out;
end

function ui.is_horizon_open_zone(zoneId)
    local zid = tonumber(zoneId);
    if zid == nil then return false; end

    local zoneName = AshitaCore:GetResourceManager():GetString('zones.names', zid) or '';
    local n = tostring(zoneName):lower();

    if n == '' or n == 'unknown' then return false; end

    local blocked = {
        'abyssea',
        'escha',
        'reisenjima',
        'adoul',
        'ceizak',
        'yahse',
        'hennetiel',
        'yorcia',
        'marjami',
        'kamihr',
        'foret de hennetiel',
        'morimar',
        'sih gates',
        'moh gates',
        'cirdas caverns',
        'dho gates',
        'woh gates',
        'ra'..'la waterways',
        'outer ra'..'kaznar',
        'castle adoulin',
        'leafallia',
        'silver knife',
        'celennia',
        'feretory',
        'walk of echoes',
        'provenance',
        'everbloom hollow',
        'ruhotz silvermines',
        'ghoyu'.."'s reverie",
        'la vaule',
        'grauberg',
        'vunkerl inlet',
        'fort karugo-narugo',
    };

    if n:find('[s]', 1, true) ~= nil or n:find('(s)', 1, true) ~= nil then
        return false;
    end

    for _, token in ipairs(blocked) do
        if n:find(token, 1, true) ~= nil then
            return false;
        end
    end

    return true;
end

function ui.get_horizon_fallback_sources(spell)
    local out = {};
    if spell == nil or spell.zones == nil then return out; end

    for zoneId, mobs in pairs(spell.zones) do
        local zid = tonumber(zoneId);
        if zid ~= nil and ui.is_horizon_open_zone(zid) then
            if type(mobs) == 'table' then
                for _, mob in pairs(mobs) do
                    table.insert(out, { zoneId = zid, mob = tostring(mob), verified = false });
                end
            else
                table.insert(out, { zoneId = zid, mob = tostring(mobs), verified = false });
            end
        end
    end

    return out;
end

function ui.get_preferred_sources(spell)
    local verified = ui.get_verified_sources(spell);
    if #verified > 0 then
        for _, src in ipairs(verified) do src.verified = true; end
        return verified, true;
    end

    return ui.get_horizon_fallback_sources(spell), false;
end


function ui.get_source_score(zoneId, spellLevel, currentZoneId)
    local zid = tonumber(zoneId);
    local current = tonumber(currentZoneId);

    if zid ~= nil and current ~= nil and zid == current then
        return -100000;
    end

    local name = AshitaCore:GetResourceManager():GetString('zones.names', zid) or '';
    local n = name:lower();
    local score = 1000;

    local easyZones = {
        'ronfaure', 'gustaberg', 'sarutabaruta', 'konschtat', 'la theine',
        'tahrongi', 'jugner', 'batallia', 'sauromogue', 'meriphataud',
        'valkurm', 'buburimu', 'qufim', 'beaucedine', 'yhoator', 'yuhtunga',
        'east ronfaure', 'west ronfaure', 'north gustaberg', 'south gustaberg',
        'east sarutabaruta', 'west sarutabaruta', 'crawler', 'zitah', 'cape teriggan',
        'boyahda', 'den of rancor', 'kuftal', 'bibiki bay', "pso'xja", "ifrit's cauldron"
    };

    for i, token in ipairs(easyZones) do
        if n:find(token, 1, true) ~= nil then
            score = score - (200 - math.min(i, 150));
            break;
        end
    end

    local difficultZones = {
        'dynamis', 'limbus', 'sea', "al'taieu", "ru'hmet", 'promyvion',
        'sky', "tu'lia", 'temple of uggalepih', 'riverne', 'battlefield',
        'escha', 'reisenjima', 'abyssea', 'adoulin', 'den of rancor'
    };

    for _, token in ipairs(difficultZones) do
        if n:find(token, 1, true) ~= nil then
            score = score + 500;
            break;
        end
    end

    if tonumber(spellLevel) ~= nil then
        score = score + math.max(0, tonumber(spellLevel) - 50) * 0.25;
    end

    return score;
end

function ui.get_recommended_source(spell)
    local sources, verified = ui.get_preferred_sources(spell);
    if #sources == 0 then
        return nil, nil, nil, false;
    end

    local currentZoneId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    local best = nil;
    local bestScore = math.huge;

    for _, src in ipairs(sources) do
        local score = ui.get_source_score(src.zoneId, spell.level, currentZoneId);
        if score < bestScore then
            bestScore = score;
            best = src;
        end
    end

    if best == nil then return nil, nil, nil, false; end
    local zone = AshitaCore:GetResourceManager():GetString('zones.names', best.zoneId) or tostring(best.zoneId);
    return best.mob, zone, best.zoneId, verified;
end

function ui.get_spells()
    ui.spells = T{};

    for x = 0, 2048 do
        local spell = AshitaCore:GetResourceManager():GetSpellById(x);
        local spell_data = ui.get_spell_data(x);

        if (spell ~= nil
            and spell.Skill == 43
            and spell_data:len() > 0
            and spell.LevelRequired[16 + 1] > 0
            and spell.LevelRequired[16 + 1] <= 75) then
            ui.spells:append(T{
                index   = x,
                name    = spell.Name[1],
                level   = spell.LevelRequired[16 + 1],
                element = spell.Element,
                known   = AshitaCore:GetMemoryManager():GetPlayer():HasSpell(x),
                zones   = spell_data,
                set_cost= ui.get_blu_spell_cost(spell.Name[1]),
            });
        end
    end

    ui.spells:sort(function (a, b)
        return (a.level < b.level) or (a.level == b.level and a.name < b.name);
    end);
end

function ui.refresh_known_blu_spells()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return 0; end

    local known = 0;
    for _, sp in ipairs(ui.spells or {}) do
        sp.known = player:HasSpell(sp.index) == true;
        if sp.known then known = known + 1; end
    end
    return known;
end

function ui.refresh_live_learned_blu_spells()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    ui.tab_sets.learned_spells = T{};
    ui.tab_sets.learned_count = 0;
    if player == nil then
        return 0;
    end

    for x = 0, 2048 do
        local spell = AshitaCore:GetResourceManager():GetSpellById(x);
        if spell ~= nil and spell.Skill == 43 and player:HasSpell(x) then
            local name = spell.Name[1];
            if name ~= nil and tostring(name) ~= '' then
                local level = tonumber(spell.LevelRequired[16 + 1]) or 0;
                ui.tab_sets.learned_spells:append(T{
                    index = x,
                    name = tostring(name),
                    level = level > 0 and level or 0,
                    set_cost = ui.get_blu_spell_cost(name),
                });
            end
        end
    end

    ui.tab_sets.learned_spells:sort(function(a, b)
        if a.level == b.level then return a.name < b.name; end
        return a.level < b.level;
    end);
    ui.tab_sets.learned_count = #ui.tab_sets.learned_spells;
    return ui.tab_sets.learned_count;
end

function ui.get_zone_spells(id)
    ui.zone = T{};

    local zoneId = tonumber(id);
    if (zoneId == nil or zoneId == 0) then
        return;
    end

    for _, spell in ipairs(ui.spells) do
        local sources = ui.get_preferred_sources(spell);
        for _, src in ipairs(sources) do
            if tonumber(src.zoneId) == zoneId then
                ui.zone:append(spell);
                break;
            end
        end
    end

    ui.zone:sort(function(a, b)
        return (a.level < b.level) or (a.level == b.level and a.name < b.name);
    end);
end

function ui.refresh_zone_helper()
    local zoneId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    zoneId = tonumber(zoneId) or 0;

    if (ui.current_zone_id ~= zoneId) then
        ui.current_zone_id = zoneId;
        ui.tab_zonehelper.selected[1] = -1;
        ui.get_zone_spells(zoneId);
    end
end

function ui.get_spell_counts()
    local counts = T{
        known   = 0,
        missing = 0,
        total   = 0,
    };

    ui.spells:each(function (v, k)
        counts.total = counts.total + 1;

        if (v.known) then
            counts.known = counts.known + 1;
        else
            counts.missing = counts.missing + 1;
        end
    end);

    ui.counts = counts;
end

function ui.load()
    local f = io.open(addon.path .. '/data/spells.json', 'rb');
    if (f == nil) then
        error('Failed to load spell list file. (/data/spells.json)');
    end

    local c = f:read("*all");
    f:close();

    ui.data = T(json.decode(c) or {});
    ui.load_live_blu_costs();

    ui.get_spells();
    ui.get_spell_counts();
    ui.current_zone_id = 0;
    ui.refresh_zone_helper();
    ui.refresh_blu_set_files(true);
    print(chat.header(addon.name):append(chat.message(('v%s loaded - Special Thanks: Tozura & KA Linkshell'):fmt(addon.version))));
end

function ui.packet_in(e)
    ui.handle_battle_action(e);

    if (e.id == 0x000A) then
        ui.tab_zonehelper.selected[1] = -1;
        ui.zone = T{};

        local zoningFlag = safe_struct_unpack('b', e.data_modified, 0x80 + 0x01);
        if zoningFlag == nil then return; end
        if zoningFlag == 1 then return; end

        local zone = safe_struct_unpack('H', e.data_modified, 0x30 + 1);
        if zone == nil then return; end
        if zone == 0 then
            zone = safe_struct_unpack('H', e.data_modified, 0x42 + 1);
            if zone == nil then return; end
        end

        ui.current_zone_id = tonumber(zone) or 0;
        ui.get_zone_spells(ui.current_zone_id);
        ui.get_spell_counts();

        return;
    end

    if (e.id == 0x000B) then
        ui.tab_zonehelper.selected[1] = -1;
        ui.zone = T{};

        return;
    end

    if (e.id == 0x0029) then
        local rawMsg = safe_struct_unpack('H', e.data_modified, 0x18 + 0x01);
        if rawMsg == nil then return; end
        local msg = bit.band(rawMsg, 0x7FFF);
        if (msg == 419) then
            local spellId = safe_struct_unpack('L', e.data_modified, 0x0C + 0x01);
            local sender  = safe_struct_unpack('H', e.data_modified, 0x14 + 0x01);
            local target  = safe_struct_unpack('H', e.data_modified, 0x16 + 0x01);
            if spellId == nil or sender == nil or target == nil then return; end

            local player = GetPlayerEntity();
            if (player ~= nil and sender == player.TargetIndex and target == player.TargetIndex) then
                local learnedSpell = ui.find_spell_by_id(spellId);

                ui.spells:each(function (v, k)
                    if (v.index == spellId) then
                        v.known = true;
                        learnedSpell = v;
                    end
                end);

                if learnedSpell ~= nil then
                    ui.show_learned_spell_alert(learnedSpell);
                end

                ui.get_spell_counts();
                ui.refresh_zone_helper();
            end
        end

        return;
    end

    if (e.id == 0x00AA) then
        ashita.tasks.oncef(1, function ()
            ui.get_spells();
            ui.get_spell_counts();
            ui.refresh_zone_helper();
        end);
        return;
    end
end

function ui.render_spell_info(lst, index)
    local t = ui.theme;
    if (index == nil or index < 1 or lst[index] == nil) then
        imgui.TextColored(t.muted, 'Select a spell to view its details.');
        return;
    end

    local spell = lst[index];
    local res = AshitaCore:GetResourceManager():GetSpellById(spell.index);
    if res == nil then
        imgui.TextColored(t.red, 'Failed to obtain spell information.');
        return;
    end

    imgui.TextColored(t.text, res.Name[1]);
    imgui.SameLine();
    imgui.TextColored(spell.known and t.green or t.red, spell.known and '  LEARNED' or '  NOT LEARNED');
    imgui.Separator();

    imgui.TextColored(t.muted, ('Level: %d'):fmt(spell.level));
    imgui.SameLine(0, 24);
    imgui.TextColored(t.muted, ('MP: %d'):fmt(res.ManaCost));
    imgui.TextColored(t.muted, ('Element: %s'):fmt(ui.get_spell_element(res.Element)));
    imgui.SameLine(0, 24);
    imgui.TextColored(t.muted, ('Recast: %.2fs'):fmt(res.RecastDelay / 4.0));

    imgui.Spacing();
    imgui.TextColored(t.accent, 'DESCRIPTION');
    imgui.PushTextWrapPos(0);
    imgui.TextColored(t.text, res.Description[1] or 'No description available.');
    imgui.PopTextWrapPos();
    imgui.Spacing();

    local mob, zone, zoneId = ui.get_recommended_source(spell);
    imgui.TextColored(t.accent, 'RECOMMENDED SOURCE');
    if mob ~= nil then
        imgui.TextColored(t.text, tostring(mob));
        imgui.TextColored(t.green, tostring(zone));
        if tonumber(zoneId) == tonumber(ui.current_zone_id) then
            imgui.TextColored(t.green, 'You are already in this zone.');
        end
    else
        imgui.TextColored(t.gold, 'No usable Horizon-era source stored yet.');
    end

    imgui.Spacing();
    if imgui.Button('Show on BGWiki', { 132, 26 }) then
        ashita.misc.open_url(('https://www.bg-wiki.com/ffxi/%s'):fmt(res.Name[1]));
    end
end

function ui.section_title(title, subtitle)
    local t = ui.theme;
    imgui.TextColored(t.accent, title);
    if subtitle ~= nil and subtitle ~= '' then
        imgui.SameLine();
        imgui.TextColored(t.muted, subtitle);
    end
end

function ui.update_opacity()
    local s = ui.settings;
    ui.theme.bg[4] = math.max(0.20, math.min(1.0, tonumber(s.background_opacity[1]) or 0.88));
    ui.theme.panel[4] = math.max(0.20, math.min(1.0, tonumber(s.panel_opacity[1]) or 0.92));
    ui.theme.panel_alt[4] = math.max(0.20, math.min(1.0, tonumber(s.card_opacity[1]) or 0.93));
end

function ui.stat_card(label, value, valueColor, width)
    local t = ui.theme;
    width = width or 125;
    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel_alt);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild(('##stat_%s'):fmt(label), { width, 66 }, ImGuiChildFlags_Borders);
        imgui.TextColored(t.muted, label);
        imgui.TextColored(valueColor or t.text, tostring(value));
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.top_tab(label, id, width)
    local t = ui.theme;
    local active = ui.active_tab == id;
    imgui.PushStyleColor(ImGuiCol_Button, active and t.accent_dim or t.panel_alt);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, t.accent_dim);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, t.accent);
    if imgui.Button(label, { width or 122, 30 }) then ui.active_tab = id; end
    imgui.PopStyleColor(3);
end

function ui.render_topbar()
    local t = ui.theme;
    local headerAvail = math.max(1, imgui.GetContentRegionAvail());
    imgui.TextColored(t.accent, 'AzureCodex');
    imgui.SameLine();
    imgui.TextColored(t.muted, '  +  HorizonXI Blue Magic Tracker');

    imgui.SameLine(imgui.GetCursorPosX() + math.max(0, imgui.GetContentRegionAvail() - 28));
    if imgui.Button('X##close', { 26, 24 }) then ui.is_open[1] = false; end

    local tabsAvail = headerAvail;
    local gap = imgui.GetStyle().ItemSpacing.x;
    local tabw = math.max(1, (tabsAvail - (gap * 5)) / 6);
    ui.top_tab('Overview', 1, tabw); imgui.SameLine();
    ui.top_tab('Spell List', 2, tabw); imgui.SameLine();
    ui.top_tab('Zone Helper', 3, tabw); imgui.SameLine();
    ui.top_tab('Traits', 4, tabw); imgui.SameLine();
    ui.top_tab('Azure Sets', 5, tabw); imgui.SameLine();
    ui.top_tab('Settings', 6, tabw);
    imgui.Separator();
end

function ui.render_progress_panels()
    local t = ui.theme;
    local avail = imgui.GetContentRegionAvail();
    local totalw = avail;
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, totalw - spacing);
    local leftw = usable * 0.66;
    local rightw = usable - leftw;

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##progress_panel', { leftw, 115 }, ImGuiChildFlags_Borders);
        ui.section_title('PROGRESS');
        imgui.Spacing();
        local inner = imgui.GetContentRegionAvail();
        local cw = math.max(96, (inner - 21) / 4);
        ui.stat_card('TOTAL SPELLS', ui.counts.total, t.text, cw); imgui.SameLine();
        ui.stat_card('KNOWN', ui.counts.known, t.green, cw); imgui.SameLine();
        ui.stat_card('MISSING', ui.counts.missing, t.red, cw); imgui.SameLine();
        ui.stat_card('IN ZONE', ui.zone:len(), t.gold, cw);
    imgui.EndChild();
    imgui.SameLine();
    imgui.BeginChild('##completion_panel', { rightw, 115 }, ImGuiChildFlags_Borders);
        ui.section_title('COMPLETION');
        local pct = ui.counts.total > 0 and (ui.counts.known / ui.counts.total) or 0;
        imgui.Spacing();
        imgui.TextColored(t.accent, ('%.1f%%'):fmt(pct * 100));
        imgui.ProgressBar(pct, { -1, 12 }, '');
        imgui.TextColored(t.muted, ('%d / %d Spells Learned'):fmt(ui.counts.known, ui.counts.total));
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.render_zone_recommendation()
    local t = ui.theme;
    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, avail - spacing);
    local leftw = usable * 0.43;
    local rightw = usable - leftw;
    local zid = ui.current_zone_id or 0;
    local zname = zid ~= 0 and (AshitaCore:GetResourceManager():GetString('zones.names', zid) or 'Unknown') or 'Unknown';

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##current_zone', { leftw, 84 }, ImGuiChildFlags_Borders);
        ui.section_title('CURRENT ZONE');
        imgui.Spacing();
        imgui.TextColored(t.text, zname);
        imgui.SameLine();
        imgui.TextColored(t.accent, ('  %d spell(s) here'):fmt(ui.zone:len()));
    imgui.EndChild();
    imgui.SameLine();

    local bestSpell, bestMob, bestZone = nil, nil, nil;
    for i, sp in ipairs(ui.spells) do
        if not sp.known then
            local mob, zone = ui.get_recommended_source(sp);
            if mob ~= nil then bestSpell, bestMob, bestZone = sp, mob, zone; break; end
        end
    end
    imgui.BeginChild('##recommended_source', { rightw, 84 }, ImGuiChildFlags_Borders);
        ui.section_title('RECOMMENDED SOURCE');
        imgui.Spacing();
        if bestSpell ~= nil then
            imgui.TextColored(t.text, ('%s  -  %s'):fmt(bestSpell.name, tostring(bestMob)));
            imgui.TextColored(t.green, tostring(bestZone));
        else
            imgui.TextColored(t.muted, 'No missing spell with a usable Horizon-era source.');
        end
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.selectable_spell_list(list, selectedRef, missingOnly)
    local t = ui.theme;
    local visibleIndex = 0;
    for i, sp in ipairs(list) do
        if (not missingOnly) or (not sp.known) then
            visibleIndex = visibleIndex + 1;
            local prefix = sp.known and '[+] ' or '[-] ';
            imgui.PushStyleColor(ImGuiCol_Text, sp.known and t.green or t.text);
            if imgui.Selectable(('%s%-28s Lv%02d##sp_%d_%d'):fmt(prefix, sp.name, sp.level, sp.index, i), selectedRef[1] == i) then
                selectedRef[1] = i;
            end
            imgui.PopStyleColor();
        end
    end
    if visibleIndex == 0 then imgui.TextColored(t.muted, 'No spells to display.'); end
end

function ui.render_suggestions(spell)
    local t = ui.theme;

    if spell == nil then
        ui.section_title('LEARNING SOURCES');
        imgui.Separator();
        imgui.TextColored(t.muted, 'Select a missing spell to see learning sources.');
        return;
    end

    local sources, verified = ui.get_preferred_sources(spell);

    if verified then
        ui.section_title('HORIZONXI VERIFIED SOURCES');
    else
        ui.section_title('HORIZON-ERA FALLBACK SOURCES');
    end
    imgui.Separator();

    if #sources == 0 then
        imgui.TextColored(t.gold, 'No usable Horizon-era source is stored for this spell.');
        return;
    end

    if not verified then
        imgui.TextColored(t.gold, 'Fallback: default mob data, Horizon-open zones only.');
        imgui.Spacing();
    end

    local current = tonumber(ui.current_zone_id) or 0;
    imgui.TextColored(t.accent, 'IN CURRENT ZONE');
    local here = 0;
    local seenHere = {};
    for _, src in ipairs(sources) do
        if src.zoneId == current and not seenHere[src.mob] then
            seenHere[src.mob] = true;
            imgui.TextColored(t.text, src.mob);
            imgui.SameLine(); imgui.TextColored(t.green, '  (Here)');
            here = here + 1;
            if here >= 4 then break; end
        end
    end
    if here == 0 then imgui.TextColored(t.muted, 'None listed in current zone.'); end

    imgui.Spacing(); imgui.Separator();
    if verified then
        imgui.TextColored(t.accent, 'OTHER VERIFIED SOURCES');
    else
        imgui.TextColored(t.accent, 'OTHER HORIZON-ERA SOURCES');
    end

    table.sort(sources, function(a, b)
        return ui.get_source_score(a.zoneId, spell.level, current) < ui.get_source_score(b.zoneId, spell.level, current);
    end);

    local shown = 0;
    local seen = {};
    for _, src in ipairs(sources) do
        if src.zoneId ~= current then
            local key = tostring(src.zoneId) .. ':' .. src.mob;
            if not seen[key] then
                seen[key] = true;
                local zname = AshitaCore:GetResourceManager():GetString('zones.names', src.zoneId) or tostring(src.zoneId);
                imgui.TextColored(t.text, src.mob);
                imgui.SameLine();
                imgui.TextColored(t.muted, ' - ' .. zname);
                shown = shown + 1;
                if shown >= 6 then break; end
            end
        end
    end
    if shown == 0 then imgui.TextColored(t.muted, 'No other usable sources listed.'); end
end

function ui.ensure_overview_selection()
    local idx = ui.tab_spells.selected[1];
    if idx ~= nil and idx > 0 and ui.spells[idx] ~= nil and not ui.spells[idx].known then return; end
    for i, sp in ipairs(ui.spells) do
        if not sp.known then ui.tab_spells.selected[1] = i; return; end
    end
    ui.tab_spells.selected[1] = -1;
end

function ui.render_overview()
    local t = ui.theme;
    ui.ensure_overview_selection();
    ui.render_progress_panels();
    imgui.Spacing();
    ui.render_zone_recommendation();
    imgui.Spacing();

    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, avail - (spacing * 2));
    local leftw = usable * 0.32;
    local midw = usable * 0.36;
    local rightw = usable - leftw - midw;
    local h = -1;

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##missing_spells', { leftw, h }, ImGuiChildFlags_Borders);
        ui.section_title(('MISSING SPELLS (%d)'):fmt(ui.counts.missing));
        imgui.Separator();
        ui.selectable_spell_list(ui.spells, ui.tab_spells.selected, true);
    imgui.EndChild();
    imgui.SameLine();
    imgui.BeginChild('##details', { midw, h }, ImGuiChildFlags_Borders);
        ui.section_title('SPELL DETAILS');
        imgui.Separator();
        ui.render_spell_info(ui.spells, ui.tab_spells.selected[1]);
    imgui.EndChild();
    imgui.SameLine();
    imgui.BeginChild('##suggestions', { rightw, h }, ImGuiChildFlags_Borders);
        local selected = ui.tab_spells.selected[1];
        ui.render_suggestions(selected and selected > 0 and ui.spells[selected] or nil);
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.render_spell_list_tab()
    local t = ui.theme;
    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, avail - spacing);
    local leftw = usable * 0.40;
    local rightw = usable - leftw;
    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##all_spells', { leftw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title(('ALL SPELLS (%d)'):fmt(ui.counts.total));
        imgui.Separator();
        ui.selectable_spell_list(ui.spells, ui.tab_spells.selected, false);
    imgui.EndChild();
    imgui.SameLine();
    imgui.BeginChild('##all_details', { rightw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title('SPELL DETAILS'); imgui.Separator();
        ui.render_spell_info(ui.spells, ui.tab_spells.selected[1]);
        local selected = ui.tab_spells.selected[1];
        imgui.Spacing(); imgui.Separator();
        ui.render_suggestions(selected and selected > 0 and ui.spells[selected] or nil);
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.render_zone_helper_tab()
    local t = ui.theme;
    local zid = ui.current_zone_id or 0;
    local zname = zid ~= 0 and (AshitaCore:GetResourceManager():GetString('zones.names', zid) or 'Unknown') or 'Unknown';
    imgui.TextColored(t.accent, 'CURRENT ZONE');
    imgui.PushStyleColor(ImGuiCol_Text, t.text); imgui.TextWrapped(zname); imgui.PopStyleColor();
    imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped(('%d Blue Magic spell(s) available here.'):fmt(ui.zone:len())); imgui.PopStyleColor();
    imgui.Separator();

    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, avail - spacing);
    local leftw = usable * 0.40;
    local rightw = usable - leftw;
    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##zone_spells', { leftw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title('ZONE SPELLS'); imgui.Separator();
        ui.selectable_spell_list(ui.zone, ui.tab_zonehelper.selected, false);
    imgui.EndChild();
    imgui.SameLine();
    imgui.BeginChild('##zone_details', { rightw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title('SPELL DETAILS'); imgui.Separator();
        ui.render_spell_info(ui.zone, ui.tab_zonehelper.selected[1]);
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.render_traits_tab()
    local t = ui.theme;
    ui.refresh_equipped_blu_spells(false);

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    local traitSummaryH = imgui.GetContentRegionAvail() < 820 and 120 or 96;
    imgui.BeginChild('##active_trait_summary', { -1, traitSummaryH }, ImGuiChildFlags_Borders);
        ui.section_title('LIVE EQUIPPED TRAIT CHECKER');
        imgui.Spacing();
        if not ui.blu_set.valid then
            local player = AshitaCore:GetMemoryManager():GetPlayer();
            if player ~= nil and player:GetMainJob() ~= 16 and player:GetSubJob() ~= 16 then
                imgui.PushStyleColor(ImGuiCol_Text, t.gold); imgui.TextWrapped('BLU is not your current main or sub job. Equip BLU to read the active Blue Magic spell set.'); imgui.PopStyleColor();
            else
                imgui.PushStyleColor(ImGuiCol_Text, t.red); imgui.TextWrapped('Unable to read the current Blue Magic spell-set buffer.'); imgui.PopStyleColor();
                imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('If you just changed jobs, open the Blue Magic set-spells menu once and AzureCodex will refresh automatically.'); imgui.PopStyleColor();
            end
        else
            imgui.TextColored(t.accent, ('Equipped Spells: %d / 20'):fmt(ui.blu_set.names:len()));
            imgui.SameLine();
            imgui.TextColored(t.green, ('    Active Traits: %d'):fmt(ui.get_active_trait_count()));
            imgui.SameLine();
            if imgui.Button('Refresh Now##traits_refresh', { 105, 24 }) then ui.refresh_equipped_blu_spells(true); end
            imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('ACTIVE is calculated only from spells that are set right now, not merely spells you have learned.'); imgui.PopStyleColor();
        end
    imgui.EndChild();
    imgui.PopStyleColor(2);
    imgui.Spacing();

    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usable = math.max(1, avail - spacing);
    local leftw = usable * 0.32;
    local rightw = usable - leftw;

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);

    imgui.BeginChild('##trait_list', { leftw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title(('BLU JOB TRAITS (%d)'):fmt(#ui.traits));
        imgui.TextColored(t.muted, 'Green = active from your current spell set.');
        imgui.Separator();
        for i, trait in ipairs(ui.traits) do
            local known = ui.get_trait_known_points(trait);
            local activeTier, equippedPts = ui.get_trait_active_tier(trait);
            local status = activeTier > 0 and ('ACTIVE T%d'):fmt(activeTier) or ('%d pts'):fmt(equippedPts);
            local label = ('%s  [%s]  %d/%d##trait_%d'):fmt(trait.name, status, known, #trait.spells, i);
            imgui.PushStyleColor(ImGuiCol_Text, activeTier > 0 and t.green or t.text);
            if imgui.Selectable(label, ui.tab_traits.selected[1] == i) then
                ui.tab_traits.selected[1] = i;
            end
            imgui.PopStyleColor();
        end
    imgui.EndChild();
    imgui.SameLine();

    imgui.BeginChild('##trait_details', { rightw, -1 }, ImGuiChildFlags_Borders);
        local idx = ui.tab_traits.selected[1] or 1;
        local trait = ui.traits[idx];
        if trait == nil then
            imgui.TextColored(t.muted, 'Select a trait.');
        else
            local known, ownedPts = ui.get_trait_known_points(trait);
            local equippedCount, equippedPts, equippedNames = ui.get_trait_equipped_points(trait);
            local activeTier = ui.get_trait_active_tier(trait);
            local thresholds = ui.get_trait_thresholds(trait);

            ui.section_title(trait.name:upper(), trait.tiers);
            imgui.Spacing();

            if rightw < 560 then
                if activeTier > 0 then
                    imgui.TextColored(t.green, ('ACTIVE  -  Tier %d'):fmt(activeTier));
                else
                    imgui.TextColored(t.red, 'INACTIVE');
                end
                imgui.TextColored(t.accent, ('Equipped trait points: %d'):fmt(equippedPts));
                imgui.TextColored(t.muted, ('Known spells: %d/%d'):fmt(known, #trait.spells));
            else
                if activeTier > 0 then
                    imgui.TextColored(t.green, ('ACTIVE  -  Tier %d'):fmt(activeTier));
                else
                    imgui.TextColored(t.red, 'INACTIVE');
                end
                imgui.SameLine();
                imgui.TextColored(t.accent, ('    Equipped trait points: %d'):fmt(equippedPts));
                imgui.SameLine();
                imgui.TextColored(t.muted, ('    Known spells: %d/%d'):fmt(known, #trait.spells));
            end

            local nextThreshold = nil;
            for _, threshold in ipairs(thresholds) do
                if equippedPts < threshold then nextThreshold = threshold; break; end
            end
            if nextThreshold ~= nil then
                imgui.TextColored(t.gold, ('Need %d more trait point(s) for the next tier.'):fmt(nextThreshold - equippedPts));
            elseif activeTier > 0 then
                imgui.TextColored(t.green, 'Highest available tier for this trait is active.');
            end

            if trait.special then
                imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped("Auto Refresh uses HorizonXI's weighted AR points; 8 total AR points activates the trait."); imgui.PopStyleColor();
            else
                imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('Normal listed spells contribute 1 trait point each while equipped.'); imgui.PopStyleColor();
            end
            imgui.Spacing(); imgui.Separator();

            imgui.TextColored(t.accent, 'SPELLS THAT CREATE THIS TRAIT');
            imgui.Spacing();
            local compactTraitRows = rightw < 620;
            if not compactTraitRows then
                imgui.TextColored(t.muted, 'Set?'); imgui.SameLine(70);
                imgui.TextColored(t.muted, 'Learned'); imgui.SameLine(145);
                imgui.TextColored(t.muted, 'Spell'); imgui.SameLine(410);
                imgui.TextColored(t.muted, 'Lv'); imgui.SameLine(460);
                imgui.TextColored(t.muted, 'Set Cost'); imgui.SameLine(535);
                imgui.TextColored(t.muted, trait.special and 'AR Pts' or 'Trait Pt');
                imgui.Separator();
            end

            for _, ts in ipairs(trait.spells) do
                local sp = ui.find_spell_by_name(ts.name);
                local isKnown = sp ~= nil and sp.known;
                local isSet = ui.is_spell_equipped(ts.name);

                if compactTraitRows then
                    local state = isSet and 'SET' or '--';
                    local learned = isKnown and 'KNOWN' or 'MISSING';
                    local row = ('%s  |  %s  |  %s  |  Lv%d  |  %d BP  |  %d pt'):fmt(
                        state, learned, ts.name, ts.level, ts.set, ts.weight or 1);
                    imgui.PushStyleColor(ImGuiCol_Text, isSet and t.green or (isKnown and t.text or t.muted));
                    imgui.TextWrapped(row);
                    imgui.PopStyleColor();
                    imgui.Separator();
                else
                    imgui.TextColored(isSet and t.green or t.muted, isSet and 'SET' or '--');
                    imgui.SameLine(70);
                    imgui.TextColored(isKnown and t.green or t.red, isKnown and 'KNOWN' or 'MISSING');
                    imgui.SameLine(145);
                    imgui.TextColored(isSet and t.green or t.text, ts.name);
                    imgui.SameLine(410);
                    imgui.TextColored(t.muted, tostring(ts.level));
                    imgui.SameLine(460);
                    imgui.TextColored(t.gold, tostring(ts.set));
                    imgui.SameLine(535);
                    imgui.TextColored(t.accent, tostring(ts.weight or 1));
                end
            end

            imgui.Spacing(); imgui.Separator();
            imgui.TextColored(t.accent, 'CURRENT CONTRIBUTORS');
            if #equippedNames == 0 then
                imgui.TextColored(t.muted, 'None of this trait\'s spells are currently equipped.');
            else
                imgui.PushStyleColor(ImGuiCol_Text, t.green); imgui.TextWrapped(table.concat(equippedNames, '  +  ')); imgui.PopStyleColor();
            end
            imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('The Set Cost column is the Blue Magic set-point cost. It is separate from trait-point contribution.'); imgui.PopStyleColor();
        end
    imgui.EndChild();
    imgui.PopStyleColor(2);
end


function ui.render_sets_tab()
    local t = ui.theme;
    ui.refresh_blu_set_files(false);
    ui.refresh_active_blu_set(false);

    local now = os.clock();
    if (now - (ui.tab_sets.last_known_refresh or 0)) >= 0.50 then
        ui.tab_sets.last_known_refresh = now;
        ui.refresh_known_blu_spells();
        ui.refresh_live_learned_blu_spells();
    end

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##blu_sets_header', { -1, 164 }, ImGuiChildFlags_Borders);
        ui.section_title('AZURE SETS');
        local activeSetName = ui.tab_sets.active_name or '';
        imgui.PushStyleColor(ImGuiCol_Text, activeSetName ~= '' and t.green or t.muted);
        imgui.TextWrapped(activeSetName ~= '' and ('ACTIVE SET: %s'):fmt(activeSetName) or 'ACTIVE SET: Custom / No saved set match');
        imgui.PopStyleColor();
        imgui.PushStyleColor(ImGuiCol_Text, t.muted);
        imgui.TextWrapped('Create, edit, save and equip BLU sets entirely inside AzureCodex');
        imgui.PopStyleColor();
        local headerPointCap = ui.get_blu_point_cap();
        local headerUsedPoints = ui.get_editor_set_points(ui.tab_sets.edit_spells);
        local headerRemainingPoints = math.max(0, headerPointCap - headerUsedPoints);
        imgui.TextColored(headerRemainingPoints > 0 and t.green or t.gold,
            ('BLUE POINTS LEFT: %d / %d'):fmt(headerRemainingPoints, headerPointCap));
        imgui.SameLine();
        imgui.TextColored(t.muted, ('    Used: %d'):fmt(headerUsedPoints));
        imgui.PushStyleColor(ImGuiCol_Text, t.muted);
        imgui.TextWrapped('Click any spell slot to open its learned-spell list. Double-click a saved set to equip it.');
        imgui.PopStyleColor();
        local headerAvail = imgui.GetContentRegionAvail();
        local headerSpacing = imgui.GetStyle().ItemSpacing.x;
        local buttonW = math.max(62, (headerAvail - (headerSpacing * 3)) / 4);
        if imgui.Button('New Set##sets_new', { buttonW, 24 }) then ui.new_editor_set(); end
        imgui.SameLine();
        if imgui.Button('Save##sets_save', { buttonW, 24 }) then ui.save_editor_set(false); end
        imgui.SameLine();
        if imgui.Button('Delete##sets_delete', { buttonW, 24 }) then ui.delete_selected_set(); end
        imgui.SameLine();
        if imgui.Button('Refresh##sets_refresh', { buttonW, 24 }) then
            ui.refresh_blu_set_files(true);
            ui.refresh_active_blu_set(true);
            ui.refresh_known_blu_spells();
            ui.refresh_live_learned_blu_spells();
            ui.get_spell_counts();
            ui.tab_sets.status = ('Refreshed saved sets and learned BLU spells (%d available).'):fmt(ui.tab_sets.learned_count or 0);
        end
        if ui.tab_sets.status ~= '' then
            imgui.Spacing();
            imgui.PushStyleColor(ImGuiCol_Text, codex_sets.applying and t.gold or t.green);
            imgui.TextWrapped(ui.tab_sets.status);
            imgui.PopStyleColor();
        end
    imgui.EndChild();
    imgui.PopStyleColor(2);
    imgui.Spacing();

    local avail = imgui.GetContentRegionAvail();
    local spacing = imgui.GetStyle().ItemSpacing.x;
    local usablew = math.max(1, avail - (spacing * 2));
    local leftw = usablew * 0.24;
    local midw = usablew * 0.43;

    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.BeginChild('##blu_sets_list', { leftw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title(('SAVED SETS (%d)'):fmt(#ui.tab_sets.files));
        imgui.Separator();
        if #ui.tab_sets.files == 0 then imgui.TextColored(t.muted, 'No saved AzureCodex sets yet.'); end
        for i, entry in ipairs(ui.tab_sets.files) do
            local source = entry.source == 'legacy' and ' [BluSets]' or '';
            local marker = ui.tab_sets.active_name == entry.name and '  [ACTIVE]' or '';
            if imgui.Selectable(entry.name .. source .. marker .. '##bluset_' .. i, ui.tab_sets.selected[1] == i) then
                ui.tab_sets.selected[1] = i;
                ui.load_set_into_editor(entry);
            end
            if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then
                ui.tab_sets.selected[1] = i;
                ui.load_set_into_editor(entry);
                ui.apply_saved_blu_set(entry);
            end
        end
    imgui.EndChild();
    imgui.SameLine();

    imgui.BeginChild('##blu_sets_editor', { midw, -1 }, ImGuiChildFlags_Borders);
        ui.section_title('SET EDITOR', ui.tab_sets.dirty and 'Unsaved changes' or 'Saved');
        imgui.PushItemWidth(-1);
        if imgui.InputText('##set_name', ui.tab_sets.edit_name, ui.tab_sets.edit_name_size) then ui.tab_sets.dirty = true; end
        imgui.PopItemWidth();
        imgui.Separator();

        imgui.BeginChild('##blu_slot_list', { -1, -1 }, ImGuiChildFlags_Borders);
            local used = 0;
            for i=1,20 do if tostring(ui.tab_sets.edit_spells[i] or '') ~= '' then used=used+1; end end
            local pointCap = ui.get_blu_point_cap();
            local usedPoints = ui.get_editor_set_points(ui.tab_sets.edit_spells);
            local remainingPoints = math.max(0, pointCap - usedPoints);
            local slotCap = ui.get_blu_spell_slot_cap();
            imgui.TextColored(t.accent, ('Blue Points: %d / %d used'):fmt(usedPoints, pointCap));
            imgui.SameLine();
            imgui.TextColored(remainingPoints > 0 and t.green or t.gold, ('    Remaining: %d'):fmt(remainingPoints));
            imgui.PushStyleColor(ImGuiCol_Text, t.accent);
            imgui.TextWrapped(('Spell Slots: %d / %d    Learned BLU Spells: %d'):fmt(used, slotCap, ui.tab_sets.learned_count or 0));
            imgui.PopStyleColor();
            imgui.PushStyleColor(ImGuiCol_Text, t.muted);
            imgui.TextWrapped('Each spell shows its Horizon Blue Magic set-point cost. Spells you cannot afford and slots above your current level cap are disabled.');
            imgui.PopStyleColor();
            imgui.Separator();

            if (ui.tab_sets.learned_count or 0) == 0 then
                imgui.TextColored(t.red, 'No learned BLU spells are available yet.');
                imgui.TextColored(t.muted, 'Open your in-game Blue Magic spell list once, then click Refresh Learned Spells.');
                if imgui.Button('Refresh Learned Spells##sets_refresh_learned', { 170, 24 }) then
                    ui.refresh_known_blu_spells();
                    ui.refresh_live_learned_blu_spells();
                    ui.get_spell_counts();
                end
                imgui.Separator();
            end

            local currentLookup = ui.get_set_lookup(ui.tab_sets.edit_spells);
            for i = 1, 20 do
                local current = tostring(ui.tab_sets.edit_spells[i] or '');
                local currentCost = ui.get_blu_spell_cost(current);
                local preview = current ~= '' and (('%s  [%d BP]'):fmt(current, currentCost)) or '(empty - click to choose)';
                local slotUnavailable = (i > slotCap) or (current == '' and (remainingPoints <= 0 or used >= slotCap));

                if slotUnavailable then imgui.BeginDisabled(); end
                imgui.PushItemWidth(-1);
                if imgui.BeginCombo(('##edit_slot_combo_%d'):fmt(i), ('%02d. %s'):fmt(i, preview)) then
                    if imgui.Selectable(('Clear Slot##combo_clear_%d'):fmt(i), current == '') then
                        ui.tab_sets.edit_spells[i] = '';
                        ui.tab_sets.edit_slot[1] = i;
                        ui.tab_sets.dirty = true;
                    end
                    imgui.Separator();
                    for _, sp in ipairs(ui.tab_sets.learned_spells or {}) do
                        local already = currentLookup[sp.name] and current ~= sp.name;
                        local selected = current == sp.name;
                        local cost = ui.get_blu_spell_cost(sp.name);
                        local effectiveRemaining = remainingPoints + currentCost;
                        local tooExpensive = (not selected) and cost > effectiveRemaining;
                        local cannotPick = already or tooExpensive or cost <= 0;
                        local prefix = sp.level > 0 and ('Lv%02d  '):fmt(sp.level) or '';
                        local suffix = ('  [%d BP]'):fmt(cost);
                        if already then suffix = suffix .. '  [ALREADY SET]'; end
                        if tooExpensive then suffix = suffix .. '  [NEED ' .. tostring(cost - effectiveRemaining) .. ' MORE BP]'; end
                        if cost <= 0 then suffix = suffix .. '  [NO SET COST DATA]'; end
                        if cannotPick then imgui.BeginDisabled(); end
                        if imgui.Selectable(prefix .. sp.name .. suffix .. '##slot_' .. i .. '_spell_' .. sp.index, selected) and not cannotPick then
                            ui.tab_sets.edit_spells[i] = sp.name;
                            ui.tab_sets.edit_slot[1] = i;
                            ui.tab_sets.dirty = true;
                        end
                        if cannotPick then imgui.EndDisabled(); end
                    end
                    imgui.EndCombo();
                end
                imgui.PopItemWidth();
                if slotUnavailable then imgui.EndDisabled(); end
            end
        imgui.EndChild();
    imgui.EndChild();
    imgui.SameLine();

    imgui.BeginChild('##blu_sets_right_column', { -1, -1 }, 0);
        local detailChain = ui.tab_sets.detail_skillchain;
        if detailChain ~= nil and detailChain ~= '' then
            imgui.BeginChild('##blu_sets_skillchain_detail', { -1, -1 }, ImGuiChildFlags_Borders);
                if imgui.Button('< Back', { 90, 26 }) then
                    ui.tab_sets.detail_skillchain = nil;
                end
                imgui.SameLine();
                ui.section_title(tostring(detailChain):upper(), 'Skillchain Detail');
                imgui.Separator();

                local weaponType, weaponName = ui.azure_get_equipped_weapon();
                local elements = ui.azure_sc_elements[detailChain] or {};
                local bursts = ui.azure_get_known_burst_spells(detailChain);

                if weaponType ~= nil then
                    imgui.PushStyleColor(ImGuiCol_Text, t.accent);
                    imgui.TextWrapped(('Equipped: %s [%s]'):fmt(weaponName or weaponType, weaponType));
                    imgui.PopStyleColor();
                else
                    imgui.TextColored(t.muted, 'Equip a Sword or Club in Main to see combinations.');
                end
                imgui.PushStyleColor(ImGuiCol_Text, t.green);
                imgui.TextWrapped(('Burst Elements: %s'):fmt(#elements > 0 and table.concat(elements, ', ') or 'None'));
                imgui.PopStyleColor();
                imgui.TextWrapped(('Known Magic Burst spells: %s'):fmt(#bursts > 0 and table.concat(bursts, ', ') or 'None learned'));
                imgui.Spacing();
                imgui.Separator();

                local allCombos = ui.azure_get_all_skillchains_for_result(detailChain, weaponType);
                imgui.TextColored(t.green, ('Ways to make %s: %d'):fmt(detailChain, #allCombos));
                imgui.PushStyleColor(ImGuiCol_Text, t.muted);
                imgui.TextWrapped('Uses the currently equipped weapon type and only physical BLU spells you currently know. [SET] marks spells in this Azure Set.');
                imgui.PopStyleColor();
                imgui.Spacing();

                if #allCombos == 0 then
                    imgui.TextColored(t.muted, 'No combinations found for this skillchain with the equipped weapon.');
                else
                    for i, sc in ipairs(allCombos) do
                        local inSet = ui.azure_is_spell_in_set(ui.tab_sets.edit_spells, sc.blu);
                        local suffix = inSet and '  [SET]' or '';
                        if sc.direction == 'WS -> BLU' then
                            imgui.TextColored(inSet and t.green or t.text, ('%s -> %s%s'):fmt(sc.ws, sc.blu, suffix));
                        else
                            imgui.TextColored(inSet and t.green or t.text, ('%s -> %s%s'):fmt(sc.blu, sc.ws, suffix));
                        end
                        if i < #allCombos then imgui.Separator(); end
                    end
                end
            imgui.EndChild();
        else
            local rightSpacing = imgui.GetStyle().ItemSpacing.y;
            local rightHeight = math.max(1, imgui.GetWindowHeight() - 36);
            local topHeight = math.max(90, (rightHeight - rightSpacing) * 0.46);
            imgui.BeginChild('##blu_sets_traits', { -1, topHeight }, ImGuiChildFlags_Borders);
                ui.section_title('ACTIVE TRAITS', 'Current Azure Set');
                imgui.Separator();
                local active = ui.get_active_traits_for_set(ui.tab_sets.edit_spells);
                imgui.TextColored(t.green, ('Active Traits: %d'):fmt(#active));
                imgui.Spacing();
                if #active == 0 then
                    imgui.TextColored(t.muted, 'No job traits activate with this set.');
                else
                    for _, tr in ipairs(active) do
                        imgui.PushStyleColor(ImGuiCol_Text, t.text);
                        imgui.TextWrapped(tr.name);
                        imgui.PopStyleColor();
                        imgui.SameLine();
                        imgui.TextColored(t.green, ('Tier %s'):fmt(ui.get_trait_tier_label(tr.tier)));
                    end
                end
            imgui.EndChild();
            imgui.Spacing();

            imgui.BeginChild('##blu_sets_skillchains', { -1, -1 }, ImGuiChildFlags_Borders);
                local weaponType = ui.azure_get_equipped_weapon();
                local chains = ui.azure_get_set_skillchains(ui.tab_sets.edit_spells);

                if #chains == 0 then
                    if weaponType == nil then
                        imgui.PushStyleColor(ImGuiCol_Text, t.muted);
                    imgui.TextWrapped('Equip a Sword or Club in Main.');
                    imgui.PopStyleColor();
                    else
                        imgui.PushStyleColor(ImGuiCol_Text, t.muted);
                    imgui.TextWrapped('No skillchains available with this weapon and Azure Set.');
                    imgui.PopStyleColor();
                    end
                else
                    local unique = {};
                    local names = {};
                    for _, sc in ipairs(chains) do
                        if sc.result ~= nil and sc.result ~= '' and not unique[sc.result] then
                            unique[sc.result] = true;
                            table.insert(names, sc.result);
                        end
                    end

                    local rank = {
                        Light=4, Darkness=4,
                        Fusion=3, Fragmentation=3, Gravitation=3, Distortion=3,
                        Transfixion=2, Liquefaction=2, Impaction=2, Detonation=2,
                        Compression=2, Scission=2, Reverberation=2, Induration=2
                    };
                    table.sort(names, function(a, b)
                        local ar, br = rank[a] or 1, rank[b] or 1;
                        if ar ~= br then return ar > br; end
                        return a < b;
                    end);

                    for i, name in ipairs(names) do
                        imgui.PushStyleColor(ImGuiCol_Text, t.green);
                        if imgui.Selectable(name .. '##azure_sc_name_' .. tostring(i), false) then end
                        imgui.PopStyleColor();
                        if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then
                            ui.tab_sets.detail_skillchain = name;
                        end
                    end
                end
            imgui.EndChild();
        end
    imgui.EndChild();
    imgui.PopStyleColor(2);
end

function ui.render_settings_tab()
    local t = ui.theme;
    ui.section_title('UI SETTINGS');
    imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('Lower transparency values show more of the game world behind AzureCodex.'); imgui.PopStyleColor();
    imgui.Spacing(); imgui.Separator();

    local bg = { ui.settings.background_opacity[1] };
    if imgui.SliderFloat('Main Background', bg, 0.20, 1.0, '%.0f%%') then
        ui.settings.background_opacity[1] = bg[1]; ui.update_opacity();
    end
    local panel = { ui.settings.panel_opacity[1] };
    if imgui.SliderFloat('Header / Panels', panel, 0.20, 1.0, '%.0f%%') then
        ui.settings.panel_opacity[1] = panel[1]; ui.update_opacity();
    end
    local card = { ui.settings.card_opacity[1] };
    if imgui.SliderFloat('Cards / Lists', card, 0.20, 1.0, '%.0f%%') then
        ui.settings.card_opacity[1] = card[1]; ui.update_opacity();
    end

    imgui.Spacing();
    if imgui.Button('Save Settings', { 130, 28 }) then settings.save(); end
    imgui.SameLine();
    if imgui.Button('Reset Transparency', { 160, 28 }) then
        ui.settings.background_opacity[1] = 0.88;
        ui.settings.panel_opacity[1] = 0.92;
        ui.settings.card_opacity[1] = 0.93;
        ui.update_opacity();
        settings.save();
    end

    imgui.Spacing(); imgui.Separator();
    imgui.TextColored(t.accent, 'UNKNOWN SPELL ALERT');
    imgui.PushStyleColor(ImGuiCol_Text, t.muted); imgui.TextWrapped('Shows a dashboard-style popup when a mob readies an unlearned BLU spell on you, your party, or your alliance.'); imgui.PopStyleColor();
    if imgui.Checkbox('Enable Unknown Spell Popup', ui.settings.unknown_spell_popup) then settings.save(); end
    local duration = { ui.settings.popup_duration[1] };
    if imgui.SliderFloat('Popup Duration', duration, 3.0, 20.0, '%.0f sec') then
        ui.settings.popup_duration[1] = duration[1];
    end
    if imgui.IsItemDeactivatedAfterEdit and imgui.IsItemDeactivatedAfterEdit() then settings.save(); end

    imgui.Spacing(); imgui.Separator();
    imgui.TextColored(t.green, 'SPELL LEARNED ALERT');
    imgui.TextColored(t.muted, 'Shows a success popup as soon as Horizon confirms that you learned a Blue Magic spell.');
    if imgui.Checkbox('Enable Spell Learned Popup', ui.settings.learned_spell_popup) then settings.save(); end
    local learnedDuration = { ui.settings.learned_popup_duration[1] };
    if imgui.SliderFloat('Learned Popup Duration', learnedDuration, 3.0, 20.0, '%.0f sec') then
        ui.settings.learned_popup_duration[1] = learnedDuration[1];
    end
    if imgui.IsItemDeactivatedAfterEdit and imgui.IsItemDeactivatedAfterEdit() then settings.save(); end

    imgui.Spacing();
    if imgui.Checkbox('Play Kweh Sound On Learn', ui.settings.learned_spell_sound) then settings.save(); end
    local learnVolume = { ui.settings.learned_spell_volume[1] };
    if imgui.SliderFloat('Learn Sound Volume', learnVolume, 0.0, 100.0, '%.0f%%') then
        ui.settings.learned_spell_volume[1] = learnVolume[1];
    end
    if imgui.IsItemDeactivatedAfterEdit and imgui.IsItemDeactivatedAfterEdit() then settings.save(); end

    imgui.Spacing(); imgui.Separator();
    imgui.TextColored(t.accent, 'CREDITS');
    imgui.PushStyleColor(ImGuiCol_Text, t.muted);
    imgui.TextWrapped('Special Thanks: Tozura & KA Linkshell');
    imgui.PopStyleColor();

    imgui.Spacing(); imgui.Separator();
    imgui.TextColored(t.accent, 'WINDOW');
    imgui.TextColored(t.muted, 'AzureCodex has no title bar and remains freely movable and resizable. Drag the window body to move it and use the lower-right resize grip to resize it.');
end

function ui.push_theme()
    ui.update_opacity();
    local t = ui.theme;
    imgui.PushStyleColor(ImGuiCol_WindowBg, t.bg);
    imgui.PushStyleColor(ImGuiCol_ChildBg, t.panel);
    imgui.PushStyleColor(ImGuiCol_PopupBg, t.bg);
    imgui.PushStyleColor(ImGuiCol_Border, t.border);
    imgui.PushStyleColor(ImGuiCol_FrameBg, t.panel_alt);
    imgui.PushStyleColor(ImGuiCol_Button, t.panel_alt);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, t.accent_dim);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, t.accent);
    imgui.PushStyleColor(ImGuiCol_Header, t.accent_dim);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.16, 0.46, 0.62, 1.00 });
    imgui.PushStyleColor(ImGuiCol_HeaderActive, t.accent);
    imgui.PushStyleColor(ImGuiCol_Separator, t.border);
    imgui.PushStyleColor(ImGuiCol_Text, t.text);
    imgui.PushStyleColor(ImGuiCol_TitleBg, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0, 0, 0, 0 });

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 5.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.0);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 4.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 10, 10 });
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 7, 4 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 7, 6 });
end

function ui.pop_theme()
    imgui.PopStyleVar(7);
    imgui.PopStyleColor(15);
end

function ui.draw_style1_popup_orb(accent, width, height)
    local dl = imgui.GetWindowDrawList();
    local px, py = imgui.GetCursorScreenPos();
    local cx = px + (width * 0.50);
    local cy = py + (height * 0.50);

    local col_main = imgui.GetColorU32(accent);
    local col_glow = imgui.GetColorU32({ accent[1], accent[2], accent[3], 0.18 });
    local col_dim  = imgui.GetColorU32({ accent[1], accent[2], accent[3], 0.52 });

    dl:AddCircleFilled({ cx, cy }, 16.0, col_glow, 32);
    dl:AddCircle({ cx, cy }, 20.0, col_dim, 32, 1.5);
    dl:AddCircle({ cx, cy }, 13.0, col_main, 32, 1.6);
    dl:AddCircleFilled({ cx, cy }, 4.0, col_main, 24);

    for i = 0, 7 do
        local a = (math.pi * 2.0 * i) / 8.0;
        local x1 = cx + math.cos(a) * 7.0;
        local y1 = cy + math.sin(a) * 7.0;
        local x2 = cx + math.cos(a) * 19.0;
        local y2 = cy + math.sin(a) * 19.0;
        dl:AddLine({ x1, y1 }, { x2, y2 }, col_main, 1.3);
    end

    imgui.Dummy({ width, height });
end

function ui.render_unknown_spell_alert()
    if not ui.spell_alert.visible or ui.spell_alert.spell == nil then return; end
    local duration = tonumber(ui.settings.popup_duration and ui.settings.popup_duration[1]) or 8.0;
    if (os.clock() - ui.spell_alert.started) >= duration then
        ui.spell_alert.visible = false;
        return;
    end

    local spell = ui.spell_alert.spell;
    local res = AshitaCore:GetResourceManager():GetSpellById(spell.index);
    local spellName = spell.name or (res and res.Name[1]) or 'Unknown Blue Magic';

    local accent = { 0.70, 0.30, 1.00, 1.00 };
    local bg = { 0.018, 0.026, 0.043, 0.985 };
    local iconBg = { 0.20, 0.07, 0.34, 0.985 };
    local divider = { 0.37, 0.16, 0.55, 1.00 };
    local text = { 1.00, 1.00, 1.00, 1.00 };
    local closeText = { 0.68, 0.73, 0.82, 1.00 };

    local popupW = math.max(275, math.min(380, 195 + (#spellName * 8)));
    local popupH = 60;
    local iconW = 54;
    local dividerW = 2;
    local bodyW = popupW - iconW - dividerW;

    imgui.SetNextWindowSize({ popupW, popupH }, ImGuiCond_Always);
    imgui.PushStyleColor(ImGuiCol_WindowBg, bg);
    imgui.PushStyleColor(ImGuiCol_Border, accent);
    imgui.PushStyleColor(ImGuiCol_Button, { 0.00, 0.00, 0.00, 0.00 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.18, 0.08, 0.28, 0.85 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.25, 0.11, 0.38, 0.95 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.5);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0);

    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse
    );

    local open = { true };
    if imgui.Begin('##AzureCodexUnknownSpellAlert', open, flags) then
        local font = imgui.GetFont();

        imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
        imgui.PushStyleColor(ImGuiCol_Border, { 0, 0, 0, 0 });
        imgui.BeginChild('##unknown_style1_icon', { iconW, popupH }, 0);
            ui.draw_style1_popup_orb(accent, iconW, popupH);
        imgui.EndChild();
        imgui.PopStyleColor(2);

        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_ChildBg, divider);
        imgui.BeginChild('##unknown_style4_divider', { dividerW, popupH }, 0);
        imgui.EndChild();
        imgui.PopStyleColor();

        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
        imgui.PushStyleColor(ImGuiCol_Border, { 0, 0, 0, 0 });
        imgui.BeginChild('##unknown_style4_body', { bodyW, popupH }, 0);
            imgui.SetCursorPosX(13);
            imgui.SetCursorPosY(8);
            imgui.PushFont(font, 10.5);
            imgui.TextColored(accent, 'UNLEARNED SPELL');
            imgui.PopFont();

            imgui.SetCursorPosX(13);
            imgui.SetCursorPosY(28);
            imgui.PushFont(font, 16.0);
            imgui.TextColored(text, spellName);
            imgui.PopFont();

            imgui.SetCursorPosX(bodyW - 25);
            imgui.SetCursorPosY(3);
            imgui.PushStyleColor(ImGuiCol_Text, closeText);
            imgui.PushFont(font, 11.0);
            if imgui.Button('X##spell_alert_close', { 19, 17 }) then
                ui.spell_alert.visible = false;
            end
            imgui.PopFont();
            imgui.PopStyleColor();
        imgui.EndChild();
        imgui.PopStyleColor(2);
    end
    imgui.End();

    imgui.PopStyleVar(6);
    imgui.PopStyleColor(5);
    if open[1] == false then ui.spell_alert.visible = false; end
end

function ui.render_learned_spell_alert()
    if not ui.learn_alert.visible or ui.learn_alert.spell == nil then return; end
    local duration = tonumber(ui.settings.learned_popup_duration and ui.settings.learned_popup_duration[1]) or 6.0;
    if (os.clock() - ui.learn_alert.started) >= duration then
        ui.learn_alert.visible = false;
        return;
    end

    local spell = ui.learn_alert.spell;
    local res = AshitaCore:GetResourceManager():GetSpellById(spell.index);
    local spellName = spell.name or (res and res.Name[1]) or 'Blue Magic';

    local accent = { 0.30, 0.95, 0.35, 1.00 };
    local bg = { 0.018, 0.036, 0.026, 0.985 };
    local iconBg = { 0.035, 0.24, 0.075, 0.985 };
    local divider = { 0.12, 0.45, 0.18, 1.00 };
    local text = { 1.00, 1.00, 1.00, 1.00 };
    local closeText = { 0.68, 0.73, 0.82, 1.00 };

    local popupW = math.max(275, math.min(380, 195 + (#spellName * 8)));
    local popupH = 60;
    local iconW = 54;
    local dividerW = 2;
    local bodyW = popupW - iconW - dividerW;

    imgui.SetNextWindowSize({ popupW, popupH }, ImGuiCond_Always);
    imgui.PushStyleColor(ImGuiCol_WindowBg, bg);
    imgui.PushStyleColor(ImGuiCol_Border, accent);
    imgui.PushStyleColor(ImGuiCol_Button, { 0.00, 0.00, 0.00, 0.00 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.04, 0.24, 0.08, 0.85 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.05, 0.34, 0.11, 0.95 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1.5);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
    imgui.PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 0.0);

    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse
    );

    local open = { true };
    if imgui.Begin('##AzureCodexSpellLearnedAlert', open, flags) then
        local font = imgui.GetFont();

        imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
        imgui.PushStyleColor(ImGuiCol_Border, { 0, 0, 0, 0 });
        imgui.BeginChild('##learned_style1_icon', { iconW, popupH }, 0);
            ui.draw_style1_popup_orb(accent, iconW, popupH);
        imgui.EndChild();
        imgui.PopStyleColor(2);

        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_ChildBg, divider);
        imgui.BeginChild('##learned_style4_divider', { dividerW, popupH }, 0);
        imgui.EndChild();
        imgui.PopStyleColor();

        imgui.SameLine();
        imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
        imgui.PushStyleColor(ImGuiCol_Border, { 0, 0, 0, 0 });
        imgui.BeginChild('##learned_style4_body', { bodyW, popupH }, 0);
            imgui.SetCursorPosX(13);
            imgui.SetCursorPosY(8);
            imgui.PushFont(font, 10.5);
            imgui.TextColored(accent, 'SPELL LEARNED');
            imgui.PopFont();

            imgui.SetCursorPosX(13);
            imgui.SetCursorPosY(28);
            imgui.PushFont(font, 16.0);
            imgui.TextColored(text, spellName);
            imgui.PopFont();

            imgui.SetCursorPosX(bodyW - 25);
            imgui.SetCursorPosY(3);
            imgui.PushStyleColor(ImGuiCol_Text, closeText);
            imgui.PushFont(font, 11.0);
            if imgui.Button('X##learn_alert_close', { 19, 17 }) then
                ui.learn_alert.visible = false;
            end
            imgui.PopFont();
            imgui.PopStyleColor();
        imgui.EndChild();
        imgui.PopStyleColor(2);
    end
    imgui.End();

    imgui.PopStyleVar(6);
    imgui.PopStyleColor(5);
    if open[1] == false then ui.learn_alert.visible = false; end
end

function ui.render()
    ui.render_unknown_spell_alert();
    ui.render_learned_spell_alert();
    if not ui.is_open[1] then return; end
    ui.refresh_zone_helper();
    ui.push_theme();

    imgui.SetNextWindowSize({ 1100, 720 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 640, 500 }, { FLT_MAX, FLT_MAX });
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoCollapse);

    if imgui.Begin('##AzureCodexOverlay', ui.is_open, flags) then
        ui.render_topbar();
        if ui.active_tab == 1 then
            ui.render_overview();
        elseif ui.active_tab == 2 then
            ui.render_spell_list_tab();
        elseif ui.active_tab == 3 then
            ui.render_zone_helper_tab();
        elseif ui.active_tab == 4 then
            ui.render_traits_tab();
        elseif ui.active_tab == 5 then
            ui.render_sets_tab();
        else
            ui.render_settings_tab();
        end
    end
    imgui.End();
    ui.pop_theme();
end

return ui;

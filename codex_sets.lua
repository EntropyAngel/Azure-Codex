require('common');

local ffi = require('ffi');

ffi.cdef[[
    typedef uint8_t (__cdecl *azurecodex_equipex_t)(uint8_t isSubJob, uint16_t jobType, uint16_t index, uint8_t id);
]];

local sets = {
    equipex = ffi.cast('azurecodex_equipex_t', ashita.memory.find(0, 0,
        '8B0D????????81EC9C00000085C95356570F??????????8B', 0, 0)),
    blu_offset = ffi.cast('uint32_t*', ashita.memory.find(0, 0,
        'C1E1032BC8B0018D????????????B9????????F3A55F5E5B', 10, 0)),
    points = ffi.cast('uint8_t***', ashita.memory.find(0, 0,
        'A1????????33C98A4E5E33D28A565D5F5E8950148948185B83C414C20400', 1, 0)),
    delay = 1.25,
    verify_delay = 0.20,
    retries = 3,
    applying = false,
    active_name = '',
};

function sets.is_blu_main()
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    return p ~= nil and p:GetMainJob() == 16;
end

function sets.is_blu_sub()
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    return p ~= nil and p:GetSubJob() == 16;
end

function sets.can_apply()
    return sets.is_blu_main() or sets.is_blu_sub();
end

function sets.get_spell_id(name)
    if name == nil or tostring(name):trim() == '' then return 0; end
    local spell = AshitaCore:GetResourceManager():GetSpellByName(tostring(name):trim(), 0);
    if spell == nil or spell.Index < 512 or spell.Index > 1024 then return nil; end
    return spell.Index - 512;
end

function sets.set_spell_by_id(index, id)
    if index < 1 or index > 20 then return false; end
    if id == nil or id < 0 or id > 255 then return false; end
    if sets.equipex == nil or tonumber(ffi.cast('uintptr_t', sets.equipex)) == 0 then return false; end
    sets.equipex(sets.is_blu_main() and 0 or 1, 0x1000, index - 1, id);
    return true;
end

function sets.set_spell_by_name(index, name)
    local id = sets.get_spell_id(name);
    if id == nil then return false; end
    return sets.set_spell_by_id(index, id);
end


function sets.get_blu_buffer_ptr()
    local inv = AshitaCore:GetPointerManager():Get('inventory');
    if inv == nil or inv == 0 then return 0; end
    local ptr = ashita.memory.read_uint32(inv);
    if ptr == 0 then return 0; end
    ptr = ashita.memory.read_uint32(ptr);
    if ptr == 0 then return 0; end
    return ptr + sets.blu_offset[0] + (sets.is_blu_main() and 0x00 or 0x9C);
end

function sets.reset_all_spells()
    if not sets.can_apply() then return false; end
    if sets.blu_offset == nil or tonumber(ffi.cast('uintptr_t', sets.blu_offset)) == 0 then return false; end
    local buffer = sets.get_blu_buffer_ptr();
    if buffer == 0 then return false; end

    AshitaCore:GetPacketManager():QueuePacket(0x102, 0xA4, 0x00, 0x00, 0x00, function(ptr)
        local packet = ffi.cast('uint8_t*', ptr);
        ffi.fill(packet + 0x04, 0xA0);
        ffi.copy(packet + 0x08, ffi.cast('uint8_t*', buffer), 0x9C);
    end);
    return true;
end

function sets.get_current_spell_ids()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil or (not sets.is_blu_main() and not sets.is_blu_sub()) then return nil; end
    if sets.blu_offset == nil or tonumber(ffi.cast('uintptr_t', sets.blu_offset)) == 0 then return nil; end

    local inv = AshitaCore:GetPointerManager():Get('inventory');
    if inv == nil or inv == 0 then return nil; end
    local ptr = ashita.memory.read_uint32(inv);
    if ptr == 0 then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if ptr == 0 then return nil; end

    local base = (ptr + sets.blu_offset[0]) + (sets.is_blu_main() and 0x04 or 0xA0);
    local raw = ashita.memory.read_array(base, 0x14);
    if raw == nil then return nil; end

    local out = {};
    for i = 1, 20 do out[i] = tonumber(raw[i]) or 0; end
    return out;
end


function sets.get_spent_points()
    local ok, value = pcall(function()
        if sets.points == nil or tonumber(ffi.cast('uintptr_t', sets.points)) == 0 then return nil; end
        return tonumber(sets.points[0][0][0x14]);
    end);
    if ok then return value; end
    return nil;
end

function sets.get_spell_name_from_id(id)
    id = tonumber(id) or 0;
    if id == 0 then return ''; end
    local spell = AshitaCore:GetResourceManager():GetSpellById(id + 512);
    if spell == nil or spell.Name == nil then return ''; end
    return tostring(spell.Name[1] or spell.Name[2] or spell.Name[0] or '');
end

function sets.verify_slot(index, expected_id)
    local current = sets.get_current_spell_ids();
    return current ~= nil and (tonumber(current[index]) or 0) == (tonumber(expected_id) or 0);
end

function sets.set_and_verify(index, id)
    for attempt = 1, sets.retries do
        if sets.verify_slot(index, id) then return true, attempt - 1, 0; end
        local before_points = sets.get_spent_points();
        if not sets.set_spell_by_id(index, id) then return false, attempt - 1, nil; end
        coroutine.sleep(sets.delay);
        if sets.verify_delay > 0 then coroutine.sleep(sets.verify_delay); end
        if sets.verify_slot(index, id) then
            local after_points = sets.get_spent_points();
            local delta = nil;
            if before_points ~= nil and after_points ~= nil then delta = after_points - before_points; end
            return true, attempt - 1, delta;
        end
    end
    return false, sets.retries, nil;
end

function sets.apply(name, spells, on_done, on_cost_learned)
    if sets.applying or not sets.can_apply() or spells == nil then return false; end

    local desired = {};
    local desired_names = {};
    for i = 1, 20 do
        desired_names[i] = tostring(spells[i] or ''):trim();
        desired[i] = sets.get_spell_id(desired_names[i]);
        if desired[i] == nil then return false; end
    end

    sets.applying = true;
    ashita.tasks.once(0, (function()
        local failed = {};

        if not sets.reset_all_spells() then
            sets.applying = false;
            if on_done ~= nil then on_done(false, { 'reset failed' }); end
            return;
        end

        coroutine.sleep(sets.delay);

        for i = 1, 20 do
            if desired[i] ~= 0 then
                local before_points = sets.get_spent_points();
                sets.set_spell_by_id(i, desired[i]);
                coroutine.sleep(sets.delay);
                if sets.verify_delay > 0 then coroutine.sleep(sets.verify_delay); end

                if not sets.verify_slot(i, desired[i]) then
                    local ok, _, delta = sets.set_and_verify(i, desired[i]);
                    if not ok then
                        table.insert(failed, ('slot %d set'):fmt(i));
                    elseif delta ~= nil and delta > 0 and desired_names[i] ~= '' and on_cost_learned ~= nil then
                        on_cost_learned(desired_names[i], delta);
                    end
                else
                    local after_points = sets.get_spent_points();
                    if before_points ~= nil and after_points ~= nil and after_points > before_points and on_cost_learned ~= nil then
                        on_cost_learned(desired_names[i], after_points - before_points);
                    end
                end
            end
        end

        local final = sets.get_current_spell_ids();
        if final == nil then
            table.insert(failed, 'final read');
        else
            for i = 1, 20 do
                if (tonumber(final[i]) or 0) ~= (tonumber(desired[i]) or 0) then
                    table.insert(failed, ('slot %d verify'):fmt(i));
                end
            end
        end

        local success = #failed == 0;
        if success then sets.active_name = name or ''; end
        sets.applying = false;
        if on_done ~= nil then on_done(success, failed); end
    end));
    return true;
end

return sets;

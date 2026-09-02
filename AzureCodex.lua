addon.name      = 'AzureCodex';
addon.author    = 'Angelofdeath';
addon.version   = '1.4';
addon.desc      = 'HorizonXI Blue Mage spell, trait, zone, and learning companion.';
addon.link      = 'https://ashitaxi.com/';

require('common');
local ui = require('ui');

ashita.events.register('load', 'load_cb', ui.load);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0) then
        return;
    end

    local cmd = tostring(args[1]):lower();
    if (cmd ~= '/azurecodex' and cmd ~= '/ac') then
        return;
    end

    e.blocked = true;
    ui.is_open[1] = not ui.is_open[1];
end);

ashita.events.register('packet_in', 'packet_in_cb', ui.packet_in);

ashita.events.register('text_in', 'text_in_cb', ui.text_in);

ashita.events.register('d3d_present', 'present_cb', ui.render);

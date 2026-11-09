local mp = require 'mp'

-- 将 menu.conf 标题中的显式按键提示移到菜单原生的右侧快捷键栏。
local updating = false
mp.observe_property('menu-data', 'native', function(_, menu)
    if updating or type(menu) ~= 'table' then return end
    local changed = false
    local function walk(items)
        for _, item in ipairs(items) do
            if type(item) == 'table' then
                local title, shortcut = (item.title or ''):match('^(.-)%s+%[(.*)%]$')
                if title then
                    item.title = title
                    item.shortcut = shortcut
                    changed = true
                end
                if type(item.submenu) == 'table' then walk(item.submenu) end
            end
        end
    end
    walk(menu)
    if changed then
        updating = true
        mp.set_property_native('menu-data', menu)
        updating = false
    end
end)

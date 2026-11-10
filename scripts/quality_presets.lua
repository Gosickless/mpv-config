-- 统一切换画质；只管理预设涉及的参数，不写回用户配置或播放状态。
local mp = require 'mp'
local utils = require 'mp.utils'
local path = mp.command_native({'expand-path', '~~/script-opts/quality-presets.json'})
local f = io.open(path, 'rb')
if not f then mp.msg.error('无法读取画质预设: '..path); return end
local presets, parse_error = utils.parse_json(f:read('*a')); f:close()
if not presets then mp.msg.error(tostring(parse_error)); return end
local baseline, keys = {}, {}
for _, preset in pairs(presets) do
    for key in pairs(preset.options or {}) do keys[key] = true end
end
for key in pairs(keys) do
    baseline[key] = mp.get_property(key)
    if baseline[key] == nil then mp.msg.error('不支持画质参数: '..key); return end
end
local current = 'base'
local function notify(text) mp.osd_message(text, 3); mp.msg.info(text) end
local function shaders_for(preset)
    local shaders = {}
    for _, file in ipairs(preset.shaders or {}) do
        local expanded = mp.command_native({'expand-path',file})
        local info = utils.file_info(expanded)
        if not info or not info.is_file then return nil, '缺少着色器: '..file end
        shaders[#shaders+1] = expanded
    end
    return shaders
end
local function select_preset(id, silent)
    local preset = presets[id]
    if not preset then notify('未知画质预设: '..tostring(id)); return end
    local shaders, err = shaders_for(preset)
    if not shaders then notify(err); return end
    local previous = {shaders=mp.get_property_native('glsl-shaders'), options={}}
    for key in pairs(keys) do previous.options[key] = mp.get_property(key) end
    local function apply()
        local function set(key,value)
            local ok, message
            if key == 'glsl-shaders' then ok, message = mp.set_property_native(key,value)
            else
                if type(value) == 'boolean' then value = value and 'yes' or 'no' end
                ok, message = mp.set_property(key,tostring(value))
            end
            if not ok then error(key..': '..tostring(message)) end
        end
        set('glsl-shaders', {})
        for key in pairs(keys) do set(key, baseline[key]) end
        for key,value in pairs(preset.options or {}) do set(key,value) end
        set('glsl-shaders', shaders)
    end
    local ok, message = pcall(apply)
    if not ok then
        for key,value in pairs(previous.options) do mp.set_property(key,value) end
        mp.set_property_native('glsl-shaders', previous.shaders or {})
        notify('画质切换失败，已尝试恢复: '..tostring(message)); return
    end
    current = id
    mp.set_property_native('user-data/quality-presets', {current=id})
    if not silent then notify('画质：'..preset.title) end
end
mp.register_script_message('select', function(id) select_preset(id, false) end)
mp.register_script_message('toggle-deband', function()
    local enabled = not mp.get_property_bool('deband', false)
    local ok, err = mp.set_property_bool('deband', enabled)
    if not ok then notify('去色带切换失败: '..tostring(err)); return end
    notify('去色带：'..(enabled and '开启' or '关闭'))
end)
-- 同进程切集保留档位；进程重启 current 回到 base。
mp.add_hook('on_preloaded', 50, function() select_preset(current, true) end)
mp.set_property_native('user-data/quality-presets', {current=current})


-- menu.conf 的标题不展开属性表达式；通过 menu-data 更新实际文字。
local updating_menu = false
local function update_deband_title()
    if updating_menu then return end
    local menu = mp.get_property_native('menu-data')
    if type(menu) ~= 'table' then return end
    local title = '去色带：'..(mp.get_property_bool('deband', false) and '开启' or '关闭')
    local changed = false
    local function walk(items)
        for _, item in ipairs(items) do
            if type(item) == 'table' then
                if type(item.title) == 'string' and item.title:match('^去色带：')
                    and (item.title ~= title or item.shortcut ~= 'b') then
                    item.title = title; item.shortcut = 'b'; changed = true
                end
                if type(item.submenu) == 'table' then walk(item.submenu) end
            end
        end
    end
    walk(menu)
    if changed then
        updating_menu = true
        mp.set_property_native('menu-data', menu)
        updating_menu = false
    end
end
mp.observe_property('deband', 'bool', update_deband_title)
mp.observe_property('menu-data', 'native', update_deband_title)

local mp = require 'mp'
local utils = require 'mp.utils'
local busy = false
local ready = false
local history_path = mp.command_native({'expand-path', '~~/subtitle-history.json'})
local function read_history()
    local file = io.open(history_path, 'rb')
    if not file then return {} end
    local data = utils.parse_json(file:read('*a')); file:close()
    if type(data) ~= 'table' then mp.msg.warn('无法读取本地字幕记录'); return nil end
    return data
end
local function full_path(path)
    return mp.command_native({'normalize-path', path})
end
local function path_key(path)
    return full_path(path):gsub('\\', '/'):lower()
end
local function remember_subtitles()
    if not ready then return end
    local video = mp.get_property('path')
    if not video then return end
    local history = read_history()
    if not history then return end
    local key = path_key(video)
    local saved = history[key] or {}
    local known = {}
    for _,path in ipairs(saved) do known[path_key(path)] = true end
    local changed = false
    for _,track in ipairs(mp.get_property_native('track-list') or {}) do
        local path = track['external-filename']
        if track.type == 'sub' and path and utils.file_info(path) then
            local id = path_key(path)
            if not known[id] then saved[#saved+1] = full_path(path); known[id] = true; changed = true end
        end
    end
    if not changed then return end
    history[key] = saved
    local file = io.open(history_path, 'wb')
    if not file then mp.msg.warn('无法保存本地字幕记录'); return end
    file:write(utils.format_json(history)); file:close()
end
mp.register_event('start-file', function() ready = false end)
mp.register_event('file-loaded', function()
    local video = mp.get_property('path')
    local history = read_history()
    local known = {}
    for _,track in ipairs(mp.get_property_native('track-list') or {}) do
        local path = track['external-filename']
        if track.type == 'sub' and path then known[path_key(path)] = true end
    end
    for _,path in ipairs(video and history and history[path_key(video)] or {}) do
        local info = utils.file_info(path)
        if info and info.is_file and not known[path_key(path)] then
            mp.commandv('sub-add', path, 'auto')
            known[path_key(path)] = true
        end
    end
    ready = true
    remember_subtitles()
end)
mp.observe_property('track-list', 'native', remember_subtitles)

mp.add_key_binding(nil, 'open', function()
    if busy then return end
    busy = true
    local video = mp.get_property('path', '')
    local directory = utils.split_path(video)
    local original = video
    mp.command_native_async({
        name = 'subprocess',
        args = {'powershell.exe', '-NoProfile', '-STA', '-WindowStyle', 'Hidden',
                '-ExecutionPolicy', 'Bypass', '-File',
                mp.command_native({'expand-path', '~~/script-opts/select-subtitle.ps1'}), directory},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result)
        busy = false
        if not success or result.status ~= 0 then
            mp.msg.error('打开字幕选择窗口失败')
            mp.osd_message('打开字幕选择窗口失败', 3)
            return
        end
        local path = (result.stdout or ''):gsub('[\r\n]+$', '')
        if path == '' then return end
        if mp.get_property('path', '') ~= original then
            mp.osd_message('视频已切换，请重新选择字幕', 3)
            return
        end
        local ok, err = mp.commandv('sub-add', path, 'select')
        if not ok then
            mp.msg.error(tostring(err))
            mp.osd_message('字幕加载失败', 3)
        else
            mp.set_property_bool('sub-visibility', true)
        end
    end)
end)

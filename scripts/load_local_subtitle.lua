local mp = require 'mp'
local utils = require 'mp.utils'
local busy = false

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

-- Optional RIFE extension. Off means no subprocess, network, or video filter.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = {runtime_root='', experimental_hdr=false}
require('mp.options').read_options(options, 'rife')
local root = options.runtime_root ~= '' and options.runtime_root or utils.join_path(os.getenv('LOCALAPPDATA') or '', 'mpv-rife')
local config = mp.command_native({'expand-path','~~/'})
local helper = utils.join_path(config, 'rife/runtime.ps1')
local bridge = utils.join_path(config, 'rife/interpolate.vpy')
local tag = 'mpv_rife'
local requested, active, busy = false, false, false
local generation, phase, reason = 0, '关闭', ''
local job, progress_timer, cancel_file
local function normalize(p) return (p or ''):gsub('\\','/'):gsub('/+$',''):lower() end
local function notify(s) mp.osd_message(s, 5); mp.msg.info(s) end
local function read_json(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local s=f:read('*a');f:close(); return utils.parse_json(s:gsub('^\239\187\191',''))
end
local function has_filter()
    for _,f in ipairs(mp.get_property_native('vf') or {}) do if f.label==tag then return true end end
    return false
end
local menu_updating=false
local function update_menu()
    if menu_updating then return end
    local data=mp.get_property_native('menu-data');if type(data)~='table' then return end
    local changed=false
    local function walk(items)
        for _,item in ipairs(items) do
            if type(item.title)=='string' and item.title:match('^AI补帧：') then
                local title='AI补帧：'..phase
                if item.title~=title then item.title=title;changed=true end
            end
            if type(item.submenu)=='table' then walk(item.submenu) end
        end
    end
    walk(data)
    if changed then menu_updating=true;mp.set_property_native('menu-data',data);menu_updating=false end
end
local function state(p,r)
    phase,reason=p,r or ''
    mp.set_property_native('user-data/rife',{requested=requested,active=active,phase=phase,reason=reason,experimental=true})
    update_menu()
end
local function remove_filter()
    if has_filter() then mp.command_native({'vf','remove','@'..tag}) end
    active=false
end
local function cancel_prepare()
    if cancel_file then local f=io.open(cancel_file,'w');if f then f:write('cancel');f:close() end end
end
local function off()
    generation=generation+1;requested=false;cancel_prepare();remove_filter();state('关闭')
    notify('AI补帧：关闭；运行缓存保留在磁盘')
end
local function helper_args(action)
    return {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',helper,'-Action',action,'-Root',root,'-ConfigDir',config}
end
local function fail(message)
    remove_filter();state('不可用',message);notify('AI补帧：'..message)
end
local function input_options()
    local p=mp.get_property_native('video-params') or {}
    local fps=mp.get_property_number('container-fps')
    if not p.w or not p.h or not fps then return nil,'请先打开视频' end
    if p.w>3840 or p.h>2160 or p.w%2~=0 or p.h%2~=0 then return nil,'首版只接受偶数尺寸，最高4K' end
    if fps<=0 or fps>30 then return nil,'首版只接受1–30 fps输入' end
    if p.interlaced or mp.get_property_bool('video-frame-info/interlaced',false) then return nil,'暂不支持交错视频' end
    if p['dolby-vision-profile'] or p['dolby-vision-level'] then return nil,'暂不支持杜比视界' end
    local transfer=p.gamma
    if transfer=='hlg' then return nil,'暂不支持HLG' end
    if transfer=='pq' and not options.experimental_hdr then return nil,'HDR10待验收，默认关闭实验性HDR处理' end
    if transfer~='pq' and transfer~='bt.1886' and transfer~='srgb' then return nil,'传递函数未知或不支持' end
    if p.colormatrix~='bt.709' and p.colormatrix~='bt.2020-ncl' then return nil,'颜色矩阵未知或不支持' end
    for _,f in ipairs(mp.get_property_native('vf') or {}) do
        if f.label~=tag then return nil,'当前已有其他视频滤镜，首版不盲目组合' end
    end
    return {root=root,width=p.w,height=p.h,fps=tostring(fps),matrix=p.colormatrix,
            transfer=transfer,primaries=p.primaries,range=p.colorlevels,
            experimental_hdr=options.experimental_hdr}
end
local enable
local function install()
    if busy then notify('已有任务进行中，可点击取消准备');return end
    busy=true;local token=generation;local started=os.time()
    cancel_file=utils.join_path(os.getenv('TEMP') or root,'mpv-rife-cancel-'..utils.getpid()..'-'..tostring(mp.get_time()):gsub('%.',''))
    local args=helper_args('Install');args[#args+1]='-CancelFile';args[#args+1]=cancel_file
    state('等待安装确认')
    progress_timer=mp.add_periodic_timer(1,function()
        local p=read_json(utils.join_path(root,'progress.json'))
        local info=utils.file_info(utils.join_path(root,'progress.json'))
        if not info or (info.mtime or 0)<started then return end
        if p and p.phase=='download' then
            state('下载环境中');mp.osd_message(string.format('AI补帧环境：%s %.1f / %.1f MiB',p.file or '',(p.bytes or 0)/1048576,(p.total or 0)/1048576),1.2)
        elseif p and p.phase=='extracting' then state('解压环境中') end
    end)
    job=mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stdout=true,capture_stderr=true},function(success,result)
        busy=false;job=nil;if progress_timer then progress_timer:kill();progress_timer=nil end
        if cancel_file then os.remove(cancel_file);cancel_file=nil end
        if token~=generation then state('关闭');return end
        if not success or not result or result.status~=0 then fail('安装失败，请查看运行信息和环境目录内progress.json');return end
        if ((result and result.stdout) or ''):find('Cancelled',1,true) then state('关闭');notify('已取消安装');return end
        if not read_json(utils.join_path(root,'active.json')) then state('关闭');notify('已取消安装');return end
        requested=false;state('需重启');notify('环境已安装。请用 rife/launch.ps1 启动mpv，再开启补帧。GPU/HDR尚未验收。')
    end)
end
local function quoted(s) return '%'..#s..'%'..s end
local function attach(token,params)
    if token~=generation or not requested then return end
    local payload=utils.format_json(params)
    local filter='@'..tag..':vapoursynth=file='..quoted(bridge)..':user-data='..quoted(payload)..':buffered-frames=4:concurrent-frames=1'
    state('准备模型（首次可能较慢）')
    local ok,err=mp.command_native({'vf','add',filter})
    if not ok then fail('滤镜加载失败：'..tostring(err));return end
    active=has_filter()
    state(active and '开启（2×，实验性）' or '不可用',active and '' or '滤镜未进入处理链')
    if active then notify('AI补帧：开启2×（实验性）；首次引擎准备可能等待较久') end
end
enable=function()
    if busy then notify('正在准备环境，请等待或取消');return end
    local installed=read_json(utils.join_path(root,'active.json'))
    if not installed then install();return end
    local params,err=input_options();if not params then fail(err);return end
    if not os.getenv('VSSCRIPT_PATH') or normalize(os.getenv('MPV_RIFE_ROOT'))~=normalize(root) then fail('需要使用配套rife/launch.ps1重新启动mpv');return end
    requested=true;generation=generation+1;local token=generation
    busy=true;state('检测NVIDIA环境')
    job=mp.command_native_async({name='subprocess',args=helper_args('Probe'),playback_only=false,capture_stdout=true,capture_stderr=true},function(success,result)
        busy=false;job=nil
        if token~=generation or not requested then if requested then enable() end; return end
        local result_json
        for line in ((result and result.stdout) or ''):gmatch('[^\r\n]+') do local p=utils.parse_json(line);if p then result_json=p end end
        if not success or not result or result.status~=0 or not result_json or not result_json.ok then
            fail(result_json and result_json.error or '运行环境探测失败（驱动或DLL不兼容）');return
        end
        -- Build on a separate process, not inside mpv's render thread.
        cancel_file=utils.join_path(os.getenv('TEMP') or root,'mpv-rife-prepare-cancel-'..utils.getpid()..'-'..tostring(token))
        local request=utils.join_path(root,'request-'..utils.getpid()..'-'..tostring(token)..'.json')
        local f=io.open(request,'w');if not f then fail('无法写入模型准备请求');return end
        f:write(utils.format_json(params));f:close()
        local args=helper_args('Prepare')
        args[#args+1]='-Request';args[#args+1]=request
        args[#args+1]='-CancelFile';args[#args+1]=cancel_file
        busy=true;state('准备模型（可取消）')
        job=mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stdout=true,capture_stderr=true},function(prepared,answer)
            busy=false;job=nil;os.remove(request)
            if cancel_file then os.remove(cancel_file);cancel_file=nil end
            if token~=generation or not requested then
                if requested then enable() end
                return
            end
            if not prepared or not answer or answer.status~=0 then fail('模型准备失败，请检查运行环境目录中的日志');return end
            attach(token,params)
        end)
    end)
end
mp.register_script_message('toggle',function() if requested or active then off() else enable() end end)
mp.register_script_message('install',install)
mp.register_script_message('cancel',off)
mp.register_script_message('info',function()
    local installed=read_json(utils.join_path(root,'active.json'))
    notify('AI补帧：'..phase..'\n'..reason..'\n环境：'..root..'\n安装：'..(installed and '已安装，GPU/HDR待验收' or '未安装')..'\nHDR实验模式：'..tostring(options.experimental_hdr))
end)
mp.register_script_message('open-runtime',function()
    if not utils.file_info(root) then notify('尚未创建运行环境目录');return end
    mp.command_native_async({name='subprocess',args={'explorer.exe',root},playback_only=false},function() end)
end)
mp.register_script_message('launch',function()
    local exe=mp.command_native({'expand-path','~~exe_dir/mpv.exe'})
    if not utils.file_info(exe) then notify('找不到mpv.exe，请手动使用rife/launch.ps1');return end
    local args=helper_args('Launch');args[#args+1]='-Mpv';args[#args+1]=exe
    mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stderr=true},function(ok,result)
        if not ok or not result or result.status~=0 then notify('启动失败：先安装环境，再查看日志') end
    end)
end)
mp.register_event('start-file',function() generation=generation+1;cancel_prepare();active=false end)
mp.register_event('file-loaded',function() if requested then enable() end end)
mp.register_event('end-file',function(event)
    generation=generation+1;remove_filter()
    if event.reason=='error' and requested then requested=false;state('播放错误，已关闭','不自动重试');notify('补帧播放失败，已关闭；可重新打开原视频') end
end)
mp.enable_messages('error')
mp.register_event('log-message',function(event)
    if requested and (event.prefix or ''):find('vapoursynth',1,true) then
        requested=false;generation=generation+1;cancel_prepare()
        fail('VapourSynth运行失败，已尝试移除补帧滤镜；可重新打开原视频')
    end
end)
mp.register_event('shutdown',function() cancel_prepare() end)
mp.observe_property('menu-data','native',update_menu)
state('关闭')

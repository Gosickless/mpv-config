-- Optional RIFE extension. Off means no subprocess, network, or video filter.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = {runtime_root='', experimental_hdr=true, model='standard', target_fps=0}
require('mp.options').read_options(options, 'rife')
local root = options.runtime_root ~= '' and options.runtime_root or utils.join_path(os.getenv('LOCALAPPDATA') or '', 'mpv-rife')
local config = mp.command_native({'expand-path','~~/'})
local helper = utils.join_path(config, 'rife/runtime.ps1')
local bridge = utils.join_path(config, 'rife/interpolate.vpy')
local tag = 'mpv_rife'
local requested, active, busy = false, false, false
local generation, phase, reason = 0, '关闭', ''
local job, cancel_file
local manager_job
local activate_runtime
local expected_fps, measured_fps, output_timer
local stable_samples=0
local announced=false
local slow_samples,settle_until=0,0
local model_names={lite='轻量',standard='均衡',heavy='高画质'}
local function notify(s) mp.osd_message(s, 5); mp.msg.info(s) end
local function read_json(path)
    local f=io.open(path,'rb'); if not f then return nil end
    local s=f:read('*a');f:close(); return utils.parse_json(s:gsub('^\239\187\191',''))
end
local manifest=read_json(utils.join_path(config,'rife/runtime-lock.json'))
local function current_install(record) return record and record.installed and manifest and record.id==manifest.id end
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
            if type(item.title)=='string' and item.title:match('^补帧画质：') then
                local title='补帧画质：'..(model_names[options.model] or '均衡')
                if item.title~=title then item.title=title;changed=true end
            elseif type(item.title)=='string' and item.title:match('^输出帧率：') then
                local title='输出帧率：'..(options.target_fps==0 and '自动两倍' or (options.target_fps..' fps'))
                if item.title~=title then item.title=title;changed=true end
            end
            if type(item.title)=='string' and item.title:match('^补帧组件：') then
                local installed=read_json(utils.join_path(root,'active.json'))
                local title='补帧组件：'..(current_install(installed) and '已安装' or (installed and installed.installed and '需要更新' or '未安装'))
                if item.title~=title then item.title=title;changed=true end
            end
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
    if output_timer then output_timer:kill();output_timer=nil end
    if has_filter() then mp.command_native({'vf','remove','@'..tag}) end
    active=false;expected_fps=nil;measured_fps=nil;stable_samples=0
end
local function cancel_prepare()
    if cancel_file then local f=io.open(cancel_file,'w');if f then f:write('cancel');f:close() end end
end
local function off()
    generation=generation+1;requested=false;announced=false;cancel_prepare();remove_filter();state('关闭')
    notify('AI 补帧已关闭')
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
    if p.w>3840 or p.h>2160 or p.w%2~=0 or p.h%2~=0 then return nil,'此视频的分辨率暂不支持补帧（最高4K）' end
    if fps<=0 or fps>30 then return nil,'此视频的帧率暂不支持补帧（最高30帧/秒）' end
    if p.interlaced or mp.get_property_bool('video-frame-info/interlaced',false) then return nil,'暂不支持交错视频' end
    if p['dolby-vision-profile'] or p['dolby-vision-level'] then return nil,'暂不支持杜比视界' end
    local transfer=p.gamma
    if transfer=='hlg' then return nil,'暂不支持HLG' end
    if transfer=='pq' and not options.experimental_hdr then return nil,'此版本暂不支持为HDR视频补帧，原画播放不受影响' end
    if transfer~='pq' and transfer~='bt.1886' and transfer~='srgb' then return nil,'此视频的色彩格式暂不支持补帧' end
    if p.colormatrix~='bt.709' and p.colormatrix~='bt.2020-ncl' then return nil,'此视频的色彩格式暂不支持补帧' end
    for _,f in ipairs(mp.get_property_native('vf') or {}) do
        if f.label~=tag then return nil,'当前视频处理设置与补帧不兼容，请关闭其他视频滤镜后重试' end
    end
    if not model_names[options.model] then return nil,'请选择有效的补帧画质' end
    if options.target_fps~=0 and (options.target_fps%1~=0 or options.target_fps<24 or options.target_fps>360) then return nil,'请选择24到360之间的目标帧率' end
    local factor=2
    if options.target_fps~=0 then
        local wanted=options.target_fps/fps;local best=math.huge
        for half=3,30 do local candidate=half/2;local distance=math.abs(candidate-wanted)
            if distance<best then factor=candidate;best=distance end
        end
    end
    return {model=options.model,target_fps=options.target_fps,output_fps=fps*factor,root=root,width=p.w,height=p.h,fps=tostring(fps),matrix=p.colormatrix,
            transfer=transfer,primaries=p.primaries,range=p.colorlevels,
            experimental_hdr=options.experimental_hdr}
end
local enable
local function install()
    if manager_job then notify('组件管理窗口已打开，请切换到该窗口');return end
    local exe=mp.command_native({'expand-path','~~exe_dir/mpv.exe'})
    local args={'powershell.exe','-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
                '-File',utils.join_path(config,'rife/manager.ps1'),'-Root',root,'-ConfigDir',config}
    if utils.file_info(exe) then args[#args+1]='-Mpv';args[#args+1]=exe end
    manager_job=mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stdout=true,capture_stderr=true},function(success,result)
        manager_job=nil;update_menu()
        if not success or not result or result.status~=0 then
            mp.msg.error(result and result.stderr or 'component manager failed')
            notify('暂时无法打开组件管理，请稍后重试')
        end
    end)
end
local function quoted(s) return '%'..#s..'%'..s end
local function attach(token,params)
    if token~=generation or not requested then return end
    local payload=utils.format_json(params)
    local filter='@'..tag..':vapoursynth=file='..quoted(bridge)..':user-data='..quoted(payload)..':buffered-frames=16:concurrent-frames=4'
    state('正在准备')
    local _,err=mp.command_native({'vf','add',filter})
    if err or not has_filter() then mp.msg.error(tostring(err));fail('暂时无法启用补帧，请重新打开视频后重试');return end
    if token~=generation or not requested then remove_filter();return end
    active=has_filter()
    expected_fps=params.output_fps;stable_samples=0
    slow_samples=0;settle_until=mp.get_time()+3
    state(active and (mp.get_property_bool('pause') and '已暂停' or '正在启动') or '不可用',active and '' or '补帧未能启动')
    if output_timer then output_timer:kill();output_timer=nil end
    if active then
        local previous_position=mp.get_property_number('time-pos')
        output_timer=mp.add_periodic_timer(.5,function()
            if not has_filter() then requested=false;remove_filter();state('不可用','补帧已停止，请重新开启');return end
            local position=mp.get_property_number('time-pos')
            if mp.get_property_bool('pause') or mp.get_property_bool('seeking') then previous_position=position;return end
            measured_fps=mp.get_property_number('estimated-vf-fps')
            local sync=mp.get_property_number('avsync',0)
            if mp.get_time()>=settle_until and math.abs(sync)>.25 then slow_samples=slow_samples+1 else slow_samples=0 end
            if slow_samples>=3 then
                local audio_position=mp.get_property_number('audio-pts')
                requested=false;generation=generation+1;remove_filter()
                state('性能不足，已关闭','请降低输出帧率或选择更轻量的画质')
                if audio_position then mp.commandv('seek',tostring(audio_position),'absolute+exact') end
                notify('补帧速度不足，已恢复原画播放；请降低帧率或画质')
                return
            end
            if math.abs(sync)<.1 and position and previous_position and position>previous_position and measured_fps and expected_fps and math.abs(measured_fps-expected_fps)/expected_fps<.05 then
                stable_samples=stable_samples+1
            else stable_samples=0 end
            previous_position=position
            if stable_samples>=3 and phase~='开启' then
                state('开启')
                if not announced then announced=true;notify('AI 补帧已开启') end
            end
        end)
    end
end
enable=function()
    if busy then return end
    if mp.get_property_number('speed',1)~=1 then requested=true;state('暂未启用','恢复正常播放速度后将自动开启');return end
    local installed=read_json(utils.join_path(root,'active.json'))
    if not current_install(installed) then install();return end
    local params,err=input_options();if not params then fail(err);return end
    requested=true;generation=generation+1;local token=generation
    busy=true;state('正在检查')
    job=mp.command_native_async({name='subprocess',args=helper_args('Probe'),playback_only=false,capture_stdout=true,capture_stderr=true},function(success,result)
        busy=false;job=nil
        if token~=generation or not requested then if requested then enable() end; return end
        local result_json
        for line in ((result and result.stdout) or ''):gmatch('[^\r\n]+') do local p=utils.parse_json(line);if p then result_json=p end end
        if not success or not result or result.status~=0 or not result_json or not result_json.ok then
            mp.msg.error(result_json and result_json.error or 'runtime probe failed');fail('补帧组件暂时不可用，请确认显卡驱动已更新');return
        end
        local configured,configure_error=pcall(function()
            if not activate_runtime then activate_runtime=dofile(utils.join_path(config,'rife/environment.lua')) end
            activate_runtime(result_json.activation)
        end)
        if not configured then
            local detail=tostring(configure_error)
            mp.msg.error(detail)
            local message='补帧组件暂时无法加载，请在组件管理中检查安装状态'
            if detail:find('组件版本已变化',1,true) then message='补帧组件已更新，请重启当前播放器一次'
            elseif detail:find("module 'ffi'",1,true) then message='当前播放器需要带LuaJIT的mpv才能直接加载补帧组件' end
            fail(message);return
        end
        params.gpu=result_json.gpu
        -- Build on a separate process, not inside mpv's render thread.
        cancel_file=utils.join_path(os.getenv('TEMP') or root,'mpv-rife-prepare-cancel-'..utils.getpid()..'-'..tostring(token))
        local request=utils.join_path(root,'request-'..utils.getpid()..'-'..tostring(token)..'.json')
        local f=io.open(request,'w');if not f then fail('无法准备补帧，请检查安装目录是否可写');return end
        f:write(utils.format_json(params));f:close()
        local args=helper_args('Prepare')
        args[#args+1]='-Request';args[#args+1]=request
        args[#args+1]='-CancelFile';args[#args+1]=cancel_file
        busy=true;state('正在准备')
        job=mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stdout=true,capture_stderr=true},function(prepared,answer)
            busy=false;job=nil;os.remove(request)
            if cancel_file then os.remove(cancel_file);cancel_file=nil end
            if token~=generation or not requested then
                if requested then enable() end
                return
            end
            if not prepared or not answer or answer.status~=0 then mp.msg.error(answer and answer.stderr or 'model preparation failed');fail('补帧准备未完成，请稍后重试');return end
            attach(token,params)
        end)
    end)
end
mp.register_script_message('toggle',function() if busy or requested or active then off() else enable() end end)
mp.register_script_message('install',install)
mp.register_script_message('cancel',off)
local function source_description()
    local p=mp.get_property_native('video-params') or {}
    if not p.w or not p.h then return '未打开视频' end
    local kind='动态范围未知'
    if p['dolby-vision-profile'] then kind='杜比视界'
    elseif p.gamma=='pq' then kind='HDR（PQ）'
    elseif p.gamma=='hlg' then kind='HDR（HLG）'
    elseif p.gamma=='bt.1886' or p.gamma=='srgb' then kind='SDR' end
    local fps=mp.get_property_number('container-fps')
    return kind..' · '..p.w..'×'..p.h..(fps and string.format(' · %.3f fps',fps) or '')
end
mp.register_script_message('info',function()
    notify('片源：'..source_description()..'\n补帧：'..phase..(expected_fps and string.format(' · 目标 %.3f fps',expected_fps) or '')..(measured_fps and string.format('\n输出估计：%.3f fps',measured_fps) or '')..(reason~='' and ('\n原因：'..reason) or ''))
end)
mp.register_script_message('open-runtime',function()
    if not utils.file_info(root) then notify('尚未创建运行环境目录');return end
    mp.command_native_async({name='subprocess',args={'explorer.exe',root},playback_only=false},function() end)
end)
mp.register_script_message('launch',function()
    local exe=mp.command_native({'expand-path','~~exe_dir/mpv.exe'})
    if not utils.file_info(exe) then notify('找不到播放器，请确认安装位置后重试');return end
    local args=helper_args('Launch');args[#args+1]='-Mpv';args[#args+1]=exe
    mp.command_native_async({name='subprocess',args=args,playback_only=false,capture_stderr=true},function(ok,result)
        if not ok or not result or result.status~=0 then notify('暂时无法打开播放器，请在组件管理中检查安装状态') end
    end)
end)
mp.register_event('start-file',function() generation=generation+1;announced=false;cancel_prepare();active=false;expected_fps=nil;measured_fps=nil;stable_samples=0;if requested then state('等待视频') end end)
mp.register_event('file-loaded',function() if requested then enable() end end)
mp.register_event('end-file',function(event)
    generation=generation+1;remove_filter()
    if event.reason=='error' and requested then requested=false;state('播放错误，已关闭','不自动重试');notify('补帧播放失败，已关闭；可重新打开原视频') end
end)
local function change_setting(key,value)
    if key=='model' and not model_names[value] then return end
    if key=='target_fps' then value=tonumber(value);if not value or value%1~=0 or value~=0 and (value<24 or value>360) then return end end
    local resume=requested
    generation=generation+1;cancel_prepare();remove_filter();options[key]=value
    announced=false
    update_menu()
    if resume then if not busy then enable() else state('正在准备') end else state('关闭') end
end
mp.register_script_message('model',function(value) change_setting('model',value) end)
mp.register_script_message('target',function(value) change_setting('target_fps',value) end)
mp.observe_property('estimated-vf-fps','number',function(_,fps)
    if active then measured_fps=fps end
end)
mp.observe_property('pause','bool',function(_,paused)
    if not active then return end
    slow_samples=0;settle_until=mp.get_time()+3
    if paused then state('已暂停') else stable_samples=0;state('正在恢复') end
end)
mp.observe_property('speed','number',function(_,speed)
    if not requested then return end
    if speed~=1 then generation=generation+1;cancel_prepare();remove_filter();state('暂未启用','恢复正常播放速度后将自动开启')
    elseif not busy then enable() end
end)
mp.register_event('seek',function()
    if not requested then return end
    stable_samples=0;measured_fps=nil
    slow_samples=0;settle_until=mp.get_time()+3
    if busy then generation=generation+1;cancel_prepare() end
    if active then state('正在恢复') end
end)
mp.enable_messages('error')
mp.register_event('log-message',function(event)
    if requested and (event.prefix or ''):find('vapoursynth',1,true) then
        requested=false;generation=generation+1;cancel_prepare()
        fail('补帧运行中断，已尝试关闭；请重新打开视频后重试')
    end
end)
mp.register_event('shutdown',function() cancel_prepare() end)
mp.observe_property('menu-data','native',update_menu)
mp.observe_property('user-data/mpv/context-menu/open','native',function(_,open) if open then update_menu() end end)
state('关闭')

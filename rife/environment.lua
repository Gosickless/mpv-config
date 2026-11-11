-- Load the private runtime into this player; never change system settings.
local ffi = require 'ffi'
ffi.cdef[[
int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char*, int, wchar_t*, int);
int __stdcall SetEnvironmentVariableW(const wchar_t*, const wchar_t*);
void* __stdcall AddDllDirectory(const wchar_t*);
void* __stdcall GetModuleHandleW(const wchar_t*);
unsigned long __stdcall GetModuleFileNameW(void*, wchar_t*, unsigned long);
int __stdcall WideCharToMultiByte(unsigned int, unsigned long, const wchar_t*, int, char*, int, const char*, int*);
void* __stdcall LoadLibraryExW(const wchar_t*, void*, unsigned long);
int _wputenv_s(const wchar_t*, const wchar_t*);
]]
local kernel = ffi.load('kernel32')
local crt = ffi.load('ucrtbase')
local directories = {}
local function wide(text)
    local count = kernel.MultiByteToWideChar(65001, 0, text, -1, nil, 0)
    assert(count > 0, '无法转换组件路径')
    local result = ffi.new('wchar_t[?]', count)
    assert(kernel.MultiByteToWideChar(65001, 0, text, -1, result, count) > 0)
    return result
end
local function normalized(path) return path:gsub('\\','/'):lower() end
local function load(path, name)
    local existing = kernel.GetModuleHandleW(wide(name))
    if existing ~= nil then
        local buffer = ffi.new('wchar_t[32768]')
        assert(kernel.GetModuleFileNameW(existing, buffer, 32768) > 0)
        local count = kernel.WideCharToMultiByte(65001,0,buffer,-1,nil,0,nil,nil)
        local text = ffi.new('char[?]',count)
        kernel.WideCharToMultiByte(65001,0,buffer,-1,text,count,nil,nil)
        assert(normalized(ffi.string(text)) == normalized(path), '组件版本已变化，请关闭并重新打开当前播放器一次')
        return
    end
    assert(kernel.LoadLibraryExW(wide(path),nil,0x1100) ~= nil, '无法加载补帧运行库')
end
return function(environment)
    -- Check an already loaded interpreter before changing its process settings.
    local existing = kernel.GetModuleHandleW(wide('vsscript.dll'))
    if existing ~= nil then load(environment.vsscript, 'vsscript.dll'); return end
    if kernel.GetModuleHandleW(wide('python313.dll')) ~= nil then load(environment.python, 'python313.dll') end
    for name,value in pairs({PYTHONHOME=environment.runtime, PYTHONPATH=environment.pythonpath, VSSCRIPT_PATH=environment.vsscript}) do
        assert(crt._wputenv_s(wide(name),wide(value)) == 0, '无法设置补帧进程环境')
        assert(kernel.SetEnvironmentVariableW(wide(name),wide(value)) ~= 0)
    end
    for _,path in ipairs(environment.directories) do
        if not directories[path] then
            local handle = kernel.AddDllDirectory(wide(path))
            assert(handle ~= nil, '无法设置补帧运行库目录')
            directories[path] = handle
        end
    end
    -- mpv caches its startup environment. Preloading by absolute path also lets
    -- its normal VSScript.dll lookup find this module without a new process.
    load(environment.python, 'python313.dll')
    load(environment.vsscript, 'vsscript.dll')
end

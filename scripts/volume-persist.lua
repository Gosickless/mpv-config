-- ============================================================
-- 全局音量记忆 volume-persist.lua
-- ------------------------------------------------------------
-- 作用：音量调整后对所有视频统一生效，并跨会话保存。
--       比如在视频 A 调到 45%，之后打开任何视频都是 45%。
-- 用法：正常调音量即可，值自动保存到 script-opts/volume_state.txt
-- 想重置：删掉 script-opts/volume_state.txt 或把里面的数字改掉
-- ============================================================

local state_file = mp.command_native({ "expand-path", "~~/script-opts/volume_state.txt" })

-- 读取并应用保存的音量
local function apply_volume()
    local f = io.open(state_file, "r")
    if not f then return end
    local line = f:read("*l")
    f:close()
    if line then
        local v = tonumber(line)
        if v and v >= 0 then
            mp.set_property("volume", v)
        end
    end
end

-- 保存当前音量
local function save_volume()
    local v = tonumber(mp.get_property("volume"))
    if v and v >= 0 then
        local f = io.open(state_file, "w")
        if f then
            f:write(string.format("%.0f", v))
            f:close()
        end
    end
end

-- 脚本启动时先应用已保存的音量（避免默认音量覆盖掉记忆值）
apply_volume()

-- 音量变化时保存
mp.observe_property("volume", "number", save_volume)

-- 每次加载文件时应用全局音量
mp.register_event("file-loaded", apply_volume)

--[[
@module  di
@summary 4 路 DI 采集驱动（仅 EHV 加载）
@version 1.0
@date    2026.11.18
@usage
引脚来自 board.profile.di_pins，顺序即 CH1~CH4。
配置为上拉输入：外部干接点闭合到 GND 时读到 0，断开时读到 1。
]]

local board = require "board"

local pins = board.profile.di_pins or {}

local _M = {}

-- 初始化：全部配置为上拉输入
function _M.init()
    for i = 1, #pins do
        gpio.setup(pins[i], nil, gpio.PULLUP)
    end
    log.info("di", "初始化完成", "通道数=" .. #pins)
end

-- 读取指定通道，返回 0/1；通道非法返回 nil
function _M.get(ch)
    local pin = pins[ch]
    if not pin then
        return nil
    end
    local v = gpio.get(pin)
    if v == nil then
        return nil
    end
    -- 注意：Lua 里 0 是真值，不能写 v and 1 or 0
    if v == 1 or v == true then
        return 1
    end
    return 0
end

return _M

--[[
@module  do
@summary 4 路 DO 继电器控制（仅 EHV 加载）
@version 1.0
@date    2026.11.18
@usage
引脚来自 board.profile.do_pins / do_en_pin。

硬件输出使能：
  EN（GPIO22）为常高电平的"输出使能"，不是锁存脉冲。
  实测脉冲方式继电器不动作，故与旧版 EHV 保持一致：EN 常高。

状态来源说明：
  GPIO3 会被内核重配，gpio.get 读回不可靠，
  因此本模块自己维护 status[ch] 作为唯一可信状态，
  对外统一用 get() 读状态表，不读 GPIO。
]]

local board = require "board"

local pins    = board.profile.do_pins or {}
local en_pin  = board.profile.do_en_pin

local status = { 0, 0, 0, 0 }

local _M = {}

-- 初始化：全部输出低电平
function _M.init()
    for i = 1, #pins do
        gpio.setup(pins[i], 0, gpio.PULLDOWN)
        status[i] = 0
    end
    -- EN 常高，打开输出使能
    if en_pin then
        gpio.setup(en_pin, 1, gpio.PULLDOWN)
    end
    for i = 1, #pins do
        gpio.set(pins[i], 0)
    end
    log.info("do", "初始化完成", "通道数=" .. #pins, "EN=" .. tostring(en_pin) .. " 常高")
end

-- 设置通道，val 为 0/1；返回 true/false
function _M.set(ch, val)
    if not pins[ch] then
        return false
    end
    local v = (val ~= 0) and 1 or 0
    gpio.set(pins[ch], v)
    status[ch] = v
    log.info("do", "通道动作", "CH" .. ch .. "=" .. v)
    return true
end

-- 读取状态（来自状态表，不读 GPIO）
function _M.get(ch)
    if not pins[ch] then
        return nil
    end
    return status[ch]
end

return _M

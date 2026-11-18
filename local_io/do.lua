--[[
@module  do
@summary 4 路 DO 继电器控制（仅 EHV 加载）
@version 1.0
@date    2026.11.18
@usage
引脚来自 board.profile.do_pins / do_en_pin。

硬件锁存时序（按 D700 系列硬件说明）：
  1. EN 置高，打开锁存
  2. 设置目标通道电平
  3. EN 置低，锁存当前状态

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

local function latch(ch, val)
    if en_pin then
        gpio.set(en_pin, 1)
    end
    gpio.set(pins[ch], val)
    if en_pin then
        gpio.set(en_pin, 0)
    end
end

-- 初始化：全部输出低电平，并锁存一次
function _M.init()
    for i = 1, #pins do
        gpio.setup(pins[i], 0, gpio.PULLDOWN)
        status[i] = 0
    end
    if en_pin then
        gpio.setup(en_pin, 0, gpio.PULLDOWN)
    end
    for i = 1, #pins do
        latch(i, 0)
    end
    log.info("do", "初始化完成", "通道数=" .. #pins, "EN=" .. tostring(en_pin))
end

-- 设置通道，val 为 0/1；返回 true/false
function _M.set(ch, val)
    if not pins[ch] then
        return false
    end
    local v = (val ~= 0) and 1 or 0
    latch(ch, v)
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

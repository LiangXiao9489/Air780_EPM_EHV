--[[
@module  led_blink
@summary NET LED 心跳闪烁
@version 1.1
@date    2026.11.18
@usage
两板 NET LED 均为 GPIO27（高电平亮），引脚从 profile.led_pin 取。
本文件没有对外接口，main.lua 中 require "led_blink" 即自动运行。
]]

local board   = require "board"
local profile = board.profile

local LED_PIN = profile and profile.led_pin

if not LED_PIN then
    log.warn("led_blink", "本板未定义 LED 引脚，跳过")
    return {}
end

local function led_blink_task()
    gpio.setup(LED_PIN, 0, gpio.PULLDOWN)
    while true do
        gpio.set(LED_PIN, 1)
        sys.wait(100)
        gpio.set(LED_PIN, 0)
        sys.wait(100)
    end
end

sys.taskInit(led_blink_task)

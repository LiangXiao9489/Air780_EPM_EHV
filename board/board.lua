--[[
@module  board
@summary 板型识别：rtos.bsp() → EPM / EHV / UNKNOWN
@version 1.0
@date    2026.11.18
@usage
main.lua 最先 require 本模块，后续所有硬件资源统一从 board.profile 取。

识别规则（子串匹配，避免固件版本带后缀导致全等失败）：
  rtos.bsp() 含 "EPM" → EPM
  rtos.bsp() 含 "EHV" → EHV
  都不含           → UNKNOWN

UNKNOWN 时 profile 为 nil，上层必须停止初始化任何硬件。
在错误板子上操作 GPIO 的代价远大于"不工作"：
EPM 的 GPIO21/22 是电源输出控制脚，EHV 的 GPIO21/22 是继电器与锁存。

对外 API：
  name          "EPM" / "EHV" / "UNKNOWN"
  bsp           rtos.bsp() 原始字符串
  is_epm        boolean
  is_ehv        boolean
  is_known      boolean
  profile       对应板型硬件资源表（UNKNOWN 时为 nil）
]]

local _M = {}

local bsp = rtos.bsp() or ""
_M.bsp = bsp

local upper = string.upper(bsp)
if string.find(upper, "EPM", 1, true) then
    _M.name = "EPM"
elseif string.find(upper, "EHV", 1, true) then
    _M.name = "EHV"
else
    _M.name = "UNKNOWN"
end

_M.is_epm   = (_M.name == "EPM")
_M.is_ehv   = (_M.name == "EHV")
_M.is_known = (_M.name ~= "UNKNOWN")

if _M.is_epm then
    _M.profile = require "profile_epm"
elseif _M.is_ehv then
    _M.profile = require "profile_ehv"
end

log.info("board", "识别到板型 " .. _M.name, "bsp=" .. bsp)

if _M.profile then
    for name, port in pairs(_M.profile.ports) do
        log.info("board", "端口 " .. name,
                 "uartid=" .. tostring(port.uartid),
                 "en_pin=" .. tostring(port.en_pin),
                 "启用=" .. tostring(port.enabled))
    end
    log.info("board", "本地IO=" .. (_M.profile.has_local_io and "DI/DO" or "无"),
             "LED=" .. tostring(_M.profile.led_pin),
             "WDT=" .. tostring(_M.profile.wdt_pin),
             "ADC=" .. tostring(_M.profile.adc_ch))
end

return _M

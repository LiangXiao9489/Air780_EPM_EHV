--[[
@module  main
@summary Air780 EPM / EHV 二合一网关固件入口
@version 1.0.0
@date    2026.11.18
@usage
按块移植，当前进度：块 1（板型识别 + 配置 + 设备支撑）

后续块逐步放开 require：
  块 2  data/point_table + data/store
  块 3  modbus/core + modbus/hardware + modbus/uart_lock
  块 4  modbus/master + modbus/write_through
  块 5  modbus/slave
  块 6  local_io/di + do + do_write + sampler
  块 7  wireless 网络与 MQTT 基础
  块 8  wireless 协议业务 + OTA
]]

require "sys"

PROJECT = "Air780_EPM_EHV"
VERSION = "1.0.0"

pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

log.info("main", "=========== 当前模组:[" .. rtos.bsp() .. "] 固件版本 [" .. VERSION .. "] ===========")
log.info("main", "=========== 芯片 UID [" .. mcu.unique_id():toHex() .. "] ===========")

-- 1. 板型识别：必须最先，后续所有硬件资源都依赖它
local board = require "board"

if not board.is_known then
    -- 未知板型：只打印，不初始化任何硬件，避免误操作 GPIO
    log.error("main", "未知板型 bsp=" .. board.bsp .. "，已停止硬件初始化")
else
    -- 2. 配置：默认值按板型裁剪，require 即加载/落盘
    require "config"

    -- 3. 设备支撑
    require "ext_wdt"
    require "led_blink"

    log.info("main", "块1 完成：板型/配置/设备支撑就绪")
end

sys.run()

--[[
@module  main
@summary Air780 EPM / EHV 二合一网关固件入口
@version 1.6.0
@date    2026.11.18
@usage
按块移植，当前进度：块 6（EHV 本地 DI/DO 与采样）

已完成：
  块 1  板型识别 / 配置 / 看门狗 / LED
  块 2  点表展开 / store 缓存初始化
  块 3  Modbus 编解码 / 动态端口 / u1 互斥锁
  块 4  EPM 主站轮询 / 485 写穿透
  块 5  从站应答（两板共用）
  块 6  EHV 本地 DI/DO 驱动 / 本地采样 / 本地写

后续块逐步放开 require：
  块 7  wireless 网络与 MQTT 基础
  块 8  wireless 协议业务 + OTA
]]

require "sys"

PROJECT = "Air780_EPM_EHV"
VERSION = "1.6.0"

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

    -- 3. 数据层：点表展开 + 缓存初始化（显式调用，采集侧不再负责 init）
    local store    = require "store"
    local pt       = require "point_table"
    local data_ok  = store.init(pt)
    if not data_ok then
        -- 点表有误时不启动业务，但仍然喂狗/闪灯，避免变成复位循环
        log.error("main", "store 初始化失败，点表有误；已跳过业务，仅保活")
    end

    -- 4. 设备支撑（无论数据层是否就绪都要运行）
    require "ext_wdt"
    require "led_blink"

    -- 5. 传输层：按板型动态初始化 1~N 路 485
    if data_ok then
        local hardware = require "hardware"
        hardware.init()

        -- 6. 采集链路（板型相关）
        if board.is_epm then
            -- EPM：u1 互斥锁 + 485 写穿透 + 主站轮询
            require "uart_lock"

            local write_through = require "write_through"
            store.set_writer(write_through.write)

            require "master"

            log.info("main", "块3+4 完成：传输层与 EPM 采集链路就绪")
        else
            -- EHV：本地 DI/DO 采集，写入 store 后由从站/上报消费
            local di_mod = require "di"
            local do_mod = require "do"

            di_mod.init()
            do_mod.init()

            store.set_writer(require("do_write").write)
            require "sampler"

            log.info("main", "块3+6 完成：传输层与本地 IO 采样就绪")
        end

        -- 7. 从站应答（两板共用，走 u2）
        require "slave"
        log.info("main", "块5 完成：从站已加载")
    end
end

sys.run()

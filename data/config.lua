--[[
@module  config
@summary 网关运行时配置（JSON 文件持久化，按板型裁剪默认值）
@version 2.0
@date    2026.11.18
@usage
所有"运行时可配置"的参数集中管理，文件系统落盘，重启不丢失。

文件位置：/gateway_cfg.json
首次启动：文件不存在 → 写入本板默认值到文件
后续启动：文件存在 → 读入内存；OTA 新增字段时 get() 自动 fallback 默认值

与旧版差异：
  默认值不再是固定表，而是按 board.profile 生成：
  - 只有 enabled 的串口才生成 uX_baudrate / uX_databits / uX_stopbits / uX_parity
  - 写使能参数名由 profile.write_enable_key 决定
    EPM = write_through_en，EHV = mqtt_do_en（平台侧参数名保持不变）
  - EHV 额外生成 local_sample_ms

对外 API：
  get(key)              读参数，文件缺这个 key 时 fallback 默认值
  set(key, val)         改内存 + 立刻落盘
  all()                 返回当前内存中的完整 cfg table（只读）
  defaults()            返回本板默认值表（调试用）
  factory_reset()       删除配置文件 + 重启

main.lua require 顺序要求：
  require "board"    ← 最先
  require "config"   ← hardware 初始化串口时要读它
  require "hardware"
]]

local board   = require "board"
local profile = board.profile

local _M = {}

-- ============================================================
-- 文件路径
-- ============================================================
local CONFIG_PATH = "/gateway_cfg.json"

-- ============================================================
-- 默认参数：按板型生成
-- ============================================================
local DEFAULT_CFG = {}

-- 串口参数：只生成本板启用的端口
for name, port in pairs(profile.ports) do
    if port.enabled then
        DEFAULT_CFG[name .. "_baudrate"] = port.baudrate
        DEFAULT_CFG[name .. "_databits"] = port.databits
        DEFAULT_CFG[name .. "_stopbits"] = port.stopbits
        DEFAULT_CFG[name .. "_parity"]   = port.parity
    end
end

-- 业务参数（两板一致）
DEFAULT_CFG.upload_interval_min = 5   -- MQTT 实时数据上报间隔（分钟）
DEFAULT_CFG.change_check_sec    = 5   -- 变化数据检测周期（秒）

-- 点表编号（仅 EPM）：1=测试点表 2=机组点表，修改后重启生效
if board.is_epm then
    DEFAULT_CFG.point_table_id = 1
end

-- 主动上行开关（默认关闭，由平台下发 1 开启）
DEFAULT_CFG.report_real_enable   = false
DEFAULT_CFG.report_change_enable = false

-- 写使能（名字按板型）
DEFAULT_CFG[profile.write_enable_key] = true

-- 本地采样周期（仅 EHV）
if profile.local_sample_ms then
    DEFAULT_CFG.local_sample_ms = profile.local_sample_ms
end

-- 内存镜像
local cfg

-- ============================================================
-- 内部：落盘
-- ============================================================
local function save()
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(json.encode(cfg))
        f:close()
    else
        log.error("config", "写入失败，磁盘可能满了")
    end
end

-- ============================================================
-- 内部：从文件读或写默认
-- ============================================================
local function load_or_init()
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        cfg = json.decode(raw)
        if type(cfg) ~= "table" then
            log.warn("config", "文件损坏，用默认值覆盖")
            cfg = {}
            save()
        end
    else
        log.info("config", "首次启动，写入默认配置", "板型=" .. board.name)
        cfg = {}
        for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
        save()
    end
end

-- ============================================================
-- 对外 API
-- ============================================================

-- 读参数：文件里有就用文件的，没有就 fallback 默认值
function _M.get(key)
    local v = cfg[key]
    if v == nil then
        return DEFAULT_CFG[key]
    end
    return v
end

-- 写参数：改内存 + 立刻落盘
function _M.set(key, val)
    cfg[key] = val
    save()
end

-- 返回完整内存表（调用方只读，别改里面的值，改了不走 save）
function _M.all()
    return cfg
end

-- 读本板默认表（调试用）
function _M.defaults()
    return DEFAULT_CFG
end

-- 恢复出厂：清空内存配置 → 删除文件 → 重启
function _M.factory_reset()
    log.warn("config", "恢复出厂设置！")
    cfg = {}
    os.remove(CONFIG_PATH)
    log.info("config", "配置文件已删除，即将重启...")
    rtos.reboot()
end

-- ============================================================
-- 模块加载时自动 init（require "config" 即运行）
-- 前提：main.lua 已先 require "board"
-- ============================================================
load_or_init()
log.info("config", "初始化完成", "文件=" .. CONFIG_PATH, "板型=" .. board.name)

return _M

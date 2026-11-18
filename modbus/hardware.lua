--[[
@module  hardware
@summary RS485 底层收发模块（纯管道，不知道任何协议），按板型动态初始化 1~N 路
@version 4.0
@date    2026.11.18
@usage
与旧版差异：
  旧版把 u1/u2 的参数全部写死在模块顶部，并且"u2 一定没有 EN 脚"是隐含假设；
  新版所有端口来自 board.profile.ports，只初始化 enabled=true 的端口，
  串口参数来自 config（uX_baudrate 等），方向脚/延时/清缓存策略来自 profile。

端口数量由板型决定：
  EPM：u1（EN=GPIO25，8N2，问答口）+ u2（无 EN，8N1，从站口）
  EHV：u2（EN=GPIO25，8N1，从站口）；u1 物理存在但 enabled=false，完全不碰

对外 API：
  init()                          初始化所有启用端口（main 调用一次）
  u1_send / u1_wait_response      u1 收发（未启用时 send 返回 false、wait 返回 nil,-3）
  u2_send / u2_wait_response      u2 收发
  send / wait_response            兼容旧调用，等价于 u1
  has_port(name)                  该板是否启用了此端口
  get_port(name)                  取端口内部表（调试用）
  set_recv_hook(fn)               安装被动接收钩子（测试/调试，与 wait_response 互斥）
]]

local config  = require "config"
local board   = require "board"
local profile = board.profile

-- parity 字符串 → uart 常量
local PARITY_MAP = {
    N = uart.NONE,
    E = uart.EVEN,
    O = uart.ODD,
}

-- 接收侧公共参数
-- 帧内静默间隔（毫秒）：连续无新数据超过此值视为一帧结束
-- 9600 波特率下 1 字节约 1.15ms，Modbus 规定帧间静默 3.5 字符 ≈ 4ms
-- 取 8ms 既有余量，又把每笔事务的固定延迟从 20ms 降到 8ms
local frame_gap_ms  = 8
local recv_max_read = 256

-- 接收钩子：装了就进入"收到就抛给外部"的被动接收模式（仅供测试/调试）
local recv_hook = nil

-- 端口表
local ports         = {}   -- ports[name] = port
local port_names    = {}   -- 已启用端口名，按名字排序，保证日志稳定
local port_by_uartid = {}  -- uartid -> port，接收回调分发用
local inited        = false

-- ============================================================
-- 内部工具：字节串转十六进制
-- ============================================================
local function to_hex_spaced(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X", data:byte(i))
    end
    return table.concat(parts, " ")
end

-- ============================================================
-- 接收回调（所有端口共用）：读走该串口全部可用数据，追加到对应暂存区
-- 未装接收钩子：发布事件唤醒 wait_response
-- 装了接收钩子：把这一批数据直接交给钩子（测试模式），不再走 wait_response
-- ============================================================
local function port_recv_cb(id, len)
    local port = port_by_uartid[id]
    if not port then
        return
    end

    local s = ""
    repeat
        s = uart.read(id, recv_max_read)
        if #s > 0 then
            port.resp_buffer = (port.resp_buffer or "") .. s
        end
    until s == ""

    if port.resp_buffer and #port.resp_buffer > 0 then
        if recv_hook then
            local data = port.resp_buffer
            port.resp_buffer = nil
            recv_hook(port.name, data)
        else
            sys.publish(port.resp_event)
        end
    end
end

-- ============================================================
-- 发送完成回调（仅打印日志）
-- ============================================================
local function port_sent_cb(id)
    -- log.info("485", "sent", "uart=" .. id, "发送完成")
end

-- ============================================================
-- 发送
-- ============================================================
local function port_send(port, data)
    if type(data) ~= "string" or #data == 0 then
        log.warn("485", port.name .. " send 无效数据")
        return false
    end

    -- 问答口发送前清残留；从站口不清，避免丢掉等待处理的上行请求
    if port.clear_rx_on_send then
        port.resp_buffer = nil
        if uart.rxClear then
            uart.rxClear(port.uartid)
        end
    end

    log.info("485", "send", port.name, "uart=" .. port.uartid,
             "len=" .. #data, "hex=" .. to_hex_spaced(data))
    uart.write(port.uartid, data)
    return true
end

-- ============================================================
-- 等待响应：先等首段数据，再等总线静默判定一帧结束
-- ============================================================
local function port_wait_response(port, timeout_ms)
    local t0 = mcu.ticks()

    -- 阶段1：等待首段数据到达
    while not (port.resp_buffer and #port.resp_buffer > 0) do
        local remain = timeout_ms - (mcu.ticks() - t0)
        if remain <= 0 then
            log.warn("485", "wait_response", port.name .. " 超时(" .. timeout_ms .. "ms)")
            return nil, -1
        end
        if not sys.waitUntil(port.resp_event, remain) then
            log.warn("485", "wait_response", port.name .. " 超时(" .. timeout_ms .. "ms)")
            return nil, -1
        end
    end

    -- 阶段2：等总线静默（连续 frame_gap_ms 没有新数据，认为一帧收完）
    local last_len
    repeat
        if not port.resp_buffer then
            log.warn("485", "wait_response", port.name .. " resp_buffer 意外为 nil")
            return nil, -2
        end
        last_len = #port.resp_buffer
        sys.wait(frame_gap_ms)
    until port.resp_buffer and #port.resp_buffer == last_len

    local data = port.resp_buffer
    port.resp_buffer = nil

    log.info("485", "recv", port.name, "uart=" .. port.uartid,
             "len=" .. #data, "hex=" .. to_hex_spaced(data))
    return data, 0
end

-- ============================================================
-- 构造端口表：只构造 enabled 的端口，参数按 config + profile 合成
-- ============================================================
local function build_ports()
    local names = {}
    for name, p in pairs(profile.ports) do
        if p.enabled then
            names[#names + 1] = name
        end
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local p = profile.ports[name]
        local port = {
            name             = name,
            uartid           = p.uartid,
            baudrate         = config.get(name .. "_baudrate") or p.baudrate,
            databits         = config.get(name .. "_databits") or p.databits,
            stopbits         = config.get(name .. "_stopbits") or p.stopbits,
            parity           = PARITY_MAP[config.get(name .. "_parity") or p.parity] or uart.NONE,
            order            = uart.LSB,
            buf_size         = 1024,
            en_pin           = p.en_pin,          -- nil = 硬件自动翻转
            en_level         = p.en_level or 0,
            rs485_delay      = p.rs485_delay or 20000,
            resp_event       = "UART485_" .. string.upper(name) .. "_RESP",
            resp_buffer      = nil,
            clear_rx_on_send = p.clear_rx_on_send and true or false,
        }
        ports[name] = port
        port_by_uartid[port.uartid] = port
        port_names[#port_names + 1] = name
    end
end

-- ============================================================
-- 端口初始化
-- ============================================================
local function port_init(port)
    log.info("485", "init", port.name,
             "uart=" .. port.uartid,
             "baud=" .. port.baudrate,
             "data=" .. port.databits,
             "stop=" .. port.stopbits,
             "parity=" .. tostring(port.parity),
             "en_pin=" .. tostring(port.en_pin),
             "delay=" .. port.rs485_delay .. "us")

    -- en_pin 为 nil 时 uart.setup 不做方向切换（适配硬件自动翻转的 485）
    uart.setup(port.uartid, port.baudrate, port.databits, port.stopbits,
               port.parity, port.order, port.buf_size,
               port.en_pin, port.en_level, port.rs485_delay)

    uart.on(port.uartid, "receive", port_recv_cb)
    uart.on(port.uartid, "sent", port_sent_cb)
end

-- ============================================================
-- 按名字生成收发函数（未启用端口给出明确失败，不抛错）
-- ============================================================
local function make_send(name)
    return function(data)
        local port = ports[name]
        if not port then
            log.warn("485", name .. " 本板未启用，send 被忽略")
            return false
        end
        return port_send(port, data)
    end
end

local function make_wait(name)
    return function(timeout_ms)
        local port = ports[name]
        if not port then
            return nil, -3   -- -3 = 端口不存在（区别于 -1 超时）
        end
        return port_wait_response(port, timeout_ms)
    end
end

local u1_send          = make_send("u1")
local u1_wait_response = make_wait("u1")
local u2_send          = make_send("u2")
local u2_wait_response = make_wait("u2")

-- ============================================================
-- 模块导出
-- ============================================================
local _M = {}

function _M.init()
    if inited then
        return true
    end
    build_ports()
    for _, name in ipairs(port_names) do
        port_init(ports[name])
    end
    inited = true
    log.info("485", "init", #port_names .. " 路 485 初始化完成",
             "端口=" .. table.concat(port_names, ","))
    return true
end

_M.u1_send          = u1_send
_M.u1_wait_response = u1_wait_response
_M.u2_send          = u2_send
_M.u2_wait_response = u2_wait_response

-- 兼容旧接口：默认指向 u1（下行设备口）
_M.send          = u1_send
_M.wait_response = u1_wait_response

function _M.has_port(name)
    return ports[name] ~= nil
end

function _M.get_port(name)
    return ports[name]
end

-- 安装接收钩子（仅供测试/调试）：收到数据时回调 fn(端口名, 数据)
-- 装了之后 wait_response 不再收数据，两种模式互斥；传 nil 可卸载
function _M.set_recv_hook(fn)
    recv_hook = fn
end

return _M

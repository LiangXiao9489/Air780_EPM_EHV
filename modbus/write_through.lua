--[[
@module  write_through
@summary EPM 485 写穿透：把写请求转发给 u1 上的从机（仅 EPM 加载）
@version 1.0
@date    2026.11.18
@usage
从 down.lua 的 write_through_single 提取而来，作为 store 的写入实现注册：

  store.set_writer(require("write_through").write)

写入流程：
  1. 按 reg_type 选功能码（线圈 0x05 / 保持寄存器 0x06）组帧
  2. 拿 u1 互斥锁，发送，等响应，释放锁
  3. 解帧；异常响应或超时都返回 false
  4. 成功后由 store.set_by_tag 统一回写缓存（本模块不重复写）

对外 API：
  write(reg, value) -> true / false, reason
]]

local uart485   = require "hardware"
local core      = require "core"
local uart_lock = require "uart_lock"

local _M = {}

local RESPONSE_TIMEOUT_MS = 2000

-- reg:   store 展开后的完整 reg（含 dev_id / s_addr / reg_type / tag）
-- value: 数字
function _M.write(reg, value)
    local fc, adu
    if reg.reg_type == 1 then
        -- 线圈：0=OFF，非0=ON（Modbus 0x05 写 ON 要发 0xFF00）
        local coil_val = (value ~= 0) and 0xFF00 or 0x0000
        fc = core.FC_WRITE_SINGLE_COIL
        adu = core.encode_request({
            dev_id = reg.dev_id,
            fc     = fc,
            addr   = reg.s_addr,
            value  = coil_val,
        })
    else
        -- 保持寄存器
        fc = core.FC_WRITE_SINGLE_REGISTER
        adu = core.encode_request({
            dev_id = reg.dev_id,
            fc     = fc,
            addr   = reg.s_addr,
            value  = value,
        })
    end

    if not adu then
        log.warn("write_through", "组帧失败", "dev=" .. reg.dev_id, "tag=" .. tostring(reg.tag))
        return false
    end

    if not uart_lock.lock("mqtt_set") then
        log.warn("write_through", "获取 u1 锁超时", "tag=" .. tostring(reg.tag))
        return false
    end

    uart485.u1_send(adu)
    local resp_adu = uart485.u1_wait_response(RESPONSE_TIMEOUT_MS)
    uart_lock.unlock()

    if not resp_adu then
        log.warn("write_through", "超时", "dev=" .. reg.dev_id, "tag=" .. tostring(reg.tag))
        return false
    end

    local resp, err = core.decode_response(resp_adu, fc)
    if not resp then
        log.warn("write_through", "解帧失败",
                 "tag=" .. tostring(reg.tag), "err=0x" .. string.format("%02X", err))
        return false
    end
    if resp.is_exception then
        log.warn("write_through", "从机异常", "tag=" .. tostring(reg.tag),
                 "ec=0x" .. string.format("%02X", resp.exception_code))
        return false
    end

    log.info("write_through", "写穿透成功",
             "tag=" .. tostring(reg.tag), "value=" .. tostring(value))
    return true
end

return _M

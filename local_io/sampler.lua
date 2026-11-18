--[[
@module  sampler
@summary 本地采样任务：DI/DO 状态定时写入 store（仅 EHV 加载）
@version 1.0
@date    2026.11.18
@usage
采样周期取配置项 local_sample_ms（默认 500ms）。

采样对象：点表中带 ch 字段的点位
  reg_type=2（离散输入）→ di.get(ch)
  reg_type=1（线圈）    → do.get(ch)（状态表，不读 GPIO）

写入 store 后：
  - 上行从站（u2）能读到实时值
  - MQTT 的 call 能读到不超过一个采样周期的值
  - report 的变化检测按自己的 change_check_sec 比较缓存
]]

local store  = require "store"
local config = require "config"
local di     = require "di"
local do_mod = require "do"

local dev_id = store.get_primary_dev()

local function read_point(reg)
    if not reg.ch then
        return nil
    end
    if reg.reg_type == 2 then
        return di.get(reg.ch)
    elseif reg.reg_type == 1 then
        return do_mod.get(reg.ch)
    end
    return nil
end

sys.taskInit(function()
    sys.wait(1000)

    local period = tonumber(config.get("local_sample_ms")) or 500
    log.info("sampler", "本地采样启动",
             "dev=" .. tostring(dev_id), "周期=" .. period .. "ms")

    local last_di = {}
    while true do
        local regs = store.get_regs_by_dev(dev_id) or {}
        for i = 1, #regs do
            local reg = regs[i]
            local v = read_point(reg)
            if v ~= nil then
                store.write_by_a(dev_id, reg.s_addr, v, 0)

                -- DI 变化时打一条日志，便于现场测试
                if reg.reg_type == 2 and last_di[reg.tag] ~= v then
                    last_di[reg.tag] = v
                    log.info("sampler", "DI 变化", reg.tag .. "=" .. v)
                end
            end
        end

        sys.wait(period)
    end
end)

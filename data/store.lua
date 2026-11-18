--[[
@module  store
@summary 寄存器缓存层（整个网关共享的数据中枢）
@version 2.0
@date    2026.11.18
@usage
本模块负责寄存器缓存的全生命周期管理，是网关唯一的数据源：
  - 主站轮询 / 本地采样 → 写缓存
  - 从站应答上位机     → 读缓存
  - MQTT report/down    → 读缓存 / 经 writer 写缓存

每个 slot 同时存 A 侧 (dev_id, s_addr) 和 B 侧 (dev_id, n_addr)：
  cache_a[dev_id][s_addr] = slot   — 下行采集侧更新用
  cache_b[dev_id][n_addr] = slot   — 上行从站读取用
EPM 的 s_addr 与 n_addr 不同（协议转换）；EHV 二者相同（100 转 100）。

写入路径由板型决定，通过 set_writer() 注册：
  EPM → write_through（485 写穿透到从机）
  EHV → do_write（本机继电器）

对外 API：
  init(pt)                            展开点表建 slot（main 调用，只调用一次）
  set_writer(fn)                      注册写入实现 fn(reg, val) -> ok, err
  set_by_tag(dev_id, tag, val)        统一写入入口（down.lua 用）
  write_by_a(dev_id, s_addr, data, err)  采集成功后写缓存
  read_by_b(dev_id, n_addr)           从站读缓存（返回 data, errcode）
  read_by_a(dev_id, s_addr)           按 A 侧地址读（调试用）
  get_reg_by_b(dev_id, n_addr)        从站查完整点表配置
  get_reg_by_tag(dev_id, tag)         按 tag 查完整配置（含 ch / rw）
  read_by_tag(dev_id, tag)            按 tag 读缓存值
  get_slot_by_tag(dev_id, tag)        按 tag 取 slot（data/errcode/ts）
  get_all_regs()                      展开后的完整 reg 表（采集用）
  get_regs_by_dev(dev_id)             按设备取 regs
  get_devs()                          返回 slave_dev 列表
  get_primary_dev()                   返回第一个设备 id（本地 IO 用）
  has_n_addr(dev_id, n_addr)          判断 B 侧地址是否存在
  get_point_values()                  按点位聚合当前缓存值（上报用）

持久化：纯 RAM，重启后由采集侧重新填充。
]]

local _M = {}

-- ============================================================
-- 错误码
-- ============================================================
_M.ERR_UNINIT = 0x08   -- 未采集过（缓存状态标记，永不上总线）

-- set_by_tag 失败原因（字符串，down.lua 归类用）
_M.ERR_NOT_FOUND = "not_found"
_M.ERR_READONLY  = "readonly"
_M.ERR_NO_WRITER = "no_writer"
_M.ERR_WRITE     = "write_fail"

-- ============================================================
-- 缓存状态
-- ============================================================
local cache_a = {}        -- cache_a[dev_id][s_addr] = slot
local cache_b = {}        -- cache_b[dev_id][n_addr] = slot
local regs_by_b = {}      -- regs_by_b[dev_id][n_addr] = 完整 reg
local regs_by_tag = {}    -- regs_by_tag[dev_id][tag] = 完整 reg（仅 group_offset==0）
local expanded_regs = {}  -- 展开后的完整点表
local dev_list = {}       -- slave_dev 原样

local writer = nil        -- fn(reg, val) -> ok, err

-- ============================================================
-- 写入实现注册（板型相关）
-- ============================================================
function _M.set_writer(fn)
    writer = fn
    log.info("store", "写入实现已注册", fn and "ok" or "nil")
end

-- ============================================================
-- 判断 (dev_id, n_addr) 是否在 cache_b 里
-- ============================================================
local function has_n_addr(dev_id, n_addr)
    return cache_b[dev_id] and cache_b[dev_id][n_addr] ~= nil
end
_M.has_n_addr = has_n_addr

-- ============================================================
-- 初始化（从点表展开，建 slot + 双向索引）
-- ============================================================
function _M.init(pt)
    cache_a = {}
    cache_b = {}
    regs_by_b = {}
    regs_by_tag = {}
    expanded_regs = {}
    dev_list = {}

    if type(pt) ~= "table" or type(pt.regs) ~= "table" then
        log.error("store", "点表为空或格式错误")
        return false
    end

    local slave_dev = pt.meta.slave_dev or {}
    local regs_tpl = pt.regs or {}
    dev_list = slave_dev

    log.info("store", "开始初始化", "设备数=" .. #slave_dev, "模板寄存器数=" .. #regs_tpl)

    for _, dev_id in ipairs(slave_dev) do
        cache_a[dev_id] = {}
        cache_b[dev_id] = {}
        regs_by_b[dev_id] = {}

        for _, tpl in ipairs(regs_tpl) do
            local reg_type = tpl.reg_type
            local count    = tpl.reg_count or 1

            if type(count) ~= "number" or count < 1 then
                log.error("store", "点表错误", "dev_id=" .. dev_id,
                          "tag=" .. tostring(tpl.tag), "reg_count 非法=" .. tostring(tpl.reg_count))
                return false
            end
            if (reg_type == 1 or reg_type == 2) and count > 1 then
                log.error("store", "点表错误", "dev_id=" .. dev_id,
                          "tag=" .. tostring(tpl.tag), "线圈/离散输入不支持 reg_count>1")
                return false
            end

            -- 区间不重叠校验
            for i = 0, count - 1 do
                if cache_a[dev_id][tpl.s_addr + i] then
                    log.error("store", "点表错误", "dev_id=" .. dev_id,
                              "s_addr=" .. (tpl.s_addr + i) .. " 重复或区间重叠")
                    return false
                end
                if cache_b[dev_id][tpl.n_addr + i] then
                    log.error("store", "点表错误", "dev_id=" .. dev_id,
                              "n_addr=" .. (tpl.n_addr + i) .. " 重复或区间重叠")
                    return false
                end
            end

            -- 离散输入/输入寄存器强制只读
            local rw = tpl.rw or "r"
            if reg_type == 2 or reg_type == 4 then
                rw = "r"
            end

            for i = 0, count - 1 do
                local s_addr = tpl.s_addr + i
                local n_addr = tpl.n_addr + i

                local slot = {
                    dev_id  = dev_id,
                    s_addr  = s_addr,
                    n_addr  = n_addr,
                    data    = 0xFFFF,
                    errcode = _M.ERR_UNINIT,
                    ts      = 0,
                }
                cache_a[dev_id][s_addr] = slot
                cache_b[dev_id][n_addr] = slot

                local full_reg = {
                    dev_id       = dev_id,
                    num          = tpl.num,
                    tag          = tpl.tag,
                    s_addr       = s_addr,
                    n_addr       = n_addr,
                    base_s_addr  = tpl.s_addr,
                    base_n_addr  = tpl.n_addr,
                    reg_type     = reg_type,
                    reg_count    = count,
                    group_offset = i,
                    data_type    = tpl.data_type,
                    scale_factor = tpl.scale_factor,
                    rw           = rw,
                    ch           = tpl.ch,          -- 仅 EHV 的 DI/DO 有值
                    bits         = (i == 0) and tpl.bits or nil,
                }
                regs_by_b[dev_id][n_addr] = full_reg
                expanded_regs[#expanded_regs + 1] = full_reg

                if i == 0 then
                    regs_by_tag[dev_id] = regs_by_tag[dev_id] or {}
                    regs_by_tag[dev_id][tpl.tag] = full_reg
                end
            end
        end
    end

    log.info("store", "初始化完成",
             "总slot数=" .. #expanded_regs,
             "设备数=" .. #dev_list)
    return true
end

-- ============================================================
-- 采集侧写入
-- ============================================================
function _M.write_by_a(dev_id, s_addr, data, err)
    local slot = cache_a[dev_id] and cache_a[dev_id][s_addr]
    if not slot then
        log.warn("store", "write_by_a",
                 "dev_id=" .. tostring(dev_id),
                 "s_addr=" .. tostring(s_addr),
                 "slot不存在")
        return false
    end
    slot.data = data
    slot.errcode = err or 0
    slot.ts = os.time()
    return true
end

-- ============================================================
-- 读取
-- ============================================================
function _M.read_by_b(dev_id, n_addr)
    local slot = cache_b[dev_id] and cache_b[dev_id][n_addr]
    if not slot then
        return nil, 0x02
    end
    return slot.data, slot.errcode
end

function _M.read_by_a(dev_id, s_addr)
    local slot = cache_a[dev_id] and cache_a[dev_id][s_addr]
    if not slot then return nil, 0x02 end
    return slot.data, slot.errcode
end

-- ============================================================
-- 点表查询
-- ============================================================
function _M.get_reg_by_b(dev_id, n_addr)
    if not regs_by_b[dev_id] then return nil end
    return regs_by_b[dev_id][n_addr]
end

function _M.get_all_regs()
    return expanded_regs
end

function _M.get_regs_by_dev(dev_id)
    local result = {}
    for _, r in ipairs(expanded_regs) do
        if r.dev_id == dev_id then
            result[#result + 1] = r
        end
    end
    return result
end

function _M.get_devs()
    return dev_list
end

function _M.get_primary_dev()
    return dev_list[1]
end

-- ============================================================
-- MQTT 专用：按 tag 查 reg / 读缓存值
-- ============================================================
function _M.get_reg_by_tag(dev_id, tag)
    if not regs_by_tag[dev_id] then return nil end
    return regs_by_tag[dev_id][tag]
end

function _M.read_by_tag(dev_id, tag)
    local reg = _M.get_reg_by_tag(dev_id, tag)
    if not reg then
        return nil, _M.ERR_UNINIT
    end
    return _M.read_by_b(dev_id, reg.n_addr)
end

function _M.get_slot_by_tag(dev_id, tag)
    local reg = _M.get_reg_by_tag(dev_id, tag)
    if not reg then return nil end
    return cache_b[dev_id] and cache_b[dev_id][reg.n_addr]
end

-- ============================================================
-- 统一写入入口（down.lua / 从站写穿透共用）
-- 返回: true / false, reason
-- ============================================================
function _M.set_by_tag(dev_id, tag, val)
    local reg = _M.get_reg_by_tag(dev_id, tag)
    if not reg then
        return false, _M.ERR_NOT_FOUND
    end
    if reg.rw ~= "rw" then
        return false, _M.ERR_READONLY
    end
    if (reg.reg_count or 1) > 1 then
        -- 多寄存器写由 down.lua 走专用路径，这里不处理
        return false, _M.ERR_WRITE
    end
    if not writer then
        log.error("store", "未注册写入实现，无法写入", "tag=" .. tostring(tag))
        return false, _M.ERR_NO_WRITER
    end

    local ok, err = writer(reg, val)
    if not ok then
        return false, err or _M.ERR_WRITE
    end

    -- 写成功后同步缓存，保证从站/MQTT 立即读到新值
    _M.write_by_a(dev_id, reg.s_addr, val, 0)
    return true
end

-- ============================================================
-- 调试/上报用：按点位聚合当前所有缓存值
-- ============================================================
function _M.get_point_values()
    local result = {}
    local seen = {}

    for _, reg in ipairs(expanded_regs) do
        if reg.group_offset == 0 then
            local key = reg.dev_id .. ":" .. reg.base_n_addr
            if not seen[key] then
                seen[key] = true

                local values = {}
                local errcode = 0
                local ts = 0
                local dev_cache = cache_a[reg.dev_id] or {}
                for i = 0, (reg.reg_count or 1) - 1 do
                    local slot = dev_cache[reg.base_s_addr + i]
                    if slot then
                        values[#values + 1] = slot.data
                        if i == 0 then ts = slot.ts or 0 end
                        if errcode == 0 and slot.errcode and slot.errcode ~= 0 then
                            errcode = slot.errcode
                        end
                    else
                        values[#values + 1] = nil
                    end
                end

                result[#result + 1] = {
                    tag          = reg.tag,
                    dev_id       = reg.dev_id,
                    reg_type     = reg.reg_type,
                    reg_count    = reg.reg_count or 1,
                    data_type    = reg.data_type,
                    scale_factor = reg.scale_factor,
                    bits         = reg.bits,
                    values       = values,
                    errcode      = errcode,
                    ts           = ts,
                }
            end
        end
    end

    return result
end

return _M

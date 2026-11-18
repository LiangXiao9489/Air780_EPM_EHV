--[[
@module  do_write
@summary EHV 的写入实现：把点位写落到 DO 通道（仅 EHV 加载）
@version 1.0
@date    2026.11.18
@usage
注册方式：
  store.set_writer(require("do_write").write)

与 EPM 的 write_through 是同一接口：
  write(reg, value) -> true / false

成功后由 store.set_by_tag 统一回写缓存与 errcode，
本模块不重复写 store。
]]

local do_mod = require "do"

local _M = {}

function _M.write(reg, value)
    local ch = reg.ch
    if not ch then
        log.warn("do_write", "点位没有 ch 字段，无法落到 DO",
                 "tag=" .. tostring(reg.tag))
        return false
    end

    if not do_mod.set(ch, value) then
        log.warn("do_write", "DO 写入失败", "tag=" .. tostring(reg.tag), "ch=" .. ch)
        return false
    end

    log.info("do_write", "写入成功",
             "tag=" .. tostring(reg.tag), "ch=" .. ch, "value=" .. tostring(value))
    return true
end

return _M

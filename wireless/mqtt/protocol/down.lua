--[[
@module  down
@summary 下行指令分发（块7 临时占位，块8 替换为完整实现）
@version 0.1
@usage
本文件当前只保证 receiver / basic 链路可以正常加载与运行，
不做任何协议解析。块8 会整体替换为完整的 set/call/cfg 分发实现。
]]

local down = {}

function down.dispatch(topic, text)
    log.warn("down", "协议层尚未移植，下行被忽略", "topic=" .. tostring(topic))
    return false
end

return down

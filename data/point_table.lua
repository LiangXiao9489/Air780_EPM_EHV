--[[
@module  point_table
@summary 统一点表（EPM / EHV 共用同一套 schema，按板型选择数据）
@version 2.1
@date    2026.11.19
@usage
一张表驱动三端：
  1. MQTT 上行/下行 → tag
  2. Modbus 从站     → n_addr（PDU 地址）+ reg_type
  3. 下行数据源      → EPM 用 s_addr 轮询从机；EHV 用 ch 操作本机 GPIO

字段说明：
  num           序号（仅可读性用）
  tag           MQTT JSON key，两板唯一
  s_addr        下行侧地址（点表 A）
                  EPM：从机寄存器地址，主站轮询用
                  EHV：与 n_addr 相同（100 转 100）
  n_addr        上行侧地址（点表 B），从站应答上位机用
  reg_type      1=线圈 2=离散输入 3=保持寄存器 4=输入寄存器
  reg_count     占用寄存器个数，默认 1；线圈/离散只允许 1
  rw            "r" 只读 / "rw" 读写（reg_type=2/4 强制只读）
  data_type     本地解析用（u16/i16/u32/i32/f32/string/bool）
  scale_factor  原始值 × scale_factor = 实际值
  bits          可选，16 位寄存器内的位定义，仅本地参照
  ch            可选，本机 GPIO 通道号（仅 EHV 的 DI/DO 使用）

硬编码约定：
  EHV 的 Modbus 从站地址 / MQTT 设备 id 固定为 240
  （现场最多 20 多台从机，不会与 1~30 的从机号冲突；
    240 在 Modbus 合法地址 1~247 范围内）

EPM 多套点表：
  一个 EPM 可能接不同型号的从机，点表按设备型号分多份，硬编码在本文件内；
  启动时按参数 point_table_id（1/2，默认 1）选择，修改后重启生效。
    point_table_id = 1  测试用点表（something1 / coilDemo …）
    point_table_id = 2  机组点表（机组状态 / 制冷控制温度 …）
  meta.protocol_version 只作说明符号，代码不读取、也不上报。
]]

local board = require "board"

local TABLES = {}

-- ============================================================
-- EPM 点表库：多台从机共用同一份 regs 模板，按 point_table_id 选择
-- ============================================================
local EPM_TABLES = {}

-- ------------------------------------------------------------
-- 1 号点表：测试用（配合从机模拟器）
-- ------------------------------------------------------------
EPM_TABLES[1] = {
    meta = {
        protocol_version = "EPM_test_1.0.0",   -- 仅说明：测试用点表
        slave_dev = {1},
    },

    regs = {
        { num=1, tag="something1", s_addr=5000, n_addr=6400,
          reg_type=3, reg_count=1, data_type="u16", scale_factor=1, rw="rw"},

        { num=2, tag="coilDemo", s_addr=5100, n_addr=6500,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},

        { num=3, tag="multiInputReg", s_addr=5800, n_addr=7200,
          reg_type=4, reg_count=2, data_type="u32", scale_factor=1, rw="r"},

        { num=4, tag="multiHoldingReg", s_addr=756, n_addr=252,
          reg_type=3, reg_count=4, data_type="u64", scale_factor=1, rw="rw"},

        { num=5, tag="deviceSn", s_addr=123, n_addr=456,
          reg_type=4, reg_count=8, data_type="string", scale_factor=1, rw="r"},

        { num=6, tag="something2", s_addr=5001, n_addr=6401,
          reg_type=3, reg_count=2, data_type="u32", scale_factor=1, rw="rw"},

        { num=7, tag="something3", s_addr=5003, n_addr=6403,
          reg_type=3, reg_count=1, data_type="u16", scale_factor=1, rw="rw"},

        { num=8, tag="coilDemo2", s_addr=5101, n_addr=6501,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},

        { num=9, tag="coilDemo3", s_addr=5102, n_addr=6502,
          reg_type=1, reg_count=1, data_type="bool", scale_factor=1, rw="rw"},

        { num=10, tag="discreteInputA", s_addr=6000, n_addr=7000,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        { num=11, tag="discreteInputB", s_addr=6001, n_addr=7001,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        { num=12, tag="discreteInputC", s_addr=6002, n_addr=7002,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        { num=13, tag="discreteInputD", s_addr=6010, n_addr=7010,
          reg_type=2, reg_count=1, data_type="bool", scale_factor=1, rw="r"},

        { num=14, tag="测试机组状态", s_addr=768, n_addr=1000, reg_type=4,
          reg_count=1, data_type="u16", scale_factor=1, rw="r",
          bits = {
              { bit = 0, tag = "机组待机态" },
              { bit = 1, tag = "机组正在启动中" },
              { bit = 2, tag = "机组运行态" },
              { bit = 3, tag = "机组正在停机中" },
              { bit = 4, tag = "机组严重报警态" },
              { bit = 8, tag = "机组预热" },
              { bit = 9, tag = "机组有故障" },
              { bit = 10, tag = "机组防冻" },
          } },
    },
}

-- ------------------------------------------------------------
-- 2 号点表：邦普热泵定频机
-- ------------------------------------------------------------
EPM_TABLES[2] = {
    meta = {
        protocol_version = "EPM_chiller_1.0.0",   -- 仅说明：机组点表
        slave_dev = {1},
    },

    regs = {
        --机组状态，8bit只读，长度为 [1] 输入寄存器
        { num = 1, tag = "机组状态", s_addr = 768, n_addr = 1000, reg_type = 4, reg_count = 1, data_type = "u16", scale_factor = 1, rw = "r",
          bits = {
              { bit = 0, tag = "机组待机态" }, { bit = 1, tag = "机组正在启动中" }, { bit = 2, tag = "机组运行态" }, { bit = 3, tag = "机组正在停机中" },
              { bit = 4, tag = "机组严重报警态" }, { bit = 8, tag = "机组预热" }, { bit = 9, tag = "机组有故障" }, { bit = 10, tag = "机组防冻" },
          } },
        --制冷控制温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
        { num = 2, tag = "制冷控制温度", s_addr = 6401, n_addr = 1001, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 0.1, rw = "r"},
        --制热控制温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
        { num = 3, tag = "制热控制温度", s_addr = 6402, n_addr = 1003, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 0.1, rw = "r"},
        --环境温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
        { num = 4, tag = "环境温度", s_addr = 6195, n_addr = 1005, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 0.1, rw = "r"},
        --出水温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
        { num = 5, tag = "出水温度", s_addr = 1203, n_addr = 1007, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 0.1, rw = "r"},
        --回水温度, 32位浮点型数据，数据单位：℃，长度为 [2] 输入寄存器
        { num = 6, tag = "回水温度", s_addr = 6197, n_addr = 1009, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 0.1, rw = "r"},
        --设定模式, 16位无符号整型只读，长度为 [1] 输入寄存器
        { num = 7, tag = "设定模式", s_addr = 6400, n_addr = 1011, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 1, rw = "r"},
        --正在除霜压机数量, 16位无符号整型只读，长度为 [1] 输入寄存器
        { num = 8, tag = "正在除霜压机数量", s_addr = 782, n_addr = 1012, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 1, rw = "r"},
        --水流开关运行状态, 1位bool只读，长度为 [1] 离散输入
        { num = 9, tag = "水流开关运行状态", s_addr = 81, n_addr = 1013, reg_type = 2, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "r"},
       --机组累计运行时间, 16位无符号整型只读，长度为 [1] 输入寄存器
        { num = 10, tag = "机组累计运行时间", s_addr = 6178, n_addr = 1014, reg_type = 4, reg_count = 1, data_type = "i16", scale_factor = 1, rw = "r"},
       --通讯故障报警, 1位bool只读，长度为 [1] 离散输入
        { num = 11, tag = "通讯故障报警", s_addr = 1168, n_addr = 1015, reg_type = 2, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "r"},
       --开机命令, 1位bool可读可写，长度为 [1] 线圈
        { num = 12, tag = "开机命令", s_addr = 0, n_addr = 1016, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
        --停机命令, 1位bool可读可写，长度为 [1] 线圈
        { num = 13, tag = "停机命令", s_addr = 1, n_addr = 1017, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
        --复位命令, 1位bool可读可写，长度为 [1] 线圈
        { num = 14, tag = "复位命令", s_addr = 8, n_addr = 1018, reg_type = 1, reg_count = 1, data_type = "bool", scale_factor = 1, rw = "rw"},
        --模块设置, 16位整型可读写，长度为 [1] 保持寄存器
        { num = 15, tag = "模块设置", s_addr = 6433, n_addr = 1019, reg_type = 3, reg_count = 1, data_type = "i16", scale_factor = 1, rw = "rw"},
    },
}

-- ============================================================
-- EHV：本机 4DI + 4DO，单设备，s_addr = n_addr（100 转 100）
-- ============================================================
TABLES.EHV = {
    meta = {
        protocol_version = "EHV_4DI4DO_1.0.0",   -- 仅说明：EHV 本机 IO 点表
        slave_dev = {240},   -- Modbus 从站地址 / MQTT 设备 id，硬编码 240
    },

    regs = {
        -- ===== DI：离散输入（reg_type=2，只读） =====
        { num=1, tag="di_a", s_addr=600, n_addr=600, reg_type=2, reg_count=1,
          data_type="bool", scale_factor=1, rw="r", ch=1 },
        { num=2, tag="di_b", s_addr=601, n_addr=601, reg_type=2, reg_count=1,
          data_type="bool", scale_factor=1, rw="r", ch=2 },
        { num=3, tag="di_c", s_addr=602, n_addr=602, reg_type=2, reg_count=1,
          data_type="bool", scale_factor=1, rw="r", ch=3 },
        { num=4, tag="di_d", s_addr=603, n_addr=603, reg_type=2, reg_count=1,
          data_type="bool", scale_factor=1, rw="r", ch=4 },

        -- ===== DO：线圈（reg_type=1，可读写） =====
        { num=5, tag="do_a", s_addr=800, n_addr=800, reg_type=1, reg_count=1,
          data_type="bool", scale_factor=1, rw="rw", ch=1 },
        { num=6, tag="do_b", s_addr=801, n_addr=801, reg_type=1, reg_count=1,
          data_type="bool", scale_factor=1, rw="rw", ch=2 },
        { num=7, tag="do_c", s_addr=802, n_addr=802, reg_type=1, reg_count=1,
          data_type="bool", scale_factor=1, rw="rw", ch=3 },
        { num=8, tag="do_d", s_addr=803, n_addr=803, reg_type=1, reg_count=1,
          data_type="bool", scale_factor=1, rw="rw", ch=4 },
    },
}

-- ============================================================
-- 按板型返回（EPM 再按 point_table_id 二选一）
-- ============================================================
local pt

if board.is_epm then
    local config = require "config"
    local id = tonumber(config.get("point_table_id")) or 1

    pt = EPM_TABLES[id]
    if not pt then
        log.error("point_table", "点表编号非法，回退 1 号", "point_table_id=" .. tostring(id))
        id = 1
        pt = EPM_TABLES[1]
    end

    log.info("point_table", "点表已选择", "板型=EPM", "编号=" .. id,
             "说明=" .. pt.meta.protocol_version,
             "设备数=" .. #pt.meta.slave_dev, "寄存器模板数=" .. #pt.regs)
else
    pt = TABLES[board.name]
    if not pt then
        log.error("point_table", "未知板型，无点表可用", "board=" .. tostring(board.name))
        return nil
    end

    log.info("point_table", "点表已选择", "板型=" .. board.name,
             "说明=" .. pt.meta.protocol_version,
             "设备数=" .. #pt.meta.slave_dev, "寄存器模板数=" .. #pt.regs)
end

return pt

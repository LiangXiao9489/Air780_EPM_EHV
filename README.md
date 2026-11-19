# Air780_EPM_EHV

LuatOS 工程：EPM（D700Tm / Air780EPM）与 EHV（SW1004V-10 / Air780EHV）**二合一固件**。
上电时用 `rtos.bsp()` 自动识别板型，两块板共用一套代码。

---

## 1. 工程概览

| 项目 | EPM | EHV |
| --- | --- | --- |
| 模组 | Air780EPM | Air780EHV |
| 底板 | D700Tm 系列（3 路 RS485） | SW1004V-10 系列（2 路 RS485 + 4DI + 4DO） |
| 角色 | **协议转换网关** — 主站轮询 485 从机 + 从站应答上位机 | **Modbus 从站 + 本地 IO** — 从站应答上位机，无协议转换 |
| 固件版本 | `VERSION = "1.0"`（main.lua，调试期固定） | 同左（共用一套固件） |
| 构建 | LuatIDE 下载 EPM 固件到 EPM 板、下载 EHV 固件到 EHV 板；**打包脚本相同**，靠 `rtos.bsp()` 在运行时识别 |

### 为什么二合一

两套代码原本独立维护，板型差异点梳理后发现：
- 数据层（store / 点表 / 配置）完全共用；
- MQTT 链路与上行协议（up / ack / report）完全共用，**数据源不同但接口统一**（`store.get_point_values()`）；
- MQTT 下行协议（down / cfg / OTA）也能共用，靠 `board.profile` 把板型差异收敛到一处。

合二为一后避免了协议升级时两边不同步。

---

## 2. 目录结构与文件职责

```
Air780_EPM_EHV/
├── main.lua                       工程入口；按块注释了 1~9 移植进度
│
├── board/
│   ├── board.lua                  板型识别（rtos.bsp() 子串匹配）→ 导出 name/is_epm/is_ehv/is_known/profile
│   ├── profile_epm.lua            EPM 硬件资源表（端口/引脚/写使能 key/本地 IO 能力）
│   └── profile_ehv.lua            EHV 硬件资源表
│
├── data/
│   ├── config.lua                 运行时参数（/gateway_cfg.json 落盘）；默认值按 profile 裁剪
│   ├── point_table.lua            点表：EPM 多套（point_table_id 1/2 选择）/ EHV 单套，由 profile 决定
│   └── store.lua                  统一缓存层：地址双映射 / set_by_tag / writer 注册 / get_point_values
│
├── device/
│   ├── ext_wdt.lua                外部看门狗（GPIO28）
│   └── led_blink.lua              NET LED（GPIO27），500ms 周期
│
├── modbus/
│   ├── core.lua                   Modbus RTU 编解码（功能码 01/02/03/04/05/06/0F/10 + 异常码）
│   ├── hardware.lua               动态初始化启用的端口；DIR 脚翻转与 rs485_delay 延时
│   ├── uart_lock.lua              u1 主站互斥锁（问答口，避免主/从同时发言）
│   ├── master.lua                 EPM 主站轮询 task（遍历点表按轮询间隔依次下发）
│   ├── write_through.lua          485 写穿透：store.set_writer 注册项（EPM 用）
│   └── slave.lua                  从站应答 task（两板共用，走 u2）
│
├── local_io/                      ← EPM 不加载本目录
│   ├── di.lua                     4 路 DI 采集（GPIO36/37/38/16），显式返回 0/1 避免 Lua 陷阱
│   ├── do.lua                     4 路 DO 输出（GPIO21/3/35/34），GPIO22 EN 常高
│   ├── do_write.lua               store.set_writer 注册项（EHV 用）
│   └── sampler.lua                本地采样 task，周期 local_sample_ms（默认 500ms）
│
└── wireless/
    ├── ota.lua                    HTTP 下载 → CRC32 校验 → fota 写入；两段 ack +  busy 拦截
    ├── 4g/
    │   ├── net_4g.lua             SIM 卡检测、设 DNS、IP_READY 发布
    │   ├── sntp.lua               NTP 对时；TIME_VALID_MIN=1600000000 时间门限
    │   └── net_watchdog.lua       5 分钟无网络喂狗重启（main.lua 默认注释掉，需要时放开）
    └── mqtt/
        ├── basic.lua              MQTT 连接调度；CLIENT_ID="YEDtest_<板型>_mqtt_<UID>"
        ├── sender.lua              上行队列（MAX_QUEUE=64 / MAX_RETRY=3 / 1s 重试）
        ├── receiver.lua           下行入队（MAX_QUEUE=32）；失败不丢弃，只 warn
        └── protocol/
            ├── topics.lua         唯一的 topic 字符串来源（SN=mcu.unique_id():toHex()）
            ├── up.lua             顶层 JSON 拼装（带 ti / 不带 ti 两种）
            ├── ack.lua            setack / indexRealAck / hisAck / ctrAck 统一结构
            ├── report.lua         real 整点全量 / change 变化 / realIndex 快速（DI 变化唤醒）
            ├── down.lua           下行分发：/s call+set、/scr indexReal、/s2 call+set+ota
            └── cfg.lua            网关参数模型：白名单/校验/落盘/change 回显（按 profile 裁剪）

```

---

## 3. 板型差异一览

### 3.1 硬件资源

| 资源 | EPM (D700Tm) | EHV (SW1004V-10) |
| --- | --- | --- |
| 板型识别 | `rtos.bsp()` 含 `EPM` | `rtos.bsp()` 含 `EHV` |
| LED | GPIO27 | GPIO27 |
| 外部 WDT | GPIO28 | GPIO28 |
| AD 参考 | ADC0（0~90V，scale=273300/3300） | ADC2（0~36V，scale=103300/3300） |
| **485 u1** | **启用**（从机问答口）：EN=GPIO25，8N2，clear_rx_on_send=true，有 uart_lock | **禁用**（物理存在但不初始化，避免与 u2 抢 GPIO25） |
| **485 u2** | **启用**（从站口）：无 EN（硬件自动翻转），8N1，silent_timeout=true | **启用**（从站口）：EN=GPIO25，8N1，silent_timeout=true |
| 485 u3 | 禁用（硬件有但不用） | 无 |
| DI | 无 | GPIO36 / 37 / 38 / 16（DI1~DI4） |
| DO | 无 | GPIO21 / 3 / 35 / 34（DO1~DO4），EN=GPIO22 **常高**（非脉冲锁存） |

### 3.2 运行时差异（由 profile 自动决定）

| 项目 | EPM | EHV |
| --- | --- | --- |
| MQTT 设备 id | 点表 meta.slave_dev（当前 `1`） | **硬编码为 240**（0xF0 = Modbus 合法从站地址上限） |
| Modbus 从站地址 | `1`（从机号） | `240`，**只接受 240 与广播 0**（白名单在 slave.lua 内） |
| 采数据源 | `master.lua` 主站轮询 u1 | `sampler.lua` 本地采样 DI/DO |
| store writer | `write_through.write`（485 写穿透） | `do_write.write`（直接驱动 DO） |
| 本地采样 | 无 | 500ms 周期（`local_sample_ms`） |
| set 写使能参数 | `write_through_en`（控制 485 写穿透） | `mqtt_do_en`（控制 MQTT 对 DO 的远程写入） |
| `/s2` 可用串口参数 | `u1_*` + `u2_*` | **只有 `u2_*`**（`u1_*` set 返回 not_found） |
| `/s2` 额外参数 | 无 | `local_sample_ms` |
| report 数据源 | master 轮询填充的 cache | sampler 填充的 cache |

---

## 4. Modbus 约定

### 4.1 两板共用的 Modbus RTU 参数

- 从站应答 **统一走 u2**（EPM 从站口 / EHV 唯一启用的口）；
- EPM 主站轮询走 u1；
- 当前默认 9600 / 8 / N / 2（EPM u1 是 2 停止位、u2 是 1 停止位），可通过 `/s2/${SN}` 修改 uX_* 参数落盘重启生效。

### 4.2 点表 schema

```lua
{
    num        = 1,                -- 点位序号（用于日志）
    tag        = "something1",     -- MQTT 上报 / 下行 set 的 tag（唯一）
    dev        = 1,                -- 设备 id（EPM=从机号，EHV=240 写死）
    s_addr     = 6400,             -- 从机寄存器地址
    n_addr     = 6400,             -- 本机从站映射地址（EHV：s_addr = n_addr）
    reg_type   = 3,                -- 1=线圈(0x)  2=离散量输入(1x)  3=保持寄存器(4x)  4=输入寄存器(3x)
    reg_count  = 1,                -- 寄存器数量
    rw         = "rw",              -- "r"只读 / "rw"可写
    data_type  = "bool",           -- "bool" / "uint16" / "int16" / ...
    scale_factor = 1,              -- 缩放系数
    ch         = 4,                -- EHV 本地 IO 通道号（DI/DO 用；EPM 无意义）
}
```

EPM 可能接不同型号的从机，点表按型号硬编码多份，由参数 `point_table_id` 选择：

| point_table_id | 点表 | meta.protocol_version |
| --- | --- | --- |
| 1（默认） | 测试点表 | `EPM_test_1.0.0`（something1 / coilDemo …） |
| 2 | 机组点表 | `EPM_chiller_1.0.0`（机组状态 / 制冷控制温度 …） |

修改 `point_table_id` 后需重启生效；`meta.protocol_version` 仅作说明，代码不读取、不上报。EHV 只有一套点表，无此参数。

### 4.3 功能码支持

| 功能码 | 名称 | 从站应答 | 主站下发 |
| --- | --- | --- | --- |
| 0x01 | 读线圈 | ✅ | ✅ |
| 0x02 | 读离散量输入 | ✅ | ✅ |
| 0x03 | 读保持寄存器 | ✅ | ✅ |
| 0x04 | 读输入寄存器 | ✅ | ✅ |
| 0x05 | 写单线圈 | ✅ | ✅ |
| 0x06 | 写单寄存器 | ✅ | ✅ |
| 0x0F | 写多线圈 | ✅ | ✅ |
| 0x10 | 写多寄存器 | ✅ | ✅ |

异常码返回：0x01（非法功能）/ 0x02（非法地址）/ 0x04（从站故障）/ 0x08（写失败）/ 0x0B（未启用）。

---

## 5. MQTT 协议

### 5.1 Broker

- 地址：`broker.emqx.io:1883`（部署常量，`wireless/mqtt/basic.lua` 顶部）
- 账密：空（测试环境）
- 协议版本：v3.1.1（LuatOS 内置 mqtt 库）
- 心跳：60s

### 5.2 身份

```lua
SN = mcu.unique_id():toHex()                      -- 例："03230619179356C9"
CLIENT_ID = "YEDtest_" .. board.name .. "_mqtt_" .. SN   -- 例："YEDtest_EPM_mqtt_03230619179356C9"
```

### 5.3 主题

| 方向 | 主题 | 内容 |
| --- | --- | --- |
| 订阅 | `/s/${SN}` | 主业务下行：`call`（查询缓存）、`set`（写入） |
| 订阅 | `/scr/${SN}` | 控制下行：`indexReal`、`his`、`ctr`（his/ctr 暂未实现） |
| 订阅 | `/s2/${SN}` | 网关自身参数：`call`、`set`、`ota` |
| 发布 | `/d/${SN}` | 实时数据：`real` / `change` / `callack` / `setack` / `realIndex` |
| 发布 | `/dcr/${SN}` | 控制应答：`indexRealAck` / `hisAck` / `ctrAck` |
| 发布 | `/d2/${SN}` | 网关参数：`callack` / `setack` / `change` / `otaDownloadAck` / `otaVerifyAck` |

> SN = 16 位大写 hex（UID），所有主题由 `wireless/mqtt/protocol/topics.lua` 统一生成。

### 5.4 通用 payload 结构

**下行（设备收到）**：
```json
{ "t": "<type>", "d": { "<dev_id>": { ...body..., "mid": 1234 } } }
```

**上行（设备发出）**：
```json
{ "t": "<type>", "ti": "2026-11-18 14:30:00", "d": { "<dev_id>": { ... } } }
```

`t` = type，`ti` = 时间字符串（仅数据类有，ack 类不带 ti），`d` = data（顶层始终以设备 id 为 key）。
`mid` = messageId，下行带什么值，上行原样带回。

### 5.5 设备 call（/s/${SN} → /d/${SN}）

下行：
```json
{"t":"call","d":{"240":{"ts":["di_a","di_b"],"mid":201}}}
```
- `ts` 缺省或空数组 → 返回该设备**全部点位**（两板行为一致）；
- 指定但不存在的 tag → 返回 `q:"0", v:"0"`（质量差但不破坏 callack 结构）。

上行：
```json
{"t":"callack","ti":"2026-11-18 14:34:48","d":{"240":{"di_a":{"q":"1","t":"1794983687","v":"1"},"di_b":{"q":"1","t":"1794983687","v":"0"},"mid":201}}}
```

### 5.6 设备 set（/s/${SN} → /d/${SN}）

下行：
```json
{"t":"set","d":{"240":{"do_a":"1","do_b":"0","mid":301}}}
```
上行：
```json
{"t":"setack","d":{"240":{"r":{"success":"all"},"mid":301}}}
```

逐项独立，部分失败时：
```json
{"t":"setack","d":{"240":{"r":{"fail":["di_a"],"not_found":["nope"]},"mid":301}}}
```
- 只读点（EHV 的 DI）→ 进 `fail`；
- 不存在的 tag → 进 `not_found`；
- 写入成功 → **自动补发一条 real**（协议 2.4 注：iot 不会自己改实时数据）。

**EHV 额外规则**：`mqtt_do_en=false` 时整台设备 set 统一回 `fail:["disabled"]`（只影响 MQTT 写入，Modbus 上位机写入不受影响）。

**EPM 额外规则**：`write_through_en=false` 时整台设备 set 统一回 `fail:["disabled"]`。

### 5.7 上报类型（report.lua）

| 类型 | 触发条件 | 间隔 | 内容 |
| --- | --- | --- | --- |
| `real` | 对齐整分钟整点（按 `upload_interval_min`，默认 5）；受 `report_real_enable` 管控，默认关闭 | 5 分钟 | 全部点位，ti 和每个 tag 的 t 都是同一整点 |
| `change` | DI 变化即时唤醒；或按 `change_check_sec`（默认 5s）周期比对快照；受 `report_change_enable` 管控，默认关闭 | 最多 5s（DI 变化 1s 内触发） | 只含本次变化的 tag |
| `realIndex` | `/scr/${SN}` 下发 `indexReal` 指令（服务器控制，不受上述开关影响） | iv 秒（指令指定） | 指定 tag 的快速上报；du 秒后自动停止 |

### 5.8 indexReal（/scr/${SN} → /dcr/${SN} + /d/${SN}）

下行：
```json
{"t":"indexReal","sti":"","du":"60","iv":"5","d":{"240":{"ts":["di_a","di_b"],"mid":401}}}
```
- `ts` 缺省 → 该设备全部 tag；
- `du` 必须在 `0~1800` 秒内，否则回 `indexRealAck fail:["param"]`；
- 收到后立刻回 ack，立刻发一条 realIndex，之后每 iv 秒发一条，du 秒后停止。

---

## 6. 网关自身参数（/s2/${SN}）

### 6.1 模型

把网关当成一台"虚拟设备"，设备 id = 模组 UID（topics.SN）。
payload 结构与设备 call/set 完全相同，只是网关内部改为读写 `config.lua`。

### 6.2 参数白名单（按 profile 自动裁剪）

```
# EPM
u1_baudrate          (requires_reboot)
u1_databits          (requires_reboot)
u1_stopbits          (requires_reboot)
u1_parity            (requires_reboot)
u2_baudrate          (requires_reboot)
u2_databits          (requires_reboot)
u2_stopbits          (requires_reboot)
u2_parity            (requires_reboot)
upload_interval_min
change_check_sec
report_real_enable
report_change_enable
point_table_id       (requires_reboot, 仅 EPM)
write_through_en

# EHV
u2_baudrate          (requires_reboot)
u2_databits          (requires_reboot)
u2_stopbits          (requires_reboot)
u2_parity            (requires_reboot)
upload_interval_min
change_check_sec
report_real_enable
report_change_enable
mqtt_do_en
local_sample_ms      (requires_reboot)
```

> `requires_reboot` 表示修改后需要重启才生效，setack 成功同时 `sys_need_reboot` 状态翻转为 "1"。
> `u1_*` 在 EHV 上不存在（set 返回 `not_found`），因为 profile_ehv 里 u1.enabled=false。

### 6.3 只读状态（call 时额外返回，set 时回 readonly）

`model`（`D700Tm_3RS485` / `SW1004V-10`）、`fw`（`VERSION`）、`sn`、`imei`、`iccid`、`csq`、`ip`、`uptime_s`、`sys_need_reboot`、`sys_last_error`。

### 6.4 动作（sys_action）

set 时可带 `"sys_action": "reboot"` 或 `"sys_action": "factoryReset"`：
- `reboot`：先落盘再重启；
- `factoryReset`：删除 `/gateway_cfg.json` 后重启，恢复代码默认值。

动作不是配置项，**不落盘、不可读**。

### 6.5 set 流程

1. 逐项校验 → setack（先回）；
2. 有变化的 tag 发一条 `t:"change"`（在 `/d2/${SN}` 上，与设备 change 分开）；
3. 如有 sys_action，500ms 后执行（留时间让 setack 发透）。

---

## 7. OTA

### 7.1 触发

发到 `/s2/${SN}`：
```json
{"t":"ota","d":{"<SN>":{"url":"http://host/firmware.bin","crc":"2339340852","size":"51200","mid":501}}}
```
- `crc` 支持十进制 / `0x` 前缀十六进制 / 纯十六进制；
- 任何参数缺失 / 多余 / 非法 → `otaDownloadAck fail:["param"]`；
- 升级中重复下发 → `otaDownloadAck fail:["busy"]`。

### 7.2 流程

1. 空间检查（剩余空间 ≥ 固件 / 0.9）；
2. HTTP GET 下载到 `/air780EpmEhvCombo_upgrade.bin`（以 PROJECT 命名，避免和其它工程冲突）；
3. 如有完整残留文件（size 一致），跳过下载直接 CRC；
4. CRC32 校验（crypto.crc32）。失败则自动重下一次；
5. 下载 + CRC 通过 → 先回 `otaDownloadAck success`，再回 `otaVerifyAck success`；
6. 等 500ms 让两条 ack 发透；
7. `fota.init()` → `fota.file(path)` → `fota.isDone()` → `fota.finish(true)` → 等 2 秒 → `rtos.reboot()`。

### 7.3 错误分类

| 失败环节 | otaDownloadAck r.fail | sys_last_error |
| --- | --- | --- |
| 参数错 | `["param"]` | `ota_param` |
| 升级中重复 | `["busy"]` | `ota_busy` |
| 剩余空间不足 | `["no_space"]` | `ota_no_space` |
| HTTP 下载（含 404/500/超时） | `["download"]` | `ota_http_XXX` / `ota_timeout` |
| 下载后 size 不符 | `["download"]` | `ota_size_mismatch` |
| CRC 校验失败 | — | `ota_crc_mismatch` |
| fota 写入失败 | — | `ota_flash_write` |

> 下载失败 → 只发 otaDownloadAck，不发 otaVerifyAck；CRC 失败 → 先 ack success 再 ack verify fail。

### 7.4 并发保护

升级进行中（busy=true）：
- 再下发 OTA → `fail:["busy"]`；
- 下发 `sys_action: reboot/factoryReset` → cfg.on_set 里拦截，setack `fail:["busy"]`，同时 `sys_last_error="ota_busy"`。

---

## 8. 时间同步

`wireless/4g/sntp.lua` 负责对时：
- IP_READY 后自动触发；
- 对时成功 1 小时后再试一次；
- 对时失败 10 秒后重试；
- **上报有硬门限**：`TIME_VALID_MIN = 1600000000`（≈2020-09-13）。时间未同步前 report 拒绝任何 real/change/realIndex 上报，避免把 2000 年的假时间戳发到 broker；
- **DI 唤醒与 indexReal 同样受时间门限保护**。

---

## 9. 异常处理

| 场景 | 表现 |
| --- | --- |
| broker 断线 | basic.lua 退避重连（5s → 10s → 20s → 30s 封顶），采集/从站继续工作 |
| 下行队列满（32 条） | receiver 不丢弃，只 warn；broker 端负责限流 |
| 上行队列满（64 条） | sender 丢弃 + warn，继续维持采集链路 |
| 485 问答超时（EPM u1） | uart_lock 超时释放，主站继续下一个从机 |
| 从站口 60 秒无请求（EPM u2 / EHV u2） | hardware.lua 把 `silent_timeout` 端口的超时日志降级为 `log.debug` |
| store 初始化失败（点表错） | main.lua 打印错误后跳过采集/从站，只喂狗/闪灯，避免复位循环 |
| 板型未知（rtos.bsp() 不含 EPM/EHV） | main.lua 停止初始化所有硬件，只打印日志（EPM GPIO21/22 在 EHV 上是继电器，不动好过错误动） |
| 下行坏 JSON / 未知 type | 只 warn，不崩；MQTT 不发任何应答 |

---

## 10. 配置持久化

所有 `/s2/${SN}` set 的参数都会落到 `/gateway_cfg.json`。
`config.lua` 在启动时：
1. 先读 /gateway_cfg.json，加载成功 → 与代码默认值合并；
2. 加载失败（首次启动或文件损坏）→ 用代码默认值，并自动落盘一份。

### 首次启动时的默认值

| 参数 | 默认值（EPM / EHV 分别按 profile 裁剪） |
| --- | --- |
| uX_baudrate | 9600 |
| uX_databits | 8 |
| uX_stopbits | 按 profile（EPM u1=2 / 其它=1） |
| uX_parity | N |
| upload_interval_min | 5 |
| change_check_sec | 5 |
| report_real_enable | false（关闭定时 real 主动上报） |
| report_change_enable | false（关闭 change 主动上报） |
| point_table_id | 1（仅 EPM；1=测试点表 2=机组点表） |
| write_through_en / mqtt_do_en | true |
| local_sample_ms | 500（仅 EHV） |

### 复位后生效的参数

串口波特率/数据位/停止位/校验位、`local_sample_ms` 以及 EPM 的 `point_table_id` 修改后需重启才生效（`sys_need_reboot="1"`）。

---

## 11. Lua 陷阱与已知坑（踩过的）

| 陷阱 | 现象 | 解决 |
| --- | --- | --- |
| `gpio.get()` 返回 0 或 1，而 Lua 中 `0 == true` | `v and 1 or 0` 永远得 1，DI 全高 | 改成显式 `(v == 0) and 0 or 1` |
| 设备 id 是数字（点表 dev），但 JSON 对象 key 永远是字符串 | JSON `"240"` 查不到 store.regs_by_tag[240] | `norm_dev()` 把字符串 key 转回数字再查 |
| real 整点对齐算好 boundary 后 NTP 校时跳变 | 把 2000 年算好的 boundary 用 2020 年时间戳上报 | 每次循环重新计算 next_boundary，且 `TIME_VALID_MIN` 把门控 |
| CRC32 参数 0xFFFFFFFF 在 32 位 Lua 上溢出 | 转字符串 hex 手动解析，最后 `& 0xFFFFFFFF` | 按位与取低 32 位 |
| require 扁平命名 | 打包后目录扁平化，**文件名必须全局唯一**（`up.lua` / `ack.lua` / `report.lua` / `cfg.lua` 都不允许重名） | 两个 profile 分别命名，其它文件全局唯一 |

---

## 12. 构建与下载

1. 用 LuatOS 工具链打开工程根目录；
2. 对 EPM 板：选择 Air780EPM 固件包，完整下载；
3. 对 EHV 板：选择 Air780EHV 固件包，完整下载；
4. 打包脚本（`platform.ini`）在两个板上完全相同，差异靠运行时 `rtos.bsp()` 识别。

### 开机日志关键行

```
[main] =========== 当前模组:[RDA780EPM] 固件版本 [1.0] ===========
[board] 识别到板型 EPM bsp=RDA780EPM
[board] 端口 u1 uartid=1 en_pin=25 启用=true
...
[mqtt.main] connect success
[sntp] 时间同步成功 2026-11-18 14:10:00
[main] 块8b 完成：下行协议已加载
[main] 启动完成 sys.run()
```

---

## 13. 已移植功能清单（9 块）

| # | 块 | 涉及文件 | 状态 |
| --- | --- | --- | --- |
| 1 | 地基 | board.lua / profile_* / config.lua / ext_wdt.lua / net_led.lua / reset_btn.lua | ✅ |
| 2 | 数据层 | point_table.lua / store.lua | ✅ |
| 3 | Modbus 基础 | core.lua / hardware.lua / uart_lock.lua | ✅ |
| 4 | EPM 采集 | master.lua / write_through.lua | ✅ |
| 5 | 从站应答 | slave.lua | ✅ |
| 6 | EHV 本地 IO | di.lua / do.lua / do_write.lua / sampler.lua | ✅ |
| 7 | 网络 + MQTT 链路 | net_4g.lua / sntp.lua / net_watchdog.lua / basic.lua / sender.lua / receiver.lua | ✅ |
| 8a | 上行协议 | up.lua / ack.lua / report.lua（real/change/realIndex + DI 唤醒） | ✅ |
| 8b | 下行协议 + OTA | down.lua / cfg.lua / ota.lua | ✅ |

### 未实现（原工程也没有）

- `/scr/${SN}` 的 `his` 历史召回、`ctr` 通用控制（目前只打占位日志）；
- `/d/${SN}` 断点续传（UP_RESUME 主题）；
- 自定义上报间隔修改后立即生效（目前 upload_interval_min 修改后重启生效）。

### 当前限制（已知，按需扩展）

- **EPM 只支持单物理从机**：point_table.meta.slave_dev 写死为 `{1}`，所有点位都归到 Modbus 从机地址 1，MQTT 设备 ID 固定为字符串 `"1"`。若现场需接多个不同地址的物理从机（如 slave 1 接温湿度、slave 3 接电表），需在点表 schema 中新增 `slave_addr` 字段，master.lua 按字段分组轮询，write_through.lua 按字段路由到正确从机。MQTT 协议层（`d` 的 key = DEV_ID）无需改动，届时 `d` 的 key 就是物理从机地址字符串；
- **EHV 的 mqtt_do_en 只拦截 MQTT 下行**：Modbus 上位机走 u2 写 DO 不受此开关影响。如需要"什么都不能写 DO"的硬锁死，需新增更狠的开关（如 `do_write_en`）放在 `do_write.lua` 入口处；
- **上报 store 未就绪时不回 setack**：点表解析失败导致 store.init() 返回 false 时，MQTT 下行 set 会直接 return，服务器等超时无响应。现场通过开机日志判断（"store 初始化失败"）；
- **设备数据 set 失败不写 sys_last_error**：只有网关参数写入失败才写 sys_last_error。设备数据写入失败（485 超时、tag 只读、值非法等）只体现在 setack 的 fail/not_found 数组里，服务器需在 setack 里查错。

---

## 14. 原厂支持渠道

- LuatOS 官方社区：https://wiki.luatos.com/
- Air780 模组手册：LuatOS 文档 → Air 系列 → Air780EPM / Air780EHV
- 工程原始两套固件在 `_extra/epm/` 和 `_extra/ehv/` 目录下，该目录已加入 `.gitignore`，不纳入版本管理。

---

## 15. 问题修复记录

### 2026-11-19 串口等帧无总超时导致 u1 锁可能永久占用

- 问题：`modbus/hardware.lua` 的 `port_wait_response` 阶段 2 只判断“总线静默 8ms”作为帧结束条件，没有总超时。总线持续噪声、A/B 浮空或从机连续吐数据时，静默条件永远不成立，函数永不返回，持有 u1 锁的调用方（主站轮询 / 写穿透 / 从站应答）随之永久卡死。由于 `ext_wdt` 是独立任务仍在正常喂狗，外部看门狗不会复位，表现为“设备在线但不再采集、不再应答”的静默故障。
- 修改：阶段 2 增加总超时（复用 `timeout_ms`）。超时后打印 `帧未结束，强制丢弃` 的 warn，清空 `resp_buffer` 并按超时返回 `nil, -1`。
- 副作用：正常从机响应在 1~20ms 内收完，不会触发该上限，行为不变；异常场景下单次事务最多多消耗约一个 `timeout_ms`，随后按超时失败处理，半帧不会被误当成有效数据。
- 预期结果：u1 锁持有时间被封顶，总线异常后主站轮询与写穿透能自行恢复，不再出现永久停摆。

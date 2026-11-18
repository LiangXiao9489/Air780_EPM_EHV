# Air780_EPM_EHV

LuatOS 工程：EPM（D700Tm / Air780EPM）与 EHV（SW1004V-10 / Air780EHV）二合一固件。
上电时用 `rtos.bsp()` 自动识别板型，两板共用一套代码。

## 文件说明

- `main.lua`：工程入口文件。
- `board/`：板型识别与硬件资源表（`profile_epm` / `profile_ehv`）。
- `data/`：配置、点表、缓存（`store`）。
- `device/`：外部看门狗、LED。
- `modbus/`：Modbus 编解码、485 收发、主站轮询、从站应答、写穿透。
- `local_io/`：EHV 本地 DI/DO 驱动与采样（EPM 不加载）。
- `wireless/`：4G、SNTP、MQTT 链路与上下行协议、OTA。
- `_extra/`：原始两套工程参照，该目录及其中的所有文件均不纳入 Git 版本管理。

## 关键约定

### 板型差异

| 项目 | EPM | EHV |
| --- | --- | --- |
| 角色 | 协议转换网关（主站轮询 + 从站应答） | Modbus 从站 + 本地 IO |
| 485 | u1 接从机（EN=GPIO25）、u2 接上位机（无 EN） | u1 不用（EN=GPIO23）、u2 接上位机（EN=GPIO25） |
| 本地 IO | 无 | 4 路 DI / 4 路 DO（DO 的 EN=GPIO22 常高） |
| 采数据源 | master 轮询 u1 从机 | sampler 本地采样 DI/DO |
| 写落地 | 485 写穿透到从机 | 直接驱动 DO |

### 设备 id

- EPM：MQTT 设备 id = 点表 `meta.slave_dev` 里的从机号（当前为 `1`）。
- EHV：MQTT 设备 id 与 Modbus 从站地址**硬编码为 `240`（0xF0）**，点表里 `dev=240`、`s_addr = n_addr`。
  因此 EHV 的 `/s/${SN}` 下行、`/d/${SN}` 上行 payload 中，`d` 的设备 key 都是字符串 `"240"`；
  上位机用 Modbus Poll 等工具访问时，Slave ID 也必须填 `240`（只接受 240 与广播 0）。

### MQTT 主题（SN = 模组 UID）

- 下行订阅：`/s/${SN}`、`/scr/${SN}`、`/s2/${SN}`
- 上行发布：`/d/${SN}`（real / change / callack / setack / realIndex）、`/dcr/${SN}`（indexRealAck 等）、`/d2/${SN}`（网关参数 callack / setack / ota*）

### 参数白名单按板型裁剪

`/s2/${SN}` 的可配置参数由 `board/profile` 生成：只有启用的串口才有 `uX_*`。
EHV 没有 `u1_*`（set 返回 `not_found`），写使能参数名为 `mqtt_do_en`（EPM 为 `write_through_en`），
`local_sample_ms` 仅 EHV 存在。

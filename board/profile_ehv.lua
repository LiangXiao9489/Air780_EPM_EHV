--[[
@module  profile_ehv
@summary EHV（SW1004V-10 系列）硬件资源表
@version 1.0
@date    2026.11.18
@usage
硬件依据（SW1004V-10 系列资源表 / Air780EHV 方案）：
  RS4851        串口1   EN=GPIO23（本固件不使用）
  RS4852        串口2   EN=GPIO25（本固件用作 Modbus 从站）
  NET LED       GPIO27
  Reload 按键   GPIO26
  硬件看门狗    GPIO28（Air153C）
  可控电压输出  GPIO17
  PA 使能       GPIO24
  DI 输入1~4    GPIO36 / 37 / 38 / 16
  DO 输出1~4    GPIO21 / 3 / 35 / 34
  DO 锁存 EN    GPIO22（先拉高 → 设输出 → 拉低锁存）
  供电电压采集  ADC2（0~36V，电压 = ADC * 103300 / 3300）

port 字段说明：
  uartid            串口 id
  enabled           false = 物理存在但本固件不初始化
  en_pin            RS485 方向脚，nil = 硬件自动翻转
  en_level          方向脚有效电平（沿用原工程实测值）
  rs485_delay       发送→接收切换延时（微秒）
  clear_rx_on_send  发送前是否清接收缓存（问答口 true / 从站口 false）
]]

return {
    name = "EHV",

    -- 设备支撑
    led_pin      = 27,
    wdt_pin      = 28,
    reload_pin   = 26,

    -- 电压采集
    adc_ch       = 2,
    adc_scale    = 103300 / 3300,

    -- 能力开关
    has_local_io = true,
    di_pins      = { 36, 37, 38, 16 },   -- DI1 ~ DI4
    do_pins      = { 21, 3, 35, 34 },    -- DO1 ~ DO4
    do_en_pin    = 22,                   -- 输出锁存 EN

    -- 写使能参数名：保持平台侧既有参数名不变
    write_enable_key = "mqtt_do_en",

    -- 本地采样周期（毫秒），块 6 使用
    local_sample_ms = 500,

    ports = {
        u1 = {
            -- 物理存在（RS4851 / EN=GPIO23），本固件不使用，避免与 u2 抢 GPIO25
            uartid = 1, enabled = false,
            en_pin = 23, en_level = 0, rs485_delay = 20000,
            baudrate = 9600, databits = 8, stopbits = 1, parity = "N",
            clear_rx_on_send = false,
        },
        u2 = {
            uartid = 2, enabled = true,
            en_pin = 25, en_level = 0, rs485_delay = 20000,
            baudrate = 9600, databits = 8, stopbits = 1, parity = "N",
            clear_rx_on_send = false,
            silent_timeout = true,   -- 从站口空闲无请求是常态，超时不告警
        },
    },
}

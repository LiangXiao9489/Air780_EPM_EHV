--[[
@module  profile_epm
@summary EPM（D700Tm 系列）硬件资源表
@version 1.0
@date    2026.11.18
@usage
硬件依据（D700Tm 系列资源表 / Air780EPM 方案）：
  RS4851        串口1   EN=GPIO25
  RS4852        串口2   无 EN（硬件自动翻转）
  RS4853        串口3   无 EN（本固件不使用）
  NET LED       GPIO27
  Reload 按键   GPIO30
  硬件看门狗    GPIO28（Air153C）
  可控电压输出  GPIO21
  输出使能      GPIO22
  供电电压采集  ADC0（0~90V，电压 = ADC * 273300 / 3300）
  本板无 DI / DO

port 字段说明：
  uartid            串口 id
  enabled           false = 物理存在但本固件不初始化
  en_pin            RS485 方向脚，nil = 硬件自动翻转
  en_level          方向脚有效电平（沿用原工程实测值）
  rs485_delay       发送→接收切换延时（微秒）
  clear_rx_on_send  发送前是否清接收缓存（问答口 true / 从站口 false）
]]

return {
    name = "EPM",

    -- 设备支撑
    led_pin      = 27,
    wdt_pin      = 28,
    reload_pin   = 30,

    -- 电压采集
    adc_ch       = 0,
    adc_scale    = 273300 / 3300,

    -- 能力开关
    has_local_io    = false,
    di_pins         = nil,
    do_pins         = nil,
    do_en_pin       = nil,

    -- 写使能参数名：保持平台侧既有参数名不变
    write_enable_key = "write_through_en",

    -- 本板无本地采样 task
    local_sample_ms = nil,

    ports = {
        u1 = {
            uartid = 1, enabled = true,
            en_pin = 25, en_level = 0, rs485_delay = 20000,
            baudrate = 9600, databits = 8, stopbits = 2, parity = "N",
            clear_rx_on_send = true,
        },
        u2 = {
            uartid = 2, enabled = true,
            en_pin = nil, en_level = 0, rs485_delay = 20000,
            baudrate = 9600, databits = 8, stopbits = 1, parity = "N",
            clear_rx_on_send = false,
            silent_timeout = true,   -- 从站口空闲无请求是常态，超时不告警
        },
        u3 = {
            uartid = 3, enabled = false,
            en_pin = nil, en_level = 0, rs485_delay = 20000,
            baudrate = 9600, databits = 8, stopbits = 1, parity = "N",
            clear_rx_on_send = false,
        },
    },
}

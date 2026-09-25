# 2.7 英寸电子纸状态屏

已在 Raspberry Pi 3B+、OpenWrt 25.12.5 和 **Waveshare 2.7inch e-Paper HAT V2 黑白版**上实测。屏幕有总览、蜂窝、VPN/流量、电源、系统五页，每页以两列展示 10 项数据；顶栏左侧是设备名、中间是日期时间与页码、右侧是 UPS 估算电量与充放电状态，首页放大延迟/丢包与 RSRP，底部有独立的按键提示条。四个实体按键用于翻页和进入本地设置菜单。它不是 LuCI 网页的镜像，不显示短信正文、电话号码、密钥等私密内容。

硬件规格与引脚以 [Waveshare 官方手册](https://www.waveshare.com/wiki/2.7inch_e-Paper_HAT_Manual) 和 [官方驱动仓库](https://github.com/waveshareteam/e-Paper) 为依据。V2 画面为 264×176；HAT 使用 SPI0 CE0，屏幕控制脚采用 BCM 编号：RST 17、DC 25、BUSY 24、PWR 18。四键依次使用 BCM 5、6、13、19。当前 EP-0136 UPS 走 I²C，两者已在同一台树莓派上同时运行。其他屏幕版本或带不同转接板的产品需重新核对引脚和驱动命令。

| 按键 | 状态页 | 设置菜单 |
| --- | --- | --- |
| KEY1 | 回首页；在首页按下可重新读取状态 | 返回；有待确认的网络设置时等待自动回退 |
| KEY2 | 上一页 | 上一项 |
| KEY3 | 下一页 | 下一项 |
| KEY4 | 进入设置 | 选择；有影响网络的操作需在确认画面长按约 2 秒 |

设置菜单提供网络检查、更新蜂窝状态、VPN 重连、启动/暂停 VPN、VPN 开机自启、Wi-Fi 2.4/5 GHz 切换、有线口 LAN/WAN 切换，以及屏幕 3/5/10 分钟刷新周期。网络检查与状态更新直接执行；VPN 和网络设置需在确认画面长按 KEY4。Wi-Fi 和有线口复用原管理页的 **125 秒限时回退**，切换后先确认目标状态和连接，再在屏幕长按 KEY4 保留；不确认会由原有服务自动回退。实体按键是设备本地管理入口，能改变网络配置，请将路由器放在仅可信人员能接触的位置。热点名称、密码、VPN 密钥等自由文本仍需在 LuCI 页面设置。

V2 的四级灰阶只用于浅色分隔与辅助标记；文字像素收敛为纯黑或纯白，底部操作提示用纯黑底白字，避免小字被点状灰底或灰色边缘淹没。使用的 Blinker SemiBold 字体及 SIL OFL 许可随源码提供。顶栏 `CHARGING`/`DISCHARGE` 依据 UPS 电池电流正负判断，接近零电流为 `IDLE`；传感器不可用时仅显示外部输入或电池供电，**不推断正在充电**。电流与电量均未经外部校准。翻页在条件允许时使用快刷，设置光标移动使用小区域局刷，累计最多三次快速/局部刷新后先做全刷，返回首页也进行完整刷新。屏幕闲置约 18 秒进入休眠；唤醒后首次更新会全刷。不操作时默认每 180 秒读取一次状态并用灰阶全刷。该频率遵循 [厂商手册](https://www.waveshare.com/wiki/2.7inch_e-Paper_HAT_Manual)对常规刷新间隔的建议。电子纸刷新需要时间，刷新期间的瞬时按键可能不会记录；画面不会像 HDMI 一样逐秒变化。无法取得或已过期的状态显示 `--`，网卡计数器重置后速率重新采样。UPS 百分比是未外部校准的估算值，速度是两次采样间的接口平均吞吐，不是运营商账单。

## 增量安装

先保证原有 Wi-Fi/网线管理入口可用。断电后把 HAT 接到树莓派 40 针排针，再开机；不要通电插拔。OpenWrt 官方软件源安装以下软件：

```sh
apk add python3 python3-gpiod python3-pillow kmod-spi-dev
```

保留原有 `/boot/config.txt`，追加 `dtparam=spi=on`，只需添加一次，然后重启。重启后确认 `/dev/spidev0.0` 存在，也确认原有 I²C/UPS、热点、WAN 和 VPN 都已恢复。把仓库中的 `kk-car-ui/root/etc/kk-car/epaper.py` 和 `epaper_lut.py` 放入设备 `/etc/kk-car/`，将 `fonts/Blinker-SemiBold.ttf` 放入设备 `/etc/kk-car/fonts/`，把 `kk-car-ui/root/etc/init.d/kk-car-epaper` 放入设备 `/etc/init.d/`；主程序与服务文件设为可执行，然后：

```sh
/etc/init.d/kk-car-epaper enable
/etc/init.d/kk-car-epaper start
cat /tmp/kk-car-epaper-status.json
```

`state` 为 `ok` 表示最近一次屏幕写入完成；`page` 为 1–5，`refresh_mode` 可为 `gray`、`full`、`fast` 或 `partial`，`key_counts` 记录本次服务启动以来四键触发次数。再到实体屏幕查看内容并逐个按键，不能只以服务启动成功代替屏幕验收。程序在显示时通过 `ubus` 读取现有 KK-Car 和 UPS 状态；执行设置时复用现有的 `kkcar` 操作接口。把 `/boot/config.txt`、程序、字体、服务文件、init 启动链接，以及可选的 `/etc/kk-car/private/epaper-settings.json` 纳入设备升级保留清单；系统升级后如软件包丢失，还需重新安装依赖。若字体文件意外缺失，程序会退回 Pillow 默认字体，但小字可能再次难辨。

维护时可用 `/usr/bin/python3 /etc/kk-car/epaper.py --preview /tmp/epaper-preview.png --page 1` 仅生成预览图，不占用屏幕 GPIO。`--once` 会真正写一帧；运行前先停止常驻服务，否则 GPIO 独占会导致冲突。退出后再启动服务。`/tmp/kk-car-epaper-status.json` 是运行时文件，重启后重新生成，不应当作历史记录。

## 故障与回退

- `/dev/spidev0.0` 不存在：检查 `kmod-spi-dev`、`dtparam=spi=on` 和重启是否完成。
- 状态为 `error` 或画面不变：查看设备日志，确认是 V2 黑白版、HAT 完全插入、SPI 与 GPIO 没被其他程序占用；断电后才重新插拔 HAT。
- 需要回退：执行 `/etc/init.d/kk-car-epaper stop` 和 `disable`；如需关闭 SPI，先保存当前启动配置，再删除本次追加的 `dtparam=spi=on` 并重启。不要覆盖原有 HDMI、I²C、UPS 或网络配置。

此次实机已验证屏幕出图、四个按键翻页、服务开机启用后运行，重启后 WAN、VPN、热点和 UPS 正常。长期车载震动、温度与反复断电后的寿命尚未测试。

# 2.7 英寸电子纸状态屏

已在 Raspberry Pi 3B+、OpenWrt 25.12.5 和 **Waveshare 2.7inch e-Paper HAT V2 黑白版**上实测。屏幕显示车载网络的只读摘要，四个实体按键能切换页面。它不是 LuCI 网页的镜像，不接收或显示短信正文、电话号码、密钥等私密内容。

硬件规格与引脚以 [Waveshare 官方手册](https://www.waveshare.com/wiki/2.7inch_e-Paper_HAT_Manual) 和 [官方驱动仓库](https://github.com/waveshareteam/e-Paper) 为依据。V2 画面为 264×176；HAT 使用 SPI0 CE0，屏幕控制脚采用 BCM 编号：RST 17、DC 25、BUSY 24、PWR 18。四键依次使用 BCM 5、6、13、19。当前 EP-0136 UPS 走 I²C，两者已在同一台树莓派上同时运行。其他屏幕版本或带不同转接板的产品需重新核对引脚和驱动命令。

| 按键 | 页面 | 显示内容 |
| --- | --- | --- |
| KEY1 | OVERVIEW | WAN/VPN、延迟与丢包、蜂窝信号、UPS 电量与输出、Wi-Fi 客户端 |
| KEY2 | CELLULAR | 网络制式、频段、RSRP/RSRQ/SINR/RSSI |
| KEY3 | VPN / DATA | VPN 状态、延迟与丢包、按网卡计数器计算的上下行速率 |
| KEY4 | UPS / SYSTEM | 外部/电池供电、估算电量、输出电压、温度、树莓派供电状态 |

按键切页后立即刷新；不操作时每 120 秒刷新一次。电子纸全屏刷新需要数秒，刷新期间的瞬时按键可能不会记录；画面不会像 HDMI 一样逐秒变化。无法取得或已过期的状态显示 `--`，网卡计数器重置后速率重新采样。UPS 百分比是未外部校准的估算值，速率是路由器接口吞吐，不是运营商账单。

## 增量安装

先保证原有 Wi-Fi/网线管理入口可用。断电后把 HAT 接到树莓派 40 针排针，再开机；不要通电插拔。OpenWrt 官方软件源安装以下软件：

```sh
apk add python3 python3-gpiod python3-pillow kmod-spi-dev
```

保留原有 `/boot/config.txt`，追加 `dtparam=spi=on`，只需添加一次，然后重启。重启后确认 `/dev/spidev0.0` 存在，也确认原有 I²C/UPS、热点、WAN 和 VPN 都已恢复。部署仓库中的 `kk-car-ui/root/etc/kk-car/epaper.py` 到设备 `/etc/kk-car/epaper.py`，`kk-car-ui/root/etc/init.d/kk-car-epaper` 到设备 `/etc/init.d/kk-car-epaper`，两个文件设为可执行，然后：

```sh
/etc/init.d/kk-car-epaper enable
/etc/init.d/kk-car-epaper start
cat /tmp/kk-car-epaper-status.json
```

`state` 为 `ok` 表示最近一次屏幕写入完成；`page` 为 1–4，`key_counts` 记录本次服务启动以来四键触发次数。再到实体屏幕查看内容并逐个按键，不能只以服务启动成功代替屏幕验收。程序在显示时通过 `ubus` 读取现有 KK-Car 和 UPS 状态，不需要改动网络、DHCP、VPN 或 UPS 设置。可以把 `/boot/config.txt`、两个程序文件和 init 启动链接纳入设备自己的升级保留清单；系统升级后如软件包丢失，还需重新安装依赖。

维护时可用 `/usr/bin/python3 /etc/kk-car/epaper.py --preview /tmp/epaper-preview.png` 仅生成预览图，不占用屏幕 GPIO。`--once` 会真正写一帧；运行前先停止常驻服务，否则 GPIO 独占会导致冲突。退出后再启动服务。`/tmp/kk-car-epaper-status.json` 是运行时文件，重启后重新生成，不应当作历史记录。

## 故障与回退

- `/dev/spidev0.0` 不存在：检查 `kmod-spi-dev`、`dtparam=spi=on` 和重启是否完成。
- 状态为 `error` 或画面不变：查看设备日志，确认是 V2 黑白版、HAT 完全插入、SPI 与 GPIO 没被其他程序占用；断电后才重新插拔 HAT。
- 需要回退：执行 `/etc/init.d/kk-car-epaper stop` 和 `disable`；如需关闭 SPI，先保存当前启动配置，再删除本次追加的 `dtparam=spi=on` 并重启。不要覆盖原有 HDMI、I²C、UPS 或网络配置。

此次实机已验证屏幕出图、四个按键翻页、服务开机启用后运行，重启后 WAN、VPN、热点和 UPS 正常。长期车载震动、温度与反复断电后的寿命尚未测试。

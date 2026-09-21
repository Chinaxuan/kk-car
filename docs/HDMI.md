# HDMI 中文状态屏

树莓派独立在 HDMI framebuffer 绘制一屏中文网络数据，沿用管理页的深色配色和指标分类。它是只读状态屏，不安装浏览器，不依赖 Mac 连续截图，也不提供点击配置功能。

## 内容与数据

- 顶部显示当前出口、VPN、热点频段/信道、运行时长和时钟。
- 六项关键读数：下载、上传、VPN 延迟、本轮丢包、LTE RSRP、CPU 使用率。
- 双趋势图：上下行速率，以及共用时间轴的 VPN 延迟/蜂窝信号。左右轴分别为 ms、dBm，颜色沿用管理页面。
- 四组 32 项详情：系统/CPU、出口/接口、VPN/IPsec、蜂窝/F30A Pro。
- 底部显示热点、已确认在线的无线设备内网地址、上次六项网络检查结果和本地/VPN 管理地址。

复用现有 `kkcar.status`。不显示 VPN 服务器公网 IP、密码、Webhook 或客户端 MAC，不执行网络切换、VPN 重启或新的外部探测。网络检查为空时显示“未检测”，超过 5 分钟标为旧结果；地区信号不保证账号可用。

正常每约 5 秒刷新，首帧需初始化本地字形缓存。首次 CPU/速率显示“未知”，取得第二次计数后才显示；出口变化或计数器归零时丢弃该轮速率。VPN Ping 过期 25 秒、蜂窝缓存过期 75 秒后不继续显示旧的实时读数。

图表保留本次显示进程启动后的最多 120 个样本，正常约 10 分钟；采集变慢时实际跨度会增加。它不加载管理页面的 1 小时/1 天/30 天历史，重启显示服务会清空屏幕图表。内存占用按 MemAvailable 计算，缺少时才回退 MemFree，未知不显示成 100%。累计字节不是运营商套餐账单，累计错误也不是当前丢包率。

## 支持与字体

支持 Pi 3B+ 的 legacy `BCM2708 FB`、32 位 BGRA、零偏移，启动参数需含 `bcm2708_fb.fbswap=1`。布局按 1920×1080 设计，在 1280×720 下可等比缩小；1080p 显示更多清晰像素，不只是放大原版八项状态卡。

中文使用本地 Noto Sans CJK SC 的位图子集，约 0.6 MB，字体许可位于 `hdmi-font.LICENSE`。路由器不需要 Pillow 或整套字体。界面用到的汉字已包含；未包含的动态字符会显示 `?`，设备列表使用内网地址，避免未知设备名影响排版。

开发机可用 Pillow 和官方字体重新生成：

```sh
python3 kk-car-ui/tools/build-hdmi-font.py NotoSansCJKsc-Regular.otf kk-car-ui/root/etc/kk-car/hdmi-font.json
```

字体来自 [Noto CJK 官方仓库](https://github.com/notofonts/noto-cjk)，按 SIL OFL 1.1 保留版权和许可证。本项目没有分发完整字体或把字体作为独立商品。

不支持 KMS/DRM、其他树莓派型号或 SPI 墨水屏，不能套用这些显示设置。

## 增量安装

先保证本地或 VPN 管理可靠，私密备份原 `hdmi.uc` 和启动配置。需已有 `ucode`、fs/ubus 模块、`vcgencmd`、KK-Car 主程序。上传下列文件到对应路径：

```text
/etc/kk-car/hdmi.uc
/etc/kk-car/hdmi-font.json
/etc/kk-car/hdmi-font.LICENSE
/etc/init.d/kk-car-hdmi
```

不要漏传字体。前三项权限 0644，init 服务 0755。先生成预览，再只重启显示服务：

```sh
ucode -c -o /tmp/kk-hdmi-check.ucb /etc/kk-car/hdmi.uc
ucode /etc/kk-car/hdmi.uc --simulate --preview-1080 --frames=3
cat /tmp/kk-car-hdmi-test-status.json
/etc/init.d/kk-car-hdmi restart
/etc/init.d/kk-car-hdmi enable
```

`--simulate` 只写 `/tmp/kk-car-hdmi-test.raw`，不覆盖显示器；`--preview-1080` 只允许与模拟一起使用，输出 1920×1080 BGRA，stride 7680。`--frames=N` 限定模拟运行 1–120 帧后自动退出，`--once` 生成一帧。模拟诊断和实时诊断文件分离。

## 设置真实 1080p 输出

先读取显示器 EDID 并确认支持 CEA 16 / 1080p60。Pi 的 legacy 配置参考 [Raspberry Pi 官方说明](https://www.raspberrypi.com/documentation/computers/legacy_config_txt.html)。在现有 `/boot/config.txt` 的自定义块中修改这些项，保留 `include distroconfig.txt` 和其他原有参数：

```ini
[all]
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
hdmi_drive=2
disable_overscan=1
framebuffer_width=1920
framebuffer_height=1080
```

当前设备的模式切换采用启动参数，必须重启才能生效。重启会中断热点、转发与 VPN，安排可恢复的维护时间；不要为显示调整重置网络配置。VPN 服务端可能重新分配车端地址，恢复连接时应检查当前地址。

回退：通过 SSH 或本地键盘恢复维护前的启动配置，或将 mode/width/height 改回 4/1280/720，再重启。只回退显示内容时恢复原 `hdmi.uc` 并重启 `kk-car-hdmi` 即可，不用重启 network。

## 验证、退出与备份

```sh
cat /sys/class/graphics/fb0/virtual_size
cat /tmp/kk-car-hdmi-status.json
/etc/init.d/kk-car-hdmi status
```

检查实际分辨率、帧数递增、`simulated=false`，再确认物理屏幕可见且时钟更新。显示正常不能替代 LAN/Wi-Fi/DHCP/VPN 验证，也不能证明供电正常。

```sh
/etc/init.d/kk-car-hdmi stop
/etc/init.d/kk-car-hdmi disable
```

停止服务恢复文本控制台。将脚本、字体/许可证、init 服务与启动链接列入自己的 sysupgrade 保留清单；启动分区在升级或重刷后另行核对。原始 EDID、运行截图、实际配置和采样只留在私密备份中。已实测结果与未验证范围见 [验证记录](VALIDATION.md)。

## 当前设备实测状态

2026-09-21 经用户确认后完成一次受控重启，设备已实际输出 1920×1080，显示服务开机启动并持续刷新；公司侧 VPN 管理和无线客户端连接均已恢复。此次重连更换了 VPN 虚拟地址，备用入口应使用屏幕上显示的当前地址。详见验证记录；该结果不代表长期供电和移动网络耐久验收。

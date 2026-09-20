# HDMI 本地状态屏

`kk-car-hdmi` 直接在树莓派自带 HDMI 对应的 framebuffer 上绘制只读状态页。每 5 秒刷新，由树莓派独立运行，不需要 Mac、浏览器、桌面环境或额外字体。当前为英文像素字体，避免在路由器安装大型图形组件。

## 显示内容

- IKEv2 连接状态与最近一轮 VPN Ping；超过 25 秒的探测不显示旧延迟。
- LTE RSRP 与信号格数；上网棒缓存超过 75 秒时显示未知。
- CPU 使用率、温度、已使用内存比例、Wi-Fi 在线客户端数。
- 当前出口、下载/上传速率，以及最近约 5 分钟的 VPN 延迟柱状图。
- 运行时间、当前欠压状态、IPv6 状态和持续变化的时钟。

首帧 CPU 和速率为 `--`，下一轮计数采样后才显示。内存占比使用 `MemAvailable`，不是只计算完全空闲内存。出口切换、计数器归零时跳过该轮速率。接口流量不是运营商账单。

数据复用已有 `kkcar.status` RPC。屏幕不会显示 VPN 服务端地址、出口公网 IP、密码、Webhook 或客户端身份；不执行联网测试、切换网络或重启 VPN。屏幕记录与诊断只写入 `/tmp`。

## 支持范围

本版仅针对 Raspberry Pi 3B+ 的 legacy `BCM2708 FB`、32 位 BGRA、零偏移 framebuffer；设备启动参数需含 `bcm2708_fb.fbswap=1`。最低逻辑画面为 640×360，按整数倍居中，支持本次设置的 1280×720。未知格式拒绝写入，错误不会修改网络配置。

这不代表已验证 KMS/DRM、其他树莓派型号或 e-Paper 屏幕。HDMI 显示与未来 SPI 墨水屏使用不同的底层驱动。

## 安装与启动

先完成 KK-Car 主程序部署，保证 `ucode`、`ucode-mod-fs`、`ucode-mod-ubus`、`vcgencmd` 和 `kkcar.status` 可用。将下列两个文件按同名绝对路径安装：

```text
kk-car-ui/root/etc/kk-car/hdmi.uc
kk-car-ui/root/etc/init.d/kk-car-hdmi
```

```sh
chmod 755 /etc/init.d/kk-car-hdmi
ucode -c -o /tmp/kk-hdmi-check.ucb /etc/kk-car/hdmi.uc
sh -n /etc/init.d/kk-car-hdmi
/etc/init.d/kk-car-hdmi enable
/etc/init.d/kk-car-hdmi start
```

如果启动时没有连接显示器，固件可能保留低分辨率默认输出；`vcgencmd display_power 1` 成功也不代表显示器已收到有效信号。先私密备份 `/boot/config.txt`，按显示器能力选择模式。此次使用以下标准 720p 配置，修改后需重启才能生效：

```ini
[all]
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=4
hdmi_drive=2
disable_overscan=1
framebuffer_width=1280
framebuffer_height=720
```

不要覆盖整个启动文件；保留原来的 `include distroconfig.txt` 与其他设备设置。重启会短暂中断热点和 VPN，管理电脑可能自动连接其他 Wi-Fi，需要重新连接路由器热点。

可将两个程序文件和 `/etc/rc.d/S99kk-car-hdmi` 加入 `/etc/sysupgrade.conf`。启动分区的显示设置需在固件升级或重刷后单独核对，不能据此假定升级后一定保留。

## 检查与停止

```sh
cat /sys/class/graphics/fb0/virtual_size
cat /tmp/kk-car-hdmi-status.json
ubus call service list '{"name":"kk-car-hdmi"}'
```

状态中的 `frames` 应持续增加，`simulated` 应为 `false`。这些只证明进程与 framebuffer 写入；最终还需在物理显示器上确认能看见画面和时钟更新。

只生成测试画面、不覆盖显示器：

```sh
ucode /etc/kk-car/hdmi.uc --simulate --once
```

输出 `/tmp/kk-car-hdmi-test.raw`，按当前 stride 与 BGRA 格式解码。测试会更新 HDMI 诊断文件；运行中的服务会在下一轮覆盖该文件。

停止并取消开机显示：

```sh
/etc/init.d/kk-car-hdmi stop
/etc/init.d/kk-car-hdmi disable
```

停止时恢复文本控制台及光标。若要撤销强制 HDMI 模式，只移除本功能添加的配置块，或恢复安装前私密备份，再重启。不要恢复无关的旧网络配置。

运行数据、framebuffer 截图和原设备启动配置不属于公开备份内容。

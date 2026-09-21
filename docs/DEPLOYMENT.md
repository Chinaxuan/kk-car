# 部署与更新

## 这是设备定制源码，不是通用一键固件

本项目备份了已部署的页面、服务和路由维护脚本。它依赖事先配置好的 LAN、Wi-Fi、USB WAN、IKEv2、DNS 与分流。仓库不提供认证资料，也没有把实际 `/etc/config/` 和 `/etc/swanctl/` 上传。

**复制 `root/` 不能单独完成一台空白设备的网络配置。** 新机器先安装 OpenWrt，完成下述基础配置与逐项连通性验证，再迁移面板。

## 已适配前提

- Raspberry Pi 3B+，OpenWrt 25.12.5，LuCI + rpcd ucode。
- `br-lan` / `lan`：192.168.88.1/24；无线 UCI 段 `radio0`、`default_radio0`。
- USB WAN：`wan` / `eth1`；F30A Pro：192.168.0.1，ADB TCP 5555。
- 有线：`eth0`；可选 DHCP WAN 配置段 `kk_ethwan`。
- strongSwan / swanctl：连接 `kk-car`，CHILD `kk-car-internet`。
- XFRM 接口 `ikecar`，接口 ID 88，MTU 1400；服务器与 PSK 在设备私密配置中设置。
- VPN 业务 mark `0x20000/0xff0000` → table 300 / priority 10000；直连 mark `0x10000/0xff0000` → table 301 / priority 9990。
- IPv6 关闭；国内域名使用国内 DNS，其余 DNS 显式经 VPN。

所需软件族包括 LuCI、rpcd ucode、ucode 的 fs/uci/ubus 模块、curl、adb、strongSwan / swanctl、PBR、nftables / XFRM 支持、USB 网卡驱动及树莓派工具。`packages-reference.txt` 是当时的软件清单参考，不是所有版本通用的安装清单；重刷后按固件软件源解决版本匹配。

## 迁移前先替换环境参数

仓库保留接口与内网拓扑约定；公司公网 IP 和观测到的真实出口 IP 已全部脱敏。`203.0.113.10` 为 VPN 服务端示例，`203.0.113.20` 与 `198.51.100.x` 为出口示例。它们不可用于实际连接，恢复部署前必须在本地换成真实值，且不要提交这些真实值。

| 参数 | 位置 |
| --- | --- |
| VPN 服务端固定 IPv4 路由 | `kk-car-ui/root/etc/kk-car/uplink-step.uc` |
| VPN Ping 目标 `10.8.8.8` | `vpn-ping.sh`、后台和页面展示 |
| 公司 HTTP 服务目标 | `ui-job.sh` 与页面诊断说明 |
| ADB 目标 | `modem-read.sh` / `modem-poll.sh` |
| LAN、无线段、接口名 | `kkcar.uc`、出口脚本和 `install-ethernet.uc` |
| 国内地址集及防止直出规则 | `20-kk-car-china.nft` |

可先用 `rg -n '203\.0\.113\.10|10\.8\.8\.|192\.168\.' kk-car-ui` 定位，再逐项核对。示例服务端地址、内网服务和 IP 地址集均须按自己的环境适配。

## 更新现有 KK-Car

1. 确保 Wi-Fi 管理稳定、没有正在进行的热点或网口试用。
2. 先从 LuCI「系统 → 备份与更新」导出当前配置，离线保管；另保存安装包清单。
3. 对照改动，只上传需要更新的文件。`root/` 内目录对应路由器绝对路径，例如 `root/etc/kk-car/history.uc` 对应 `/etc/kk-car/history.uc`。
4. 脚本与 init.d 文件保持可执行；菜单、ACL、ucode、CSS、JS 为可读文件。建议先上传临时文件，再在设备端改名替换。
5. 仅更新页面 CSS/JS：强制刷新浏览器即可。更新 rpcd 后台：执行 `/etc/init.d/rpcd reload`，避免无必要的 restart 导致会话失效。
6. 更新某个采集器时，只重启对应服务。除非明确需要，不重启整个网络。
7. 检查日志、首页更新时间、历史读取，以及国内、VPN、公司服务和 DNS；涉及分流时，还要验证 VPN 停止后的直出保护。

## 有线 WAN 配置迁移

`install-ethernet.uc` 会修改 network / firewall / pbr。它要求已有 `br-lan`、WAN 防火墙区、`wan.device=eth1` 且没有待应用更改；重复运行会保留已选择的端口模式。

这是部署迁移工具，**不是普通页面更新步骤**。只在确认拓扑匹配、备份完成且通过 Wi-Fi 可管理时运行。网络与防火墙重载会影响现有连接，应在可恢复的维护时间进行。

## 服务与启动

| 服务 | 用途 |
| --- | --- |
| `kk-car-ui-recovery` | 网络启动前回退尚未确认的热点 / 网口试用 |
| `kk-car-route` | 保持 IKEv2 策略路由 |
| `kk-car-uplink` | 有线 / 4G 出口选择 |
| `kk-car-modem` | 上网棒 ADB 状态采集 |
| `kk-car-vpn-ping` | VPN 探测与历史保存 |
| `kk-car-auto-check` | 每 10 分钟执行六项网络检查，与手动检查互斥 |
| `kk-car-notify` | 事件推送、限频队列与开关机通知 |

首次部署需要按依赖启用相应服务。备份清单应覆盖 `/etc/kk-car/`、对应 init.d 与启动链接、热插拔文件、nftables、strongSwan 行为配置、LuCI 前端/菜单和 rpcd 后台/ACL。

仓库没有经空白 SD 卡完整重装验证，不能把这些步骤视作已验收的一键安装器。

## 增量部署飞书推送

上传 `notify-config.uc`、`notify-engine.uc`、`notify-worker.uc`、`notify-watch.sh` 和 `init.d/kk-car-notify`，同时更新 rpcd 后台、ACL、LuCI 菜单及前端 `notifications.js/css` 和首页入口。先放齐模块，再刷新 rpcd，避免导入缺失影响原页面。设置 `notify-watch.sh` 与 init.d 服务为 0755，启用并启动 `kk-car-notify`。源代码默认关闭推送；在设备页面配置自己的地址后启用。不需要重载 network、firewall 或 VPN。

服务启动优先级 99，正常关机优先级 10；`shutdown` 与普通服务 `stop/restart` 区分，维护服务不会伪造关机通知。保留私密配置权限与启动链接。参见 [推送说明](NOTIFICATIONS.md)。


## HDMI 本地状态屏

可选的 `kk-car-hdmi` 服务直接输出到树莓派 HDMI；安装前备份启动配置，停止服务可恢复文本控制台。显示模式、安装、检查与撤销步骤见 [HDMI 状态屏](HDMI.md)。原设备启动配置与画面截图只保留在私密备份中。

## VPN 备用管理与无线修复

2026-09-21 新增可选 VPN 管理输入规则和动态源地址返回路由，依赖 `flock`，预留路由优先级 9980。单独的 Pi 3B+ 无线安装器可固定使用本机硬件地址。两项均不属于普通页面更新的默认步骤；安装前提、备份、验证和撤销见 [网络恢复](NETWORK-RECOVERY.md)。

## 中文高密度 HDMI 更新

新版须同时部署 `hdmi.uc`、`hdmi-font.json` 与 `hdmi-font.LICENSE`，保留原 init 服务。先用模拟参数验收布局，再只重启显示服务；单纯内容更新不重启 network。真实 1080p 的启动配置、短时断网与回退方法见 [HDMI 说明](HDMI.md)。

## 每 10 分钟自动网络检查

上传 `kk-car-ui/root/etc/kk-car/auto-check.sh` 与 `root/etc/init.d/kk-car-auto-check` 到设备对应位置，权限 0755；同时更新 `kkcar.uc` 与 `overview.js`。若使用 HDMI，同时更新 `hdmi.uc` 和 `hdmi-font.json`。依赖已有 `flock`、`ubus`、`jsonfilter`、`jshn.sh` 与原诊断工作脚本，不新增认证信息。

```sh
/etc/init.d/rpcd reload
/etc/init.d/kk-car-auto-check enable
/etc/init.d/kk-car-auto-check start
# 已安装 HDMI 且本次更新了显示文件时执行
/etc/init.d/kk-car-hdmi restart
```

服务启动后约 15 秒首次检测；在开机阶段最早等运行满 60 秒。后续按每次成功接受任务的时间间隔 600 秒触发。任务忙碌后 15 秒重试，RPC 不可用后 60 秒重试；实际开始时间可能稍后。计时使用运行时间，系统校时不改变间隔。状态和结果只存内存，失败不会触发网络或 VPN 重启。

用 `ubus call kkcar status` 查看 `diagnostics_auto`、六项结果与检查时间；管理页和 HDMI 也显示最新结果。本次更新不需要重启路由器、网络或 VPN。撤销自动检查时执行：

```sh
/etc/init.d/kk-car-auto-check stop
/etc/init.d/kk-car-auto-check disable
```

手动检查按钮仍可使用；已经开始的单次检查可能继续至有界超时结束。恢复时重新 enable 和 start。回退显示改动时，从私密备份只恢复对应显示文件及后台文件。

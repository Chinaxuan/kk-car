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
| `kk-car-dji-sms-forward` | DJI 新短信轮询、飞书正文转发、SD 卡公钥加密归档 |

首次部署需要按依赖启用相应服务。备份清单应覆盖 `/etc/kk-car/`、对应 init.d 与启动链接、热插拔文件、nftables、strongSwan 行为配置、LuCI 前端/菜单和 rpcd 后台/ACL。

仓库没有经空白 SD 卡完整重装验证，不能把这些步骤视作已验收的一键安装器。

## 增量部署飞书推送

上传 `notify-config.uc`、`notify-engine.uc`、`notify-worker.uc`、`notify-watch.sh` 和 `init.d/kk-car-notify`，同时更新 rpcd 后台、ACL、LuCI 菜单及前端 `notifications.js/css` 和首页入口。先放齐模块，再刷新 rpcd，避免导入缺失影响原页面。设置 `notify-watch.sh` 与 init.d 服务为 0755，启用并启动 `kk-car-notify`。源代码默认关闭推送；在设备页面配置自己的地址后启用。不需要重载 network、firewall 或 VPN。

服务启动优先级 99，正常关机优先级 10；`shutdown` 与普通服务 `stop/restart` 区分，维护服务不会伪造关机通知。保留私密配置权限与启动链接。参见 [推送说明](NOTIFICATIONS.md)。

## DJI 长短信、飞书转发与加密备份

增量部署 `dji-sms.uc`、`dji-sms-forward.uc`、`dji-sms-forward-watch.sh`、`init.d/kk-car-dji-sms-forward`，同时更新 `notify-config.uc`、`kkdji.uc` 与 DJI/通知页面。短信串口依赖 `socat`、`flock`；加密归档另需 `openssl-util` 和 `sha256sum`。在可信电脑上生成 CMS 接收证书与私钥，只把公开证书放到设备 `/etc/kk-car/private/sms-archive-recipient.pem`；私钥留在离线安全位置。创建 `/etc/kk-car/private/sms-archive/` 并设 0700；服务脚本、init.d 设 0755。先启动服务建立已有短信基线，再到飞书页面启用「DJI 新短信正文」，避免旧验证码批量发送。证书未配置时归档会报错，不能把转发成功当作备份成功。

本服务不改 `network`、Wi-Fi、DHCP、VPN；不会自动删除 SIM 或模块短信。当前短信脚本会在操作时将读取、写入和接收仓选为 SIM `SM`；部署到其他 SIM 前先用 `storage_probe` 确认支持，再读回三个仓位置和容量。SIM 容量独立于 SD 卡，满仓时需先验证加密备份可解密，再由管理员明确决定是否删除旧短信。更换存储仓时服务会把该仓已有短信作为历史基线，不会补发。当前设备已有一次真实新短信归档和飞书成功回复；新设备仍应重新做端到端验收。

## 试验性网页电话与来电提醒

增量更新 `dji-sms.uc`、`dji-at-status.sh`、`notify-config.uc`、`notify-worker.uc`、`notify-watch.sh`、`kkdji.uc`、ACL、DJI 页面、`notifications.js` 和 `voice-worklet.js`。语音运行时脚本为 `dji-voice-*`、`module-voice-*` 及两个 `kk-car-voice-*` init 服务。`voice-gateway/` 需自行编译 Linux arm64 可执行文件；运行时驱动、音频辅助程序、设备 HTTPS 私钥均**不在公开仓库**。只在来源、哈希、模块内核版本和证书信任逐项核对后启用实验服务，细节见 [电话验证与限制](VOICE-CALLS.md)。

配置飞书来电/未接事件与推送地址时，先保存并回读开关；通知服务此后约每 5 秒采样，地址仍只保留在设备私有配置。更新电话组件不需要重启 network、Wi-Fi、DHCP、VPN 或整机。部署后读回原蜂窝 WAN、VPN、Wi-Fi、短信和通知服务，再用真实来电分别验证提醒和声音。2026-09-25 已有一次 15–30 秒、双方有声的网页来电短测；新设备仍须重新实测，不能把硬件检测成功当成通话验收成功。


## HDMI 本地状态屏

可选的 `kk-car-hdmi` 服务直接输出到树莓派 HDMI；安装前备份启动配置，停止服务可恢复文本控制台。显示模式、安装、检查与撤销步骤见 [HDMI 状态屏](HDMI.md)。原设备启动配置与画面截图只保留在私密备份中。

## EP-0136 UPS 电源

UPS 管理页依赖 I²C 与 `i2c-tools`。先备份启动配置，在 `/boot/config.txt` 启用 `dtparam=i2c_arm=on`，重启后确认主控与传感器地址；再部署 `ups-read.uc`、`ups-control.uc`、`ups-watch.uc`、`ups-watch.sh`、`kk-car-ups` init、`kkups.uc`、`ups.js/css` 及对应菜单/ACL。启用监控服务后默认策略仍为关闭。只替换四个页面的 JS/CSS 时刷新浏览器即可；改动 `ups-read.uc` 等 rpcd 模块后需重启 rpcd，再确认管理页重新登录和状态读回，不重启 network。设备只从 UPS 供电；实机电源操作与低电关机验收边界见 [UPS 适配说明](UPS.md)。

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


## QMI 适配更新顺序

同时更新 `uplink-model.uc`、`uplink-policy.uc`、`uplink-step.uc`、`uplink-watch.sh` 及 RPC/历史调用方；新模型不能漏装。检查完整 nft 候选后启用覆盖 eth/wwan/usb 的防泄漏规则，再改 logical WAN 为 QMI。`modem-qmi-read.sh` 与 `modem-poll.sh` 应可执行；状态采集兼容原 F30A。只更新面板通常无需重启网络；首次安装协议包的情况见 [DJI QMI](DJI-QMI.md)。

手动替换前端资源后，LuCI 的资源版本仍可能沿用包数据库时间。本次更新只刷新 `/lib/apk/db/installed` 的修改时间、校验文件内容哈希不变，使正常页面刷新加载新资源；没有改变已安装软件包记录。

## DJI 独立控制页增量部署

先安装并核对 `root/etc/kk-car/dji-at-status.sh`、`dji-sms.uc`、`dji-control.sh`、`dji-traffic.uc` 与 `dji-traffic-parse.uc`，再放 `root/usr/share/rpcd/ucode/kkdji.uc`、ACL、LuCI 菜单和前端 `dji-console-v2.js`/`dji-console-v2.css`。两个可执行 `.sh` 设为 0755；rpcd ucode、流量 ucode 与前端 0644。`dji-sms-forward-watch.sh` 负责约 30 秒一次的流量采样；更新后只重启该服务。依赖设备已有的 `ucode`、`socat`、`flock`、QMI 和 LuCI/rpcd ucode。部署前将现有菜单与 ACL 复制到设备私有备份；不要把真实设备配置、流量校正数字或短信带入仓库。

增量更新仅需重新加载 rpcd 与短信/流量后台服务，再用已登录会话打开 `/cgi-bin/luci/admin/kkcar_dji`。rpcd 重启可能使旧 LuCI 会话失效，重新登录即可。如果菜单缓存未刷新，清除 LuCI 菜单缓存再打开页面。当前前端采用 `dji-console-v2` 资源名，避免旧浏览器资源缓存。把版本化的 JS/CSS 路径加入设备 `/etc/sysupgrade.conf`，替换旧的 `dji-console` 条目；`/etc/kk-car/` 原已整体保留。**这一页的安装不要求重启 `network`、Wi-Fi、DHCP、VPN 或树莓派。**

左侧导航、通话记录与网络详情迭代需先放 `dji-phonebook.uc`（0600）、新版 `dji-at-status.sh`（0755）和 `dji-sms.uc`，再更新 `kkdji.uc`、ACL、`notify-worker.uc` 与前端资源。`notify-worker.uc` 需要导入 phonebook 模块；放齐文件后重启 `rpcd` 与 `kk-car-notify` 即可，不重启网络。首次通话记录文件由服务在 `/etc/kk-car/private/dji-phonebook.json` 自动创建，目录应为 0700、文件 0600；迁移时只通过私密加密备份转移此文件，绝不加入公开仓库。小区 ID/TAC/PCI/EARFCN 只来自 `/tmp/kk-car-dji-at.json` 当前采样，不能纳入历史或公开截图。

验收顺序是：先检查原首页、Wi-Fi、VPN 与当前出口；再用 `ubus call kkdji status`、`ubus call kkdji traffic_status` 查 QMI、AT、短信仓和设备流量；最后用浏览器检查新页面的实机数据及短信目录自动读取。新增的 `call_status` 和 `gps_probe` 是受 LuCI 登录权限限制的只读 RPC；GPS 启停经原 `action` 白名单执行，不重启网络。目录读取可能改变未读标志；正文仍要点击会话才读取。每天查询依保存的运营商、号码、指令和时间运行；部署当天若已经手动查过，应先记录当天已查询，避免立刻重复发送。发送、删除与重新连接需真实业务意图。定位天线未验证时可以只读检查；若测试启动 GNSS，结束后应停止并读回关闭状态。操作解释见 [DJI 模块控制](DJI-CONTROL.md)。

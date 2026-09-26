# 网络故障与 VPN 备用管理

## 本地连不上时先区分故障范围

| 现象 | 优先核实 |
| --- | --- |
| 热点能搜到，连接后很快断开 | 查看 AP 认证、断开日志与 DHCP 租约；收到 DHCPACK 不代表连接能保持 |
| Wi-Fi 不通，有线能进 | 保留有线管理，采集无线日志后只处理无线，不必重启整个网络 |
| 本地都不通，但 VPN、推送仍工作 | 从公司网络用当前 VPN IPv4 打开管理页或 SSH |
| 管理页显示旧数据或不能通信 | 区分登录过期、页面缓存与设备网络失联 |
| VPN 也断开 | 备用入口不可用，使用 HDMI + USB 键盘进行本地诊断 |

推送成功、红灯亮、屏幕更新分别只能证明部分功能仍在运行。不要据此直接判定 DHCP、Wi-Fi 或供电正常。先保留日志与配置，再决定是否重载服务；不要先重刷 SD 卡。

## VPN 备用入口

在公司网络访问 `http://<树莓派当前 VPN IPv4>/cgi-bin/luci/admin/kkcar`，或 SSH 到该地址。地址可在设备 `ip -o -4 addr show dev ikecar` 中查看。VPN 服务端可能在重连时分配不同地址；本实现跟随设备实际地址维护路由，**不负责让服务端固定分配地址**。

本项目部署选择允许所有经 `ikecar` VPN 区域到达的 IPv4 来源访问 TCP 22、80、443 及 ICMP echo-request。仍使用原有 SSH/LuCI 认证，不新增账户，不在物理 WAN 开放这些入口，也不开放 VPN 到 LAN 的任意转发。

此前 VPN 区域默认拒绝输入；同时，设备以 VPN 地址发出的管理回复会落到物理 WAN。新增 `vpn-management-route.sh` 按实时分配的地址建立 `priority 9980 from <VPN IPv4>/32 lookup 300`，先于物理出口规则，保证回复回到 XFRM 接口。

维护脚本由已有 `ike-route-ensure.sh` 调用，路由守护每约 5 秒运行，并在 IPsec up/down 钩子中使用。`flock` 防止并发；仅删除自己记录的精确旧地址规则，不清空路由表或整段优先级。关闭开关、地址消失或变更后会清理对应旧规则。

### 增量安装（仅适用于本文档指定拓扑）

1. 保留可用的本地有线管理。确认接口为 `ikecar` / XFRM、VPN 表为 300、现有 `kk-car-route` 服务已启用，并安装 `flock`。确认优先级 9980 没有被其他功能占用。
2. 在设备私密目录备份 `/etc/config/firewall` 和 `/etc/kk-car/ike-route-ensure.sh`。
3. 将仓库中的 `vpn-management-route.sh` 和 `ike-route-ensure.sh` 传到临时目录，比对当前设备的路由维护逻辑，再原子替换到 `/etc/kk-car/`，权限 0755。不要覆盖其他定制路由功能。
4. 上传并运行 `ucode /tmp/install-vpn-management.uc`。安装器核对拓扑、拒绝未应用的防火墙改动，并保存两个 VPN 区域输入规则。
5. 执行 `fw4 check`。失败时恢复刚备份的 firewall 文件，不重载防火墙；检查成功后执行 `/etc/kk-car/ike-route-ensure.sh` 和 `/etc/init.d/firewall reload`。不需要重启 network、VPN 或整机。
6. 验证 `ip -4 route get <公司测试机地址> from <当前 VPN 地址>` 显示 `dev ikecar table 300`，再从真实公司网络测试 Ping、SSH 与登录后的页面。连接着树莓派 LAN 的电脑直接访问 VPN 地址，不足以证明反向通道可用。

### 关闭备用入口

```sh
uci set firewall.kk_vpn_admin.enabled='0'
uci set firewall.kk_vpn_admin_ping.enabled='0'
uci commit firewall
fw4 check && /etc/init.d/firewall reload
/etc/kk-car/vpn-management-route.sh
```

关闭后守护不会重新添加源地址规则。撤销文件前先执行关闭与清理；也可恢复维护前的 firewall 与路由维护脚本备份。所有私密备份不应上传到公开仓库。

## Pi 3B+ 无线地址一致性修正

2026-09-21 的一次故障中，无线客户端已经完成 WPA2 握手、取得 DHCPACK，却随后立即断开。实机 AP 的 BSSID 与硬件地址、生成的 hostapd 配置不一致。将 AP 显式设为本机硬件地址并单独重建无线后，连接恢复；**地址修正和无线重建同时发生，不能据此证明所有历史故障都只有同一原因**。

`install-wifi-address.uc` 是可选、限定设备的安装器：仅允许 Raspberry Pi 3B+ 原生 brcmfmac、phy0/radio0 和 default_radio0 AP 拓扑；读取设备本身的硬件地址，不写死某台设备的 MAC。已有不同的显式 MAC 或未应用的无线改动时停止，避免覆盖定制配置。

先备份 `/etc/config/wireless`，通过有线管理执行安装器。若确认需要应用，执行 `wifi down radio0`、`wifi up radio0` 单独重建无线；这会短暂断开所有无线客户端。不要在仅有 Wi-Fi 管理时直接操作。安装器本身只保存配置，不会重启任何接口。面板后续修改名称、密码与频段会保留该 MAC 设置。

回退时经有线恢复维护前的 wireless 备份并重建 radio0。更新固件后应重新核对驱动与实际 AP 地址，不能盲目套用其他机型。

## 验证边界

本次通过公司 Wi-Fi 强制绑定出口测试，并在树莓派 ikecar 接口抓到双向数据；Ping、已有 SSH 密钥登录及 LuCI 登录后的页面 HTTP 200 均通过。路由维护脚本通过幂等、VPN 地址变化、禁用/断线清理、部分失败重试和不干扰其他规则的隔离测试。

Wi-Fi 修正后已观察到此前反复断开的客户端持续连接超过 10 分钟，且 Mac 经 Wi-Fi 探测没有丢包。此结果是现场短时验证，未做新的冷启动和长时间行车耐久验收。供电曾有独立欠压记录，仍需持续观察。

## 固定请求 VPN 管理地址

2026-09-21 将树莓派 `/etc/swanctl/conf.d/kk-car.conf` 中 KK-Car 连接的 `vips = 0.0.0.0` 改为 `vips = 10.8.250.1`，并保存到设备持久化配置。该参数表示每次连接请求指定虚拟地址；最终由服务端分配，不能把客户端请求等同于服务端静态绑定。

爱快保留原有 `10.8.250.0/30` 地址池和限定客户端标识。实机将地址池收窄为 `/32` 后出现 VPN 丢包 100%，已回退，不应按该方法缩池。随后仅重连树莓派 VPN，确认爱快接受 `.1` 请求，地址为 `10.8.250.1`，目标探测丢包 0%。

管理入口：`http://10.8.250.1/cgi-bin/luci/admin/kkcar`，需要处于能够路由到该 VPN 网段的网络。已有动态返回路由继续按实际协商地址工作；若未来服务端分配策略改变或地址被占用，应以设备显示的实际地址为准。

修改前私密备份连接配置；用 `swanctl --load-conns` 加载后，仅重连 KK-Car VPN 并验证实际地址、公司访问与国外出口。无需重启 Wi-Fi、LAN 或整台设备。撤销时恢复原配置中的 `vips = 0.0.0.0` 并重新加载、重连。真实连接文件与密钥不上传仓库。此次没有为了验证该修改再次重启整台树莓派。


## DJI QMI 模块恢复

先区分 USB 识别、SIM 就绪、基站注册、数据会话和真实访问。多个 cdc-wdm 节点不一定表示多张网卡；临时通用动态 ID 绑定可能误占串口。不要直接刷整机来修这类问题。恢复 CDC 上网棒或读取原 USB 设置时使用本地私密备份，见 [DJI QMI 回退说明](DJI-QMI.md)。

## 故障追溯

现已提供 [每分钟故障记录](FAULT-LOG.md)：UPS 页可看到是否持续保存，详细私有快照与关机原因在设备 SD 卡。排查 4G 绿色指示灯但没有信号显示、突然掉电或反复重启时，先读取记录，不要直接重置网络或刷机。没有正常关机标记只说明未记录正常关机，不等于已确认电池故障。

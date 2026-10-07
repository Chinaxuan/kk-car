# 有线网络上的 OpenVPN/TCP

2026-10-07 状态：此文记录 OpenVPN/TCP 单隧道的部署与验证。当前设备还运行 WireGuard 自动选线；现行策略见 [VPN 自动选线](VPN-AUTO-SELECT.md)。不要直接把下文的单隧道 PBR/DNS 设置覆盖到当前设备。

2026-10-02，KK-Car 从 IKEv2 切到爱快 OpenVPN/TCP。原因是当次电信有线上联能收到 IKE 首次应答的分片前段，后续分片未到树莓派；同一上联上的 OpenVPN/TCP 已实测连通。此结论只针对当次链路，不代表 IKEv2 端口普遍被封锁。

## 工作方式

车端 OpenWrt 以专用账号连接爱快 TCP 28443，虚拟接口名 `ovpncar`。PBR 把公司内网和非中国大陆 IPv4 送入隧道；国内流量走当前有线或蜂窝出口。`192.168.0.0/16` 为本地私网例外，也走当前有线或蜂窝出口，不送公司。国内与国际 DNS 分开，国际上游 DNS 绑定 `ovpncar`。路由表 300 保留不可达默认路由，隧道停止时国外业务不会自动漏到物理 WAN。当前有线口为 WAN 时，PBR 上游必须是 `kk_ethwan`；切回蜂窝时由上联守护改为 `wan`。

爱快账号、CA 证书、服务端实际地址及密码只保留在设备和离线私有备份。本公开仓库不包含能直接连接的配置。下例中的 `203.0.113.10` 是文档示例地址，不能用于实际连接：

```conf
client
dev ovpncar
dev-type tun
disable-dco
proto tcp-client
remote 203.0.113.10 28443
resolv-retry infinite
nobind
persist-tun
auth-user-pass /etc/openvpn/kkcar.auth
auth-nocache
ca /etc/openvpn/kkcar-ca.crt
verify-x509-name "iKuai OpenVPN Server" name
data-ciphers AES-256-GCM
data-ciphers-fallback AES-256-GCM
cipher AES-256-GCM
route-nopull
pull-filter ignore "redirect-gateway"
verb 4
```

当前爱快自动生成的服务端证书没有服务器用途扩展，故不能使用 OpenVPN 的 `remote-cert-tls server` 检查；客户端仍验证专用 CA 与服务端证书名称。更换爱快证书后，要同步更新本地 CA 并重新核对名称。不要关闭证书验证。

## 部署与迁移

1. 先确认 Wi-Fi 管理入口可用，离线备份 `/etc/config/network`、`firewall`、`pbr`、`dhcp`、`openvpn` 和旧 VPN 配置。证书、账号、密码文件权限设为 `0600`。
2. 爱快启用 OpenVPN/TCP 与专用账号，车端安装 OpenWrt 官方 `openvpn-openssl` 和 `kmod-tun`，把私有客户端配置放入 `/etc/openvpn/kkcar.conf`。只保留一个会被服务自动扫描的 `.conf` 文件，避免同名隧道双实例冲突。
3. 新增 `network.ovpncar`（`proto=none`，`device=ovpncar`）、独立防火墙区域及 LAN 到该区域的转发。PBR 的 `supported_interface` 和国外/DNS 策略改为 `ovpncar`，物理 `uplink_interface` 根据当前实际 WAN 选择。国际 DNS 上游从 `@ikecar` 改为 `@ovpncar`。不修改热点和 LAN 地址。
4. 先验证隧道地址、CA 与证书名称验证、公司测试主机和境外出口，再启用 OpenVPN 开机服务。旧 IKEv2 停用开机服务但保留配置；WireGuard 配置也继续保留。
5. 将本仓库的状态、重连、探测和上联维护脚本部署到设备，检查 `kkcar.status.vpn.backend` 为 `OpenVPN/TCP`，VPN Ping 与网络守护检测 `ovpncar`。必要时更新 LuCI 静态页面并重载 `rpcd`。恢复外部访问前先确认防火墙只开放 VPN 区域的认证管理入口，未在物理 WAN 开放。
6. 验证 Wi-Fi 客户端、国内直连、公司内网、国际出口及 DNS；临时停止 OpenVPN 时确认境外流量被阻断而国内仍可直连，随后立即恢复并检查告警。

`192.168.0.0/16` 例外需要两处一致：PBR 为来自车端 LAN、目标为该网段的流量设置 `ignore`（保留主路由），`20-kk-car-china.nft` 的物理 WAN 防漏规则也放行该网段。仅改 PBR 会被防漏规则拒绝。网段内地址若不在当前本地网络可达范围，仍可能访问失败；它不会因此改走公司隧道。

网口切换由现有两分钟确认回退保护。跨 VLAN 内网服务仍可能受公司侧路由、防火墙或目标主机 ACL 限制；隧道连通不等于所有公司地址都可访问。

## 当次实测范围

有线 WAN 为电信光猫下发的私网地址。车端 OpenVPN 建立 AES-256-GCM 会话；从 KK-Car Wi-Fi 访问公司测试服务与境外站点成功，国内站点直连，国内和国际 DNS 均正常。公司 VPN 侧能 Ping 到车端新隧道地址，管理页有 HTTP 响应。网络重载后隧道保持，手动停用/恢复和断线阻断均通过。`10.7.0.31:8188` 经隧道仍超时，而公司 Mac 直接访问为 HTTP 200，尚需单独排查公司侧跨 VLAN 路由或访问策略。蜂窝切换、整机断电重启和移动中长时间稳定性未在本轮验收。

补充验证：车端客户端访问本地上级网关 `192.168.2.1`，Ping 3/3 成功且 HTTP 返回登录限制；公司测试服务、境外站点、国内站点同时返回 HTTP 200，OpenVPN 保持连接。`192.168.0.0/16` 的 PBR 例外和物理 WAN 防漏放行均已生效；未逐一验证该 /16 下的所有子网。

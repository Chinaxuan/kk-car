# 手动公司白名单

## 使用

在左侧选择「公司白名单」，或打开 `http://192.168.88.1/cgi-bin/luci/admin/kkcar_routing`。连接设置页的 VPN 控制也提供入口，沿用原管理员登录。

1. 输入域名、IPv4 地址或 CIDR 网段，每行一条，可选备注。例如 `portal.example.com`、`10.9.20.31`、`10.9.20.0/24`，均为文档示例。
2. 点击「加入列表」，再点「保存并应用」。也可直接输入后点保存。
3. 等待上方的「已保存版本」和「已应用版本」一致并显示「已生效」。应用失败会显示错误；仅显示保存成功不等于路由已应用。
4. 每条规则、白名单总开关都可独立启停，修改地址或备注、删除后也需保存。最多 128 条，重复项及非法输入会被拒绝。

域名包含全部子域名，`*.example.com` 会规范化为 `example.com`。不填写网址协议、路径或端口。内网域名需要公司的专用 DNS 时，展开「公司内网 DNS」填写可通过 VPN 访问的 IPv4；留空使用 VPN 内的公共 DNS。

终端应使用 KK-Car 提供的 DNS。浏览器安全 DNS、手动指定其他 DNS、已有缓存和旧连接不在域名学习覆盖范围内；保存后重新打开网站，必要时清理终端 DNS 缓存。路由根据解析出的 IP 匹配，共享 IP 的其他域名也可能走公司出口。

192.168/16 始终走本地，不允许加入；上级直连网段、VPN 服务器和保留地址也受保护。IPv6 未启用，不接受 IPv6 规则。

## 分流与 DNS

- 独立 nft prerouting 链优先级 -152，早于现有国内直连链 -151；输出链为 route/output，兼顾树莓派自身发起的请求。
- 命中后写入项目固定标记 `0x20000/0xff0000`，经既有优先级 10000、表 300 跟随 OpenVPN/TCP 或 WireGuard。先核实该规则及表 300 的 unreachable 默认路由存在，否则不应用。
- 不修改物理出口优先级、PBR 策略、VPN 配置或选择器。缺少 VPN 路由时依靠表 300 的 unreachable 默认项阻止回落公网。
- 独立 postrouting 守卫额外阻止白名单地址经两条公司 VPN 以外的接口发出；即使路由守护短时未就绪，也不让国内白名单静默回落物理 WAN。
- 当前 dnsmasq 没有 nftset 支持。Python 标准库实现的专用 DNS 服务只监听 `127.0.0.1:1054` 的 UDP/TCP，不对 LAN/WAN 开放新端口。
- 白名单域名的 dnsmasq server 规则指向该服务；上游套接字绑定当前 VPN 接口及固定标记。支持标准 A 响应、CNAME 链、UDP 截断转 TCP。地址写入 nft 成功后才返回 DNS 应答；上游或 nft 失败返回 SERVFAIL，不回落本地解析。
- 已学习的地址保留到 DNS TTL 到期，最低保留 60 秒；随 VPN 切换继续使用表 300，避免终端缓存地址暂时落入国内直连。后台每 5 分钟预解析根域名，真实子域名查询实时学习。重启后运行地址缓存重建，终端旧缓存可能需重新查询。
- 自动排除内置国内 DNS 列表中与白名单冲突的相同及更具体后缀；停用或删除后恢复。原始列表备份到设备私有目录，不上传仓库。
- 仅对白名单后缀加入 DNS rebind 例外，允许公司 DNS 返回 10.x 等内网地址；不全局关闭 DNS 重绑定保护。
- DNS `reload` 不会重新读取 conf-dir 的 server 规则；域名集合变化时需短暂重启 dnsmasq，保留现有租约，Wi-Fi、netifd 和 VPN 不重启。仅改 IP 或备注不需要重启 DNS。

## 部署

本组件依赖项目现有的公司 VPN、表 300 防泄漏路由、fw4/nft、Python 3、ucode、rpcd 和 LuCI；不是用于任意 OpenWrt 的通用安装器，无需更换当前 dnsmasq 软件包。

新增文件按 `kk-car-ui/root/` 映射到设备绝对路径：

- `etc/kk-car/company-routing.py`
- `etc/init.d/kk-car-company-routing`
- `usr/share/rpcd/ucode/kkroute.uc`
- `www/luci-static/resources/view/kkcar/company-routing.js`、`company-routing.css`

同时合并菜单 `usr/share/luci/menu.d/luci-app-kkcar.json`、ACL `usr/share/rpcd/acl.d/luci-app-kkcar.json`、两个 console 导航资源和 overview 连接入口。不要覆盖本机其他修改。

```sh
chmod 755 /etc/kk-car/company-routing.py /etc/init.d/kk-car-company-routing
/etc/init.d/kk-car-company-routing enable
/etc/init.d/kk-car-company-routing start
/etc/init.d/rpcd reload
fw4 check
ubus call kkroute status
```

运行时生成的规则及状态：

| 文件 | 用途 |
| --- | --- |
| `/etc/kk-car/company-routing.json` | 私有配置，0600；保存后通过版本号避免并发覆盖 |
| `/etc/nftables.d/25-kk-car-company.nft` | fw4 重载后保留静态目标、集合与独立链 |
| `/etc/dnsmasq.d/kk-car-company.conf` | 仅白名单域名的 DNS 转发规则 |
| `/etc/kk-car/private/company-routing-china-original.conf` | 国内 DNS 原始列表备份 |
| `/tmp/kk-car-company-routing.json` | 已应用版本、错误、当前出口及临时域名地址，0600 |

配置、生成规则、DNS 缓存、截图与设备日志均属于私有数据，不发布。不要用运行中的国内 DNS 过滤副本覆盖原始备份；更新国内 DNS 数据库前应先停用白名单并恢复原始列表，更新后再建立新备份。

## 恢复

首选在页面关闭总开关并保存，等「白名单已停用」及版本一致；原国内 DNS 列表会恢复，配置仍保留以便重新开启。

若服务无法运行，先保留私有配置和错误信息。通过本地管理或 SSH 暂停服务，移除生成 DNS 文件，并用私有原始备份恢复国内 DNS 文件；只恢复本组件自己的文件，不重置整机网络。移除 nft 持久化文件前先 `fw4 check`，在有管理备用连接时再执行防火墙重载。域名 DNS 修复后仅重启 dnsmasq 即可。详见 [网络恢复](NETWORK-RECOVERY.md)。

## 验证与边界

2026-10-31 在 KK-Car 内创建临时网络命名空间，将 veth 接入 br-lan 模拟 LAN 客户端路径：白名单国内域名经路由器 DNS 解析，返回的地址进入域名集合，HTTP 200，prerouting 域名计数增加，标记后的表 300 指向当前 OpenVPN。静态测试 IP 规则同样增加计数；另外将一条仅针对模拟终端和测试目标的临时路由强制指向物理 WAN，独立出口守卫丢弃 3 个报文，随后删除临时路由；非白名单国内探测地址经表 301 指向物理 WAN，本地管理地址保持本地路由。未用 Mac 默认路由替代该验证。

测试还覆盖域名停用后的国内 DNS 原文恢复、集合清空、刷新读回、未登录会话写权限拒绝、桌面及 390px 界面。所有临时规则和模拟终端均在验证后删除。没有为了本功能重启整机、修改 Wi-Fi 或重连 VPN；没有用副卡移动数据上网。

本地回归：`python3 kk-car-ui/tests/company-routing.py`，覆盖输入/端点保护、CNAME、DNS 失败不返回可用答案、地址安装失败、配置原子保存与冲突、应用失败回退、VPN 切换时地址保留。原双 VPN 选择器回归也通过。移动过程中自动换线、完整掉电启动和真实公司私有域名仍需结合具体部署验证。

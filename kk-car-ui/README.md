# KK-Car 源码

项目介绍见 [仓库首页](../README.md)。

- [使用说明](../docs/USAGE.md)
- [部署与更新](../docs/DEPLOYMENT.md)
- [架构与实现](../docs/ARCHITECTURE.md)
- [验证与限制](../docs/VALIDATION.md)
- [备份与恢复](../docs/BACKUP.md)

`root/` 映射到设备绝对路径；认证资料与实际 UCI 配置不随源码发布。

## DJI 4G 独立控制页

`/cgi-bin/luci/admin/kkcar_dji` 以同一 OpenWrt 管理员权限提供 DJI 一代 QMI 模块状态。`kkdji.uc` 合并既有 QMI 缓存与经动态 USB 接口发现的 AT 只读数据；模块温度使用 `AT+QTEMP` 第一值，SIM 锁状态使用 `AT+CPIN?`，邻区只输出数量与最强 RSRP，短信仓占用由 `AT+CPMS?` 查询。刷新不会重启网络，重连仅针对 QMI `wan` 逻辑接口。短信中心在树莓派上提供长短信合并、列表搜索与详情，关闭详情清除页面正文；发送及删除必须由用户主动确认。当前设备把新短信保存在 SIM `SM`，树莓派在线时将完整短信加密归档到 SD 卡，并可按开关将正文转发飞书。短信 AT 回复和发送请求只短暂保存在设备私有 `/tmp`，不进入公共备份。VoHive 是运行在 Linux 主机上的独立程序，不会安装在 DJI 模块内部；这里参考其信息架构，仍使用原生 LuCI 和已有路由控制服务。

GNSS 状态命令可用，但外壳天线和定位尚未实测，页面不开放定位按钮；eSIM 管理未获支持证据，也不开放。部署时先放齐 `dji-at-status.sh`、`dji-sms.uc`、`dji-control.sh`，再安装 RPC、菜单、ACL 与 `dji.js`/`dji.css`，只刷新 rpcd，不重启 network。完整边界见公共仓库 `docs/DJI-CONTROL.md`。


## HDMI 只读状态屏

新增 `root/etc/kk-car/hdmi.uc` 与 `root/etc/init.d/kk-car-hdmi`，直接通过树莓派 legacy framebuffer 显示 VPN 延迟、LTE RSRP、CPU、温度、内存、Wi-Fi 客户端及接口速率，每 5 秒更新。独立于浏览器运行，不修改网络。需要匹配的显示模式，详细部署与撤销见发布仓库 `docs/HDMI.md`。

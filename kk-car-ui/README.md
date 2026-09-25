# KK-Car 源码

项目介绍见 [仓库首页](../README.md)。

- [使用说明](../docs/USAGE.md)
- [部署与更新](../docs/DEPLOYMENT.md)
- [架构与实现](../docs/ARCHITECTURE.md)
- [验证与限制](../docs/VALIDATION.md)
- [备份与恢复](../docs/BACKUP.md)
- [UPS 电源适配](../docs/UPS.md)

`root/` 映射到设备绝对路径；认证资料与实际 UCI 配置不随源码发布。

## EP-0136 UPS 电源页

`/cgi-bin/luci/admin/kkcar_ups` 通过已登录 LuCI 会话展示 52Pi UPS Plus EP-0136 的实时输入、输出、电池、温度及控制器状态。依赖 `/boot/config.txt` 中的 `dtparam=i2c_arm=on` 与 `i2c-tools`；只读采集，不发送关机/重启指令或安装厂商遥测脚本。电量估计和电流/功率的验证边界见 [UPS 说明](../docs/UPS.md)。

DJI 控制页现提供电话、短信、信号与流量的快捷入口。网页声音断开而 SIM 通话仍活动时，可手动重连音频；此恢复路径还需真实通话复测。功能与界面对照见 [DJI 开源对标](../docs/DJI-BENCHMARK.md)。

## DJI 4G 独立控制页

`/cgi-bin/luci/admin/kkcar_dji` 以同一 OpenWrt 管理员权限提供 DJI 一代 QMI 模块状态。`kkdji.uc` 合并既有 QMI 缓存与经动态 USB 接口发现的 AT 只读数据；模块温度使用 `AT+QTEMP` 第一值，SIM 锁状态使用 `AT+CPIN?`，邻区只输出数量与最强 RSRP，短信仓占用由 `AT+CPMS?` 查询。刷新不会重启网络，重连仅针对 QMI `wan` 逻辑接口。短信中心在树莓派上提供长短信合并、列表搜索与详情，关闭详情清除页面正文；发送及删除必须由用户主动确认。当前设备把新短信保存在 SIM `SM`，树莓派在线时将完整短信加密归档到 SD 卡，并可按开关将正文转发飞书。短信 AT 回复和发送请求只短暂保存在设备私有 `/tmp`，不进入公共备份。VoHive 是运行在 Linux 主机上的独立程序，不会安装在 DJI 模块内部；这里参考其信息架构，仍使用原生 LuCI 和已有路由控制服务。

GNSS 可手动启停并查询位置与速度，但外壳天线及实际定位 fix 尚未验收；只有真实 fix 才显示坐标，默认保持关闭。网页电话已接入模块拨号/接听/挂断控制、USB 音频网关和飞书来电提醒；2026-09-25 同一只 DJI 模块和电信 SIM 的一次网页接听持续约 15–30 秒，双方确认能听见声音。长期通话、出站拨号和移动车载稳定性仍未验收，不能作为紧急联络。eSIM 管理未获支持证据，也不开放。部署时先放齐 `dji-at-status.sh`、`dji-sms.uc`、`dji-control.sh`、`dji-traffic.uc` 与 `dji-traffic-parse.uc`，再安装 RPC、菜单、ACL 与 `dji-console-v2.js`/`dji-console-v2.css`，只刷新 rpcd 和 LuCI 菜单缓存，不重启 network。语音实验另需不在公开仓库内的驱动/辅助程序和 HTTPS 私钥，见 `docs/VOICE-CALLS.md`。设备私有目录只保存流量数字与校正锚点，不保存短信正文。完整边界见公共仓库 `docs/DJI-CONTROL.md`。


网页电话的来话播放新增约 60 ms 缓冲，电话页每 5 秒显示断流和积压丢帧计数；代码模拟通过，真实通话改善尚待复测。遇到声音断续时，比较靠近热点与原位置的计数，并检查树莓派供电与降频状态。此修改只更新页面静态文件，不重启网络或 VPN。

## HDMI 只读状态屏

新增 `root/etc/kk-car/hdmi.uc` 与 `root/etc/init.d/kk-car-hdmi`，直接通过树莓派 legacy framebuffer 显示 VPN 延迟、LTE RSRP、CPU、温度、内存、Wi-Fi 客户端及接口速率，每 5 秒更新。独立于浏览器运行，不修改网络。需要匹配的显示模式，详细部署与撤销见发布仓库 `docs/HDMI.md`。

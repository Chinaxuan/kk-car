# KK-Car 源码

项目介绍见 [仓库首页](../README.md)。

- [使用说明](../docs/USAGE.md)
- [部署与更新](../docs/DEPLOYMENT.md)
- [架构与实现](../docs/ARCHITECTURE.md)
- [验证与限制](../docs/VALIDATION.md)
- [备份与恢复](../docs/BACKUP.md)

`root/` 映射到设备绝对路径；认证资料与实际 UCI 配置不随源码发布。


## HDMI 只读状态屏

新增 `root/etc/kk-car/hdmi.uc` 与 `root/etc/init.d/kk-car-hdmi`，直接通过树莓派 legacy framebuffer 显示 VPN 延迟、LTE RSRP、CPU、温度、内存、Wi-Fi 客户端及接口速率，每 5 秒更新。独立于浏览器运行，不修改网络。需要匹配的显示模式，详细部署与撤销见发布仓库 `docs/HDMI.md`。

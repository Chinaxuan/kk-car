# DJI 4G 控制页：开源功能与界面对标

本页按 2026-09-25 可核对的源码和项目截图整理。目标是把适合车载树莓派的能力做成易用的网页；项目宣传中的“支持”不等于已在 KK-Car 的这只 QDC507 模块上实测。上游项目采用 PolyForm Noncommercial 等许可，KK-Car 只参考交互和技术路径，不直接复制界面素材或源码。

## 参考项目与界面

| 项目 | 查看的来源 | 值得借鉴的界面做法 | 适用边界 |
| --- | --- | --- | --- |
| [DJOneHubNative](https://github.com/cr-zhichen/DJOneHubNative) | [首页截图](https://github.com/cr-zhichen/DJOneHubNative/blob/main/docs/screenshot-home.png)、[语音路由](https://github.com/cr-zhichen/DJOneHubNative/blob/main/backend/cmd/djonehub-macos/module_voice_darwin.go)、[音频桥](https://github.com/cr-zhichen/DJOneHubNative/blob/main/app/Sources/AudioBridge.swift) | 顶部集中显示连接、信号和 SIM 状态；短信、通话、eSIM 分工清楚；通话中有音频重连、设备选择和记录 | 原生 macOS 程序，CoreAudio、系统通知和网络服务排序不能直接移植到 OpenWrt 网页。其文档截至该版本仍把运营商侧双方可听列为待验收 |
| [MaVo](https://github.com/moluncn/mavo) | [主窗口源码](https://github.com/moluncn/mavo/blob/main/Sources/MaVo/MenuContentView.swift)、[语音运行时](https://github.com/moluncn/mavo/blob/main/Sources/MaVo/ModuleVoiceRuntime.swift) | 菜单栏显示最常用的状态；来电独立提示；短信详情、发短信和调试从主视图按需进入 | Mac 菜单栏的尺寸与操作方式不适合照搬到桌面和手机浏览器。用户已用同一只模块与 SIM 实测 MaVo 双向通话 |
| [DJOneHub](https://github.com/ZenGeekLabs/DJOneHub) | [网络卡片截图](https://github.com/ZenGeekLabs/DJOneHub/blob/main/docs/images/network-traffic.png)、[功能说明](https://github.com/ZenGeekLabs/DJOneHub#功能概览) | 运营商、信号、网络、SIM、实时速率在同一行，减少查找成本 | 原版功能说明以短信、eSIM 和网络为主，不能拿它证明双向电话已经实现 |
| [VoHive](https://github.com/iniwex5/vohive-release) 与 [Mac 部署指南](https://github.com/wlzh/dji-4g-vohive-mac) | [功能说明](https://github.com/wlzh/dji-4g-vohive-mac#项目依赖)；对照[社区开源 Web 实现](https://github.com/jikdarren/vohive/tree/main/web/src)中的设备、短信、流量和设置模块 | 多设备列表、短信工作区、独立设置与调试入口；窄屏折叠导航 | 面向多模组与代理池。教程是部署说明，不是原生 Mac 界面；VoWiFi 和代理池不能从宣传列表推断这张国内 SIM 可用 |

### 页面结构对照

| 操作场景 | 参考界面的处理 | KK-Car 的处理与取舍 |
| --- | --- | --- |
| 一眼判断能否联网 | DJOneHubNative 和 DJOneHub 把连接、运营商、信号放在首屏 | 继续显示 SIM、注册、会话、实际上网出口与四项信号，不能只给一个“在线”灯 |
| 快速进入高频任务 | MaVo 菜单栏入口短；VoHive 用导航分开短信和设置 | DJI 独立页改为左侧功能导航、右侧工作区；总览保留电话、短信、信号、套餐实时摘要，手机改用横向导航 |
| 短信阅读 | VoHive 的列表与详情分区，MaVo 按需打开详情 | 现有合并短信列表和详情保留，正文只有点击后读取；后续可再做按联系人会话视图 |
| 来电与声音故障 | MaVo / DJOneHubNative 把通话与音频状态独立呈现 | 电话工作区提供拨号盘、私有通话记录和联系人；音频断开时可手动重连，但不代替真实通话稳定性测试 |
| 专业功能与不支持项 | 参考项目面向不同主机系统，部分还有 eSIM、代理与调试菜单 | 页面将其列为“功能状态”，不为本机未识别的 eSIM、VoWiFi 等放置虚假的可操作按钮 |

## 与 KK-Car 当前能力对照

| 能力 | KK-Car 状态 | 下一步 |
| --- | --- | --- |
| 模块、SIM、蜂窝注册、频段和四项信号 | 已在树莓派网页显示；信号阈值是经验参考 | 保留详细数据，同时在首屏给出简短状态 |
| 路由器出口、VPN 与蜂窝备用 | 已接入车载网络面板 | 保持在路由器侧管理，避免让模块页直接改动网络配置 |
| 短信收发、长短信合并、自动刷新、加密归档、飞书转发 | 已接入；读取详情可能将短信标为已读 | 后续增加会话视图和本地归档检索，先核验原件与归档一致性 |
| 网卡字节和运营商短信校正流量 | 已接入 | 清楚区分设备流量、运营商口径和估算余额 |
| 来电、接听、网页双向语音 | 一通 15–30 秒实机双向通话通过 | 验证多次、出站和长时通话；通话仍在进行时提供手动音频重连 |
| 分机按键、通话记录、音频设备选择 | 尚未接入 | 先做不误拨的 DTMF 与通话记录，再评估浏览器设备选择和回声处理 |
| GPS 位置与速度 | 可手动查询；尚未确认定位成功 | 获得真实卫星定位后再考虑轨迹记录 |
| eSIM / 多卡 | 当前设备未识别可用 eUICC | 检测到相容卡后再开放写入和切换 |
| 多模组与代理池、VoWiFi | 当前车载方案未启用 | 先解决 USB 供电与链路隔离；不把 Mac 专用网络功能直接移植 |

## 本次页面落地

- 在状态概览下加入电话、短信、信号、套餐余额的快捷入口和实时摘要。所有区域仍在同一页面，手机上折为两列。
- 电话和短信仍保留现有完整工作区；用户可从首屏直接跳到目标区域，详细网络数据没有移除。
- 浏览器音频断开但模块通话仍在进行时，显示“连接网页音频”按钮。重连只重建浏览器到树莓派的声音通道，不重新拨号或改蜂窝/VPN 配置；失败后停止自动反复尝试。
- 页面底部的内部竞品术语改为“功能状态”，只反映已接入和未验证的能力。

## 验收边界

本次改动限于页面布局和浏览器音频恢复入口。按钮的静态检查、页面渲染、状态更新和网络连通可独立验证；实际音频重连、长时通话、移动场景与运营商侧结果，必须用真实电话另行验收。任何 eSIM 写入、模块 USB 身份修改或网络出口切换，都不能靠界面对标直接开放。

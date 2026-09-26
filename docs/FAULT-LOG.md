# 每分钟故障记录

`kk-car-diagnostics` 在树莓派上独立运行，每 60 秒将一次运行快照写入 SD 卡。UPS 供电状态改变、连续低电压触发以及手动电源操作会即时追加事件。无需保持管理页或电脑开启。

## 保存什么

- 开机编号、系统时间、单调运行时间、正常关机标记。系统校时可能使时间跳变，排查时同时看运行时间。
- 4G USB 控制接口是否出现、SIM 状态、QMI 采集结果、WAN 初始化/连接状态、数据是否连接。
- RSRP、RSRQ、RSSI、SINR、LTE 频段、模块温度及采样是否新鲜。过期信号记为空，不冒充实时读数。
- 当前上联、VPN 探测延迟和丢包、负载、内存、CPU 温度。
- UPS 外部输入、电池主控与负载电压、估算电流和功率、百分比估计、关机/重启倒计时、软件低电阈值和连续计数。
- 已识别错误的类别与次数：QMI 超时/解析失败、SIM 重置、注册失败、USB 断开/复位、SD 卡异常、内存不足等。

**不保存原始系统日志正文**。日志先在内存中分类，只落盘固定类别与次数；不记录短信正文、号码、SIM/设备序列号、定位/小区标识、公司公网端点、密码、密钥或令牌。错误类别按当前系统日志环形缓冲区计数，缓冲区覆盖时不能保证所有短暂错误均被保留。

## 在哪里查看

私有目录 `/etc/kk-car/private/diagnostics/` 为 0700，文件为 0600，仅管理员可读。主文件为 `faults.jsonl`，每行一条 JSON。每个文件最多 2 MiB，最多主文件加七份轮转，总上限约 16 MiB；保留时长取决于事件数量，不保证固定天数。新记录超过容量时删除最旧轮转。`lifecycle.json` 单独保留上次启动/关机标记。

UPS 页「时钟与硬件诊断」显示记录器是否按时保存、最近一分钟 QMI 错误数和本次启动分区未正常卸载告警数。管理员通过 SSH 可查看详细记录：

```sh
/etc/init.d/kk-car-diagnostics status
cat /tmp/kk-car-diagnostics.json
tail -n 20 /etc/kk-car/private/diagnostics/faults.jsonl
```

`sample` 是每分钟快照；`ups_transition` 是供电/低电状态变化；`low_voltage_shutdown` 保存触发电压与阈值；`power_action` 保存请求；`os_shutdown` 说明正常关机钩子执行；下次 `boot` 的 `previous_clean=false` 表示未记录正常关机，可能为掉电、崩溃或钩子未执行，不能单独判断硬件原因。首次安装的 `previous_clean=null` 没有历史可比。

每次写入刷新文件并请求持久化；若断电留下未完成的最后一行，下次写入前裁去这段残尾，保留此前完整记录。突然断电、SD 卡内部缓存、文件系统损坏仍可能丢失最后一条记录；本功能不是外部独立黑匣子。

## 安装、更新与停用

需要设备已安装 Python 3（此设备电子纸已经使用该运行环境）。复制 `diagnostics.py`、`diagnostic-event.uc` 和 `root/etc/init.d/kk-car-diagnostics`，并同步更新 `ups-control.uc`、`ups-watch.uc`、`kkups.uc` 及 UPS 前端。Python 与 init 文件为 0755，ucode/前端为 0644。

```sh
/etc/init.d/kk-car-diagnostics enable
/etc/init.d/kk-car-diagnostics start
/etc/init.d/kk-car-ups restart
/etc/init.d/rpcd reload
```

更新 `modem-poll.sh`、`modem-qmi-read.sh`、`modem-parse.uc` 后，仅重启 `kk-car-modem`。不重启 network、DHCP、无线或 VPN。WAN 正在 QMI 初始化时，采集器只发现 USB 节点，避免并行查询争用；信号另由共享 AT 锁读取。AT 信号可显示不意味着数据连接成功，页面仍独立显示数据连接状态。信号格由 RSRP 估算。

UPS watcher 启动时，若外部输入存在、没有本次开机显式电源操作、且发现遗留关机倒计时，会尝试取消并读回确认；不在正常运行期间反复取消硬件保护计时，不取消电池供电下的保护倒计时。

将新代码、init 启动链接和私有记录目录加入设备升级保留范围。日志与运行配置只保留本地，**不要上传公开仓库**。停用每分钟采样：

```sh
/etc/init.d/kk-car-diagnostics stop
/etc/init.d/kk-car-diagnostics disable
```

停止周期采样后，UPS 控制/低电事件仍可由事件桥写入；要完全撤销记录功能，需恢复对应 UPS 与模块采集器代码，再移除记录器组件。保留私有历史，不自动删除。

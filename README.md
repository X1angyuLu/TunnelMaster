# TunnelMaster

一个原生的 macOS 菜单栏应用，用自有 WireGuard 服务器处理日常网站分流。打开菜单可以连接、断开、查看实时流量和出口 IP，或编辑域名规则。

| 模式 | 路由 |
| --- | --- |
| 全部代理 | 遵循系统代理的公网连接走 WireGuard 出口，保留局域网直连 |
| 规则分流 | 按自定义域名和可选的中国大陆 IP 规则处理，剩余公网连接走 WireGuard 出口 |

两个模式都使用同一个 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核和同一个 WireGuard 配置。连接后可以直接点选另一种模式，应用会通过私有控制套接字更新规则并保留代理进程和端口。新建连接按更新后的规则路由。规则中的域名也匹配子域名，指定走隧道的域名优先于直连清单。启用中国大陆 IP 规则时，应用会从 [MetaCubeX 数据仓库](https://github.com/MetaCubeX/meta-rules-dat) 下载并缓存 GeoIP 数据。

## 在 Mac 上使用

1. 通过 Homebrew 安装 Mihomo。它作为独立依赖运行。

   ```sh
   brew install mihomo
   ```

2. 构建应用需要 macOS 13 或更高版本和 Swift 5.9 或更高版本的 Xcode 工具链。

   ```sh
   ./scripts/build-app.sh
   ```

3. 打开 `dist/TunnelMaster.app`。在菜单栏点 TunnelMaster，导入已有的 WireGuard `.conf`。
4. 在同时使用同一个节点前，先断开当前的 WireGuard 或其他 VPN。从 TunnelMaster 选择模式并连接。macOS 可能弹出管理员授权。
5. 断开连接或使用菜单里的退出按钮时，应用会尝试恢复当前会话之前的系统代理设置。

此版本使用 macOS 系统代理。覆盖浏览器和遵循系统代理的应用，单独管理连接的应用或 UDP 流量需要其他接管方式。代理设置应用在连接时的主要网络服务上。切换 Wi‑Fi 与有线网络后，先断开再重连。

菜单显示即时速率和本次会话的 60 秒走势。打开「流量历史」可查看过去 24 小时、7 天、30 天、90 天或 1 年的上下行用量、上一周期对比、活动峰值和逐时明细。15 分钟汇总保存在仅当前用户可读取的本机 SQLite 文件中，保留一年。数据来自 Mihomo 接管的流量，覆盖它处理的直连与隧道请求。应用记录用量和活跃连接数的汇总，数据文件无需保存网站或地址。历史记录从支持该功能的版本开始采集。

「流量统计」里的 DigitalOcean 来源读取指定 Droplet 的公网入站和出站速率，同一台服务器上各设备的流量都会计入。连接时输入 Droplet ID 和只勾选 `monitoring:read` 的 DigitalOcean API 令牌，令牌保存在当前 Mac 的钥匙串。图表直接使用 [Monitoring API](https://docs.digitalocean.com/reference/api/reference/monitoring/#get-droplet-bandwidth-metrics) 返回的采样，进出站用量按已覆盖的时段估算。结算用量和团队流量池在 [DigitalOcean Billing](https://cloud.digitalocean.com/account/billing) 查看。

安装应用后，也可以用 `open 'tunnelmaster://statistics/digitalocean'` 打开 DigitalOcean 统计页。

如果程序异常结束，重新打开应用并选择「恢复系统代理」。遇到其他代理应用在会话中修改设置时，TunnelMaster 会保留它修改的代理组。

从源码更新时，构建后运行 `python3 scripts/install-update.py`。安装程序会先验证新版能接管当前 Mihomo，再退出现有界面。当前版本的控制套接字、系统代理或 HTTPS 检查失败时，安装程序会中止交接。

## 本机配置与测试

导入的配置含私钥，存放在当前用户的 Application Support 私有目录，使用仅限当前用户访问的权限。仓库只存源码及使用虚构数据的测试。

```sh
./scripts/test.sh
```

应用使用临时的 Mihomo 配置、仅监听本机的代理端口和独立恢复记录。菜单的出口检测向 Cloudflare 发出请求，用来确认代理走的出口。菜单栏布局参考了 CodexMeter 的交互思路。

## 许可证

TunnelMaster 源码使用 [MIT 许可证](LICENSE)。独立安装的 [Mihomo](https://github.com/MetaCubeX/mihomo) 按其项目许可证分发。

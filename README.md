# TunnelMaster

一个原生的 macOS 菜单栏应用，用自有 WireGuard 服务器处理日常网站分流。打开菜单可以连接、断开、查看实时流量和出口 IP，或编辑域名规则。

| 模式 | 路由 |
| --- | --- |
| 全部代理 | 遵循系统代理的公网连接走 WireGuard 出口，保留局域网直连 |
| 规则分流 | 按自定义域名和可选的中国大陆 IP 规则处理，剩余公网连接走 WireGuard 出口 |

两个模式都使用同一个 [Mihomo](https://github.com/MetaCubeX/mihomo) 内核和同一个 WireGuard 配置。规则中的域名也匹配子域名，指定走隧道的域名优先于直连清单。启用中国大陆 IP 规则时，应用首次连接会从 [MetaCubeX 数据仓库](https://github.com/MetaCubeX/meta-rules-dat) 下载并缓存 GeoIP 数据。

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

菜单显示上传和下载速率、最近 60 秒的走势、本次连接的累计流量、活跃连接数和连接时长。统计包含 Mihomo 处理的直连与隧道流量，通过本机私有套接字读取，历史保存在内存中并在断开后清空。

如果程序异常结束，重新打开应用并选择「恢复系统代理」。遇到其他代理应用在会话中修改设置时，TunnelMaster 会保留它修改的代理组。

## 本机配置与测试

导入的配置含私钥，存放在当前用户的 Application Support 私有目录，使用仅限当前用户访问的权限。仓库只存源码及使用虚构数据的测试。

```sh
./scripts/test.sh
```

应用使用临时的 Mihomo 配置、仅监听本机的代理端口和独立恢复记录。菜单的出口检测向 Cloudflare 发出请求，用来确认代理走的出口。菜单栏布局参考了 CodexMeter 的交互思路。

## 许可证

TunnelMaster 源码使用 [MIT 许可证](LICENSE)。独立安装的 [Mihomo](https://github.com/MetaCubeX/mihomo) 按其项目许可证分发。

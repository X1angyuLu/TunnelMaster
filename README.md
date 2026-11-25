# TunnelMaster

TunnelMaster 是基于 [Clash Verge Rev v2.5.10](https://github.com/clash-verge-rev/clash-verge-rev/releases/tag/v2.5.10) 的开源 macOS 代理客户端。它使用 Mihomo 运行系统代理、TUN、DNS 分流及订阅配置，并在同一个应用中提供本机和服务器侧的流量统计。

## 日常使用

- 在「订阅」中导入 Clash 配置、订阅链接或单个 WireGuard `.conf`。也可一键导入原生 TunnelMaster 保存的 WireGuard 配置和分流偏好。导入的 WireGuard 配置会作为独立条目出现，选中配置后可直接切换规则或全局模式。
- 从 WireGuard 配置卡片打开 TunnelMaster 分流规则，可选默认出口、按大陆 IP 直连及 OpenAI 和 Claude 分流预设。保存活动配置时会验证并应用规则。
- 点击或短暂停留在 macOS 菜单栏地球上可打开用量面板。鼠标悬停图表就能查看明细，点击可固定读数。按 Esc、点击外部或再次点击地球可收起。右键打开代理和模式操作。
- 「流量用量」提供 60 秒实时速率、90 天与一年历史以及同长度上一周期的记录。本机数据由应用后台采集，保留近一年。新版首次打开历史时会从旧版数据库导入已有记录，随后保存在独立数据库。「检测出口 IP」通过当前 Mihomo 规则向 Cloudflare 作一次检测。
- DigitalOcean 统计读取 Droplet 公网出站与入站数据，可切换监控对象。月度出站按 UTC 自然月估算。剩余额度结合套餐和 Droplet 存续时间估算，数据覆盖不足时留空。团队共享池和最终账单以 DigitalOcean 控制台为准。

## DigitalOcean 配置

在「流量用量」页面选择 Droplet，填写包含 `monitoring:read` 的 DigitalOcean 只读 Token。列出该账户所有 Droplet 还需要 `droplet:read`。可以通过 macOS 钥匙串或仅当前用户可读的本地文件保存。已保存的令牌可以直接切换存储方式。已经在旧版使用本地文件的用户可以在设置中导入旧版监控配置。服务器图表可查看每一时段的入站、出站和采样覆盖率。手动刷新会重新查询 DigitalOcean。

DigitalOcean 凭据与流量历史位于新应用的私有存储目录。上游的配置导出及 WebDAV 备份会包含导入的代理配置。因此，包含 WireGuard 私钥的配置导出也应按私钥保管。

## 本地构建

安装本仓库 `rust-toolchain.toml` 指定的 Rust、Node.js 和 pnpm。在 Apple 芯片 Mac 上运行：

```sh
pnpm install --frozen-lockfile
pnpm prebuild aarch64-apple-darwin
pnpm gen:contract
pnpm tauri build --debug --bundles app
```

Intel Mac 将预构建目标改为 `x86_64-apple-darwin`。TUN 使用与新应用同源码构建的 macOS 助手，首次安装需要管理员授权。发行前需要单独配置应用签名、公证及更新源。

托管 macOS 集成测试使用虚拟机及合成配置验证提权助手、TUN 和 DNS，测试路由只覆盖一个文档地址。图表测试在 Chrome 中连接模拟数据。开发时也可以用 `TUNNELMASTER_TEST_CHROME=/path/to/chrome node tests/usage.browser.mjs` 运行图表测试。

## 许可

本分支基于 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 并按 [GPL-3.0](LICENSE) 发布。来自原生 TunnelMaster 的代码和行为测试保留 [MIT 声明](LICENSE.TunnelMaster)。TUN 助手的固定来源和分支变更见 [服务源码说明](vendor/tunnelmaster-service/UPSTREAM.md)。

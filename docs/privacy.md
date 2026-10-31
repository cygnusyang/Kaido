# Kaido Plan 隐私政策 / Privacy Policy

最后更新 / Last updated: 2026-11-01

## 简体中文

Kaido Plan（下称「本应用」）不收集、不存储、不传输任何个人信息。

- **不收集数据**：本应用不含账号系统、行为分析、崩溃上报、广告或第三方 SDK。
- **项目数据留在本地**：你打开和保存的 `.kaido` 文件只存在你选择的位置。本应用不上传、
  不备份、不同步任何项目内容。
- **最近项目**：为了在启动时重新打开上次的项目，本应用在你明确选择文件或文件夹后，
  会为该文件生成一个仅限本应用使用的安全作用域书签（security-scoped bookmark），
  保存在本机偏好设置里。删除「最近项目」或移除授权目录即可清除。
- **MCP 服务（默认关闭）**：你在「项目 ▸ MCP 服务…」中手动开启后，本应用会在
  `127.0.0.1` 上监听一个本地端口，供你在本机运行的 AI 客户端读写同一份计划。
  - 只监听回环地址，不接受来自局域网或互联网的连接；
  - 每个请求必须携带本应用在本机生成、并显示在该面板中的访问令牌；
  - 只有你在该面板中授权的文件夹可被访问，越界请求会被拒绝；
  - 随时关闭开关或重置令牌即可立即中断访问。
- **无第三方共享**：本应用不与任何第三方共享数据，因为不存在可共享的数据。

如对本政策有疑问，请通过项目主页 <https://github.com/cygnusyang/Kaido> 的 Issues 联系。

## English

Kaido Plan ("the app") does not collect, store or transmit any personal information.

- **No data collection**: no accounts, no analytics, no crash reporting, no advertising,
  no third-party SDKs.
- **Project data stays local**: the `.kaido` files you open and save live only where you
  put them. The app never uploads, backs up or syncs project content.
- **Recent projects**: to reopen your last project on launch, the app creates a
  security-scoped bookmark for files or folders you explicitly chose, and keeps it in
  local preferences. Clearing "Recent projects" or removing an authorized folder deletes it.
- **MCP service (off by default)**: when you enable it under Project > MCP Service…, the
  app listens on `127.0.0.1` so a locally running AI client can read and write the same
  plan.
  - loopback only — never the LAN, never the internet;
  - every request must carry a bearer token generated locally and shown in that panel;
  - only folders you authorized in that panel are reachable; anything else is refused;
  - turning the switch off or resetting the token cuts access immediately.
- **No third-party sharing**: there is no data to share.

Questions: open an issue at <https://github.com/cygnusyang/Kaido>.

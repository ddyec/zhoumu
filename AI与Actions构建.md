# AI 排课助理与 GitHub Actions

## 使用

首页右上角的 ✨ 打开 AI 排课助理。在「AI 服务」添加一个或多个端点，选择当前服务后发送请求。

- OpenAI 格式：`https://api.openai.com/v1`，请求发送到 `/chat/completions`。
- Anthropic 格式：`https://api.anthropic.com/v1`，请求发送到 `/messages`。
- 兼容服务填写其 HTTPS Base URL（保留厂商要求的版本路径）或完整接口地址，模型 ID 按厂商提供的名称填写。不支持 HTTP、带查询参数的地址或重定向；请直接填写最终 HTTPS 地址。
- API Key 仅存设备钥匙串。配置多个服务后，点击服务前的圆圈切换；编辑按钮可修改配置，左滑删除会同时删除 Key。

发送时，会把完整课表（含临时例外）、学期参数和当前会话发给你选择的服务。会话只保留在当前页面内；关闭页面取消请求。应用不内置公共 Key，也不需要开发者提供统一 AI 后端。

可以请求：

- “把明天正课第 2 节和第 4 节交换。”
- “2026-11-04 全天调休，正课和晚课都取消。”
- “将 11 月 7 日调整成 11 月 4 日的课程安排。”
- “明天 15:00–16:00 安排班会；如果有课，请先给我调整建议。”

AI 给出方案后，逐项查看日期、原课程、新课程和时间，再点「应用方案」。缺少日期或目标时会先提问；本地校验会拒绝无效日期、重复修改和新增时间重叠。最多修改 200 个格，只支持开学后、距今天一年以内的日期。第 1–12 节之外的事项需要调整到受支持的格。

临时例外按日期保存，不改变常规循环模板。主应用的当天课表、倒计时、实时活动和 iOS 小组件都通过同一课表计算逻辑读取。Apple Watch 当前仍使用原项目的独立课表，不会自动同步 iPhone 的临时安排。

应用后可点「撤销上次应用」。之后再次编辑过课表时，为避免覆盖新改动，请进入「查看 / 撤销指定日期的临时安排」恢复对应日期的常规课表。此列表在重启后仍可使用。原项目的课表编辑器编辑的是常规模板；某日已存在例外时，需要先撤销该日期例外才能看到模板修改。

注意：AI 的语义理解仍需人工检查，尤其是目标格已有课程的移动方案；本地只对有明确起止时间的课程检查时间冲突。没有时间的课程不能保证无冲突。未应用的方案不会写入课表。

## GitHub Actions 构建

工作流：`.github/workflows/ios.yml`（Build iOS）。推送 main 或提交 / 更新 PR 自动校验并构建无签名 IPA。也可以在 Actions → Build iOS → Run workflow 手动构建。

默认主应用 Bundle ID：`com.ddyec.zhoumu.ai`，与上游的 `com.zhoumu.weekdisplay` 不同。手动运行可填写其他 Bundle ID；自动构建也可设置仓库变量 `APP_BUNDLE_ID`。

所有 target 自动派生：

| Target | Bundle ID |
| --- | --- |
| iPhone | `<主ID>` |
| iPhone 小组件 | `<主ID>.widget` |
| Apple Watch | `<主ID>.watchkitapp` |
| Watch 复杂功能 | `<主ID>.watchkitapp.widget` |

四个 target 的 App Group 均为 `group.<主ID>`。改变 Bundle ID 会使用新的数据容器，不会自动迁移上游安装的数据。

### 无证书构建

保留 `signed=false`。构建完成后在该次运行的 Artifacts 下载 `ZhouMu-unsigned-<Bundle ID>`，解压获得 IPA，再用 SideStore / Sideloadly / ESign 等工具重签安装。无签名 IPA 本身不能直接安装；重签需同时处理内嵌小组件、Watch App 和 Watch 扩展。免费账号或重签工具可能不保留 App Group 权限，小组件共享数据会受限制。

### 证书签名构建

需要你自己的 Apple 开发者证书私钥和四份显式 provisioning profiles。项目已移除上游 Team ID，不能用上游身份签名。不要把证书、密码或 API Key 提交到 Git 仓库。

在仓库 Settings → Secrets and variables → Actions 添加：

| Secret | 内容 |
| --- | --- |
| `IOS_CERTIFICATE_P12_BASE64` | 含私钥的 `.p12` 文件的 Base64 |
| `IOS_CERTIFICATE_PASSWORD` | `.p12` 导出密码，允许为空但必须创建 secret |
| `IOS_PROFILES_ZIP_BASE64` | 四份 `.mobileprovision` 打成 ZIP 后的 Base64 |
| `IOS_TEAM_ID` | 自己的 Apple Developer Team ID |

在 Apple Developer 为上表四个 Bundle ID 分别创建显式 App ID，启用并关联 `group.<主ID>` App Group，然后创建与证书、导出方式匹配的四份描述文件。开发/Ad Hoc 分发需注册目标设备（包括需要安装 Watch 版本的设备）。

在 macOS 生成 Base64（复制结果到对应 secret，不要公开）：

```sh
base64 -i signing.p12 | pbcopy
zip profiles.zip *.mobileprovision
base64 -i profiles.zip | pbcopy
```

手动运行工作流，填写匹配描述文件的 Bundle ID，勾选 `signed=true`，选择 `development`、`ad-hoc` 或 `app-store`。脚本检查描述文件的 Team、有效期、Bundle ID 和 App Group，再使用临时钥匙串归档和导出 IPA。证书和安装的描述文件会在作业结束时清理。工作流只导出构建产物，不上传 TestFlight/App Store；`app-store` 产物需要后续按 Apple 的分发流程处理。

没有上述签名 secrets 时，使用无签名构建；选择签名构建会明确报缺少的配置，不会伪造签名。

## 校验

macOS / Xcode 16 或更新版本：

```sh
bash Tools/verify.sh
swiftc Tools/AssistantCheck/main.swift Shared/SemesterCalculator.swift Shared/ScheduleModel.swift Shared/ScheduleOverride.swift ZhouMu/Models/SchedulePlan.swift -o build/assistant-check
build/assistant-check
```

Actions 还会用离线响应样本验证两种协议的 URL、认证头、消息结构、响应解码和截断响应处理，无需真实 API Key。

Actions 还会执行整个 iOS Release 构建，编译内嵌 Watch App 和两种小组件。真实第三方 API 的响应质量及证书签名需使用用户自己的服务配置和证书验证。

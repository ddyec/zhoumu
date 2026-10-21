# 安全策略

## 数据与凭证

常规课表和学期设置保存在设备本地的 App Group，不需要应用账号。
本 fork 的可选 AI 助理会在用户发送消息时，将完整课表、学期参数和当前会话通过 HTTPS 发送给所选 API 服务。请按服务商的政策判断数据处理方式。

API Key 保存在设备钥匙串，使用 `WhenUnlockedThisDeviceOnly`，不写入课表、UserDefaults、仓库或构建产物。端点设置保存在应用本地；删除服务同时删除其 Key。AI HTTP 客户端使用临时会话，不跟随重定向。

AI 输出只生成待确认的方案，本地校验通过后由用户应用。方案可能包含语义错误，用户应核对日期和目标课程。没有明确时间的课程无法做时间冲突检测。

## 报告问题

请勿在公开 issue 中提交 API Key、签名证书、描述文件或包含个人信息的完整课表。
可通过本 fork 的 GitHub 私密漏洞报告功能报告问题（需仓库启用）：

https://github.com/ddyec/zhoumu/security/advisories/new

## 安装与构建

第三方重签工具自行处理其 Apple ID 凭证。证书签名工作流从仓库 Actions secrets 读取证书和描述文件，使用临时钥匙串，并在作业结束时清理签名材料。构建产物不包含用户的 AI Key。

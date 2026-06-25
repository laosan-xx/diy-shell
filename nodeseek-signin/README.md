# NodeSeek 论坛自动签到工具

通过 GitHub Actions 定时执行 NodeSeek 论坛自动签到，支持 Cookie 或账号密码登录，默认随机签到模式。

## 功能特点

- **双登录方式**：支持 Cookie 直接登录 或 账号密码登录
- **Turnstile 自动求解**：账号密码登录通过 patchright 无头浏览器自动求解 Cloudflare Turnstile，**完全免费，无需打码平台**
- **Cloudflare 绕过**：签到请求通过 `curl_cffi` 浏览器 TLS 指纹模拟绕过 Cloudflare 校验
- **随机签到**：默认随机签到模式（1~N 鸡腿），可切换固定签到（鸡腿 x5）
- **多账号支持**：多个账号用 `&` 分隔，自动逐个签到
- **TG 通知**：签到结果通过 Telegram Bot 推送
- **Cookie 自动更新**：账号密码登录后自动将新 Cookie 写回 GitHub 仓库变量
- **失效重试**：Cookie 失效时自动重新登录并重试签到
- **随机延迟**：默认 0~300 秒随机延迟，模拟非准时签到

## 快速开始

### 1. Fork 仓库

将本仓库 Fork 到自己的 GitHub 账号下。

### 2. 配置 Secrets

进入仓库 **Settings → Secrets and variables → Actions → Secrets**，添加以下配置：

#### 必填（二选一）

| 名称 | 说明 |
|------|------|
| `NS_COOKIE` | Cookie 登录方式。浏览器 F12 抓取，多账号用 `&` 分隔 |
| `NS_USERNAME` | 账号密码登录方式。用户名，多账号用 `&` 分隔 |
| `NS_PASSWORD` | 账号密码登录方式。密码，多账号用 `&` 分隔 |

> **两种方式对比：**
>
> | | Cookie 登录 | 账号密码登录 |
> |---|---|---|
> | 依赖 | 仅 `curl_cffi` | 额外需要 `patchright` 浏览器 |
> | Cloudflare | TLS 指纹模拟绕过 | 浏览器自动求解 Turnstile |
> | Cookie 失效 | 需手动更新 | 自动重新登录并更新 |
> | 推荐场景 | 简单稳定，首选 | 需要自动刷新 Cookie 时使用 |

#### 可选：Telegram 通知

| 名称 | 说明 |
|------|------|
| `TG_BOT_TOKEN` | Telegram Bot Token，通过 [@BotFather](https://t.me/BotFather) 创建 |
| `TG_CHAT_ID` | 接收通知的 Chat ID，可通过 [@userinfobot](https://t.me/userinfobot) 获取 |
| `TG_API_URL` | TG API 反代地址，留空默认 `https://api.telegram.org` |

#### 可选：Cookie 自动更新

使用账号密码登录时，如需自动将新 Cookie 写回 GitHub 变量，需配置：

| 名称 | 说明 |
|------|------|
| `GH_PAT` | GitHub Personal Access Token，需 `repo` 权限（不能用默认的 `GITHUB_TOKEN`） |

> 创建路径：GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token，勾选 `repo` scope。

### 3. 配置 Variables（可选）

进入仓库 **Settings → Secrets and variables → Actions → Variables**，添加：

| 名称 | 默认值 | 说明 |
|------|--------|------|
| `NS_RANDOM` | `true` | 签到模式：`true`=随机签到（1~N鸡腿），`false`=固定签到（鸡腿x5） |
| `NS_DELAY` | `0-300` | 签到前随机延迟（秒），格式 `最小-最大`，如 `60-600` |

### 4. 启用 Actions

进入仓库 **Actions** 页面，点击 "I understand my workflows, go ahead and enable them"。

定时任务会自动运行：
- **北京时间 08:00**（UTC 00:00）
- **北京时间 20:00**（UTC 12:00）

也可在 Actions 页面手动触发（workflow_dispatch）。

## 获取 Cookie

1. 打开 [www.nodeseek.com](https://www.nodeseek.com/) 并登录
2. 按 `F12` 打开开发者工具，进入 **Network** 面板
3. 刷新页面，找到任意请求到 `www.nodeseek.com` 的请求
4. 在请求头中找到 `Cookie` 字段，复制完整内容
5. 粘贴到 GitHub Secret `NS_COOKIE` 中

> 多账号示例：`cookie1的完整值&cookie2的完整值&cookie3的完整值`

## 环境变量总览

### Secrets（敏感信息）

| 名称 | 必填 | 说明 |
|------|------|------|
| `NS_COOKIE` | 二选一 | 论坛 Cookie，多账号用 `&` 分隔 |
| `NS_USERNAME` | 二选一 | 论坛用户名，多账号用 `&` 分隔 |
| `NS_PASSWORD` | 二选一 | 论坛密码，多账号用 `&` 分隔 |
| `TG_BOT_TOKEN` | 否 | Telegram Bot Token |
| `TG_CHAT_ID` | 否 | Telegram Chat ID |
| `TG_API_URL` | 否 | Telegram API 反代地址 |
| `GH_PAT` | 否 | GitHub PAT（用于自动更新 Cookie） |

### Variables（非敏感配置）

| 名称 | 默认值 | 说明 |
|------|--------|------|
| `NS_RANDOM` | `true` | 签到模式：`true`=随机，`false`=固定 |
| `NS_DELAY` | `0-300` | 随机延迟范围（秒），格式 `最小-最大` |

## 本地运行

### Cookie 登录方式

```bash
# 安装依赖
pip install -r requirements.txt

# 设置环境变量（PowerShell）
$env:NS_COOKIE="你的cookie值"
$env:NS_DELAY="0"
python nodeseek_sign.py
```

### 账号密码登录方式

```bash
# 安装依赖
pip install -r requirements.txt

# 安装 patchright 浏览器
python -m patchright install chromium

# 设置环境变量（PowerShell）
$env:NS_USERNAME="用户名"
$env:NS_PASSWORD="密码"
$env:NS_DELAY="0"
python nodeseek_sign.py
```

## 定时任务配置

工作流文件位于 `.github/workflows/signin.yml`，默认每天运行两次：

```yaml
schedule:
  - cron: '0 0 * * *'    # UTC 00:00 = 北京时间 08:00
  - cron: '0 12 * * *'   # UTC 12:00 = 北京时间 20:00
```

如需修改时间，编辑 `cron` 表达式即可。注意 GitHub Actions cron 使用 UTC 时区。

## 项目结构

```
nodeseek-signin/
├── .github/
│   └── workflows/
│       └── signin.yml          # GitHub Actions 定时工作流
├── .gitignore
├── nodeseek_sign.py            # 主签到脚本
├── requirements.txt            # Python 依赖
└── README.md                   # 使用文档
```

## 工作原理

### Cookie 登录方式

```
NS_COOKIE → curl_cffi (TLS指纹模拟) → 签到API → 返回结果
```

`curl_cffi` 通过模拟 Chrome 的 TLS 握手指纹绕过 Cloudflare 的 TLS 层校验，直接用 Cookie 调用签到接口。

### 账号密码登录方式

```
patchright 启动无头 Chromium
  → 加载 NodeSeek 登录页
  → Cloudflare Turnstile JS 自动执行并求解
  → 提取 cf-turnstile-response token
  → 在浏览器内调用登录 API（username + password + token + source=turnstile）
  → 登录成功后提取浏览器 Cookie
  → 用 Cookie 调用签到 API
```

`patchright` 是 Playwright 的反检测分支，能通过 Cloudflare 的浏览器指纹检测，让 Turnstile 的 JS 在真实浏览器环境中自动执行求解。**不需要任何第三方打码服务，完全免费。**

## 常见问题

### Q: 签到失败显示 "USER NOT FOUND"？

Cookie 已失效，需要重新获取 Cookie 并更新 `NS_COOKIE`。如果配置了账号密码和 `GH_PAT`，脚本会自动重新登录并更新 Cookie。

### Q: 账号密码登录显示 "Turnstile 验证码求解超时"？

可能是 Cloudflare 检测到自动化行为。尝试：
1. 确认 patchright 浏览器已正确安装：`python -m patchright install chromium`
2. 多运行几次（Turnstile 有时会随机触发人机验证）
3. 改用 Cookie 登录方式

### Q: GitHub Actions 没有自动运行？

- 确认 Actions 已启用
- 确认 Fork 后的仓库有 Actions 页面
- GitHub 对 60 天未活动的仓库会暂停定时任务，偶尔手动触发一次即可

### Q: 如何关闭随机延迟？

设置 `NS_DELAY` 为 `0`。

### Q: 如何同时使用 Cookie 和账号密码？

可以同时配置 `NS_COOKIE` 和 `NS_USERNAME` + `NS_PASSWORD`，脚本会按数量合并账号。当 Cookie 失效时，会自动用对应的账号密码重新登录。

### Q: patchright 和 playwright 有什么区别？

`patchright` 是 `playwright` 的反检测分支，修补了多个被 Cloudflare 检测的指纹特征（如 `navigator.webdriver`、CDP 检测等），能在无头模式下通过 Turnstile 验证。API 完全兼容 playwright。

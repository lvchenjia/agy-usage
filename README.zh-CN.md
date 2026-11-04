# Agy Usage (中文版)

<p align="center">
  <strong>专为 Google Antigravity (AGY) 设计的原生轻量级 macOS 菜单栏工具：实时配额监控、动态 Token 流速分析与远程控制管理。</strong>
</p>

<p align="center">
  <a href="README.md">English</a> •
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/平台-macOS%2013%2B-blue?logo=apple" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/Swift-6.1-F05138?logo=swift&logoColor=white" alt="Swift 6.1" />
  <img src="https://img.shields.io/badge/依赖-零外部依赖-success" alt="Zero Dependencies" />
  <img src="https://img.shields.io/badge/开源协议-MIT-green" alt="MIT License" />
</p>

---

## 项目简介

**Agy Usage** 是一款专为使用 **Google Antigravity (AGY)** 终端 CLI 与 Antigravity IDE 的开发者打造的 macOS 原生常驻菜单栏效率工具。完全基于原生 Swift 与 AppKit 构建，无任何第三方包依赖，运行时零 CPU 占用，内存常驻通常低于 25MB。

它让您在编码时随时掌握 5 小时滚动配额、每周总额度、当前登录的 Google 账号身份、最近实时 Token 生成流速，并可直接在菜单栏一键开关与跳转 Antigravity 远程控制（Remote Control）。

---

## 核心特性

### 1. 极简状态栏常驻显示
* **清爽高可读性字体**：菜单栏采用 14pt Regular Monospaced Digits 纯文本渲染（如 **`G96`**），代表当前 Gemini 模型组的 5 小时滚动剩余配额百分比。
* **远程控制联动标识**：当检测到 Antigravity 远程控制守护进程处于活跃状态时，状态栏自动无缝扩展为 **`G96 R`**；守护进程停止时即刻静默恢复为 **`G96`**。

### 2. Google 账号个人卡片
* **顶部个人中心**：下拉面板最顶层直接展示当前已授权的 Google 用户高清晰度圆形头像（从 base64 自动解码与原生圆角裁剪）。
* **身份与订阅标签**：展示用户名（如 `Alex`）、订阅等级药丸徽标（如 `Google AI Pro`）以及完整邮箱地址（`alex@example.com`）。
* **点击直达**：点击该账号卡片可立即在默认浏览器中打开 Antigravity Web 控制台。

### 3. 双维度双周期配额监控卡片 (5h 滚动 + 每周总限额)
* **独立模型分组**：分别设立 **Gemini Models** 与 **Claude & GPT Models** 两大独立配额卡片。
* **双周期进度条**：
  * **5 小时滚动限额 (5-Hour Rolling Limit)**：平滑全球峰值流量，显示实时百分比与重置倒计时（如 `resets in 4h 55m`）。
  * **每周总额度 (Weekly Limit)**：关联个人订阅总配额，显示周度剩余及完整刷新时间（如 `resets in 5d 21h`）。
* **动态色彩警示**：绿（>50%）、橙（20%~50%）、红（<20%），额度状态一目了然。

### 4. 远程控制深度集成 (Remote Control Hub)
* **操控台快捷入口**：点击 `Open Remote Control Web...` 菜单项直达 `https://antigravity.google.com`。
* **原生守护进程启停**：动态提供 `Start Remote Control`（启动）与 `Stop Remote Control`（停止）操作。
* **耗时过渡与防抖防重复点击**：
  * 启动/停止过程需要与系统 launchd 及守护进程通信，在任务执行中动态展示 **`Starting Remote Control...`** 或 **`Stopping Remote Control...`**；
  * 执行过渡期间**自动禁用点击（Disabled）**，防止快速连击引发后台进程并发冲突或系统端口占用异常。

### 5. 实时 Token 速度与用量仪表盘 (`Cmd + T`)
* **3 分钟实时流速监控**：窗口底栏集成滚动流速指示器：
  * 🟢 **`Live: 44.2 tok/s (3m)`**：代码生成活跃时亮起绿灯，并实时计算最近 3 分钟的输出吞吐速率。
  * `○ Live: Idle`：生成空闲超 3 分钟时自动转为浅灰色静止状态。
  * **综合窗口均速**：同步展示选定时间范围内的综合平均流速 **`Window Avg: 45.8 tok/s`**。
* **多窗口时间筛选**：支持快速切换 **最近 5 分钟**、**1 小时**、**5 小时**、**24 小时**、**7 天** 及 **全部历史**。
* **模型级明细表格**：
  * 统计各模型输入 Token（Input Tokens）、输出 Token（Output Tokens）、总用量（Total Tokens）；
  * 精确统计具备测量耗时的单步输出 Token（Timed Out）与纯净速率（Timed Speed tok/s）、调用次数（Calls）及占比份额（Share %）。
* **WAL-Safe 无锁并发架构**：针对 Antigravity 正在高频写入的 SQLite 会话数据库，采用 URI `mode=ro&immutable=1` 模式连接，杜绝 `SQLITE_CANTOPEN` (14) 锁争用；实现单 step 耗时与 Token 1 对 1 精准对齐，彻底消除历史跨轮次虚高计算缺陷。

---

## 菜单界面布局示意

```
┌──────────────────────────────────────────────┐
│  (头像)    Alex  [Google AI Pro]             │
│            alex@example.com                  │
├──────────────────────────────────────────────┤
│  Gemini Models                               │
│  5h Limit · resets in 4h 55m          99%    │
│  [======================================-]   │
│  Weekly Limit · resets in 5d 21h      92%    │
│  [==================================-----]   │
├──────────────────────────────────────────────┤
│  Claude and GPT models                       │
│  5h Limit · resets in 5h 00m         100%    │
│  [=======================================]   │
│  Weekly Limit · resets in 50m        100%    │
│  [=======================================]   │
├──────────────────────────────────────────────┤
│  Open Remote Control Web...                  │
│  Stop Remote Control                         │
│  Token Usage Dashboard...             ⌘T     │
├──────────────────────────────────────────────┤
│  Auto-Quit if Offline                        │
├──────────────────────────────────────────────┤
│  Refresh                              ⌘R     │
│  Quit                                 ⌘Q     │
└──────────────────────────────────────────────┘
```

---

## 技术架构与设计

1. **纯原生与极小开销**：基于纯 Swift 6.1 + AppKit 原生框架，不引入 Electron、Web 容器或任何臃肿框架，启动时间小于 0.2 秒。
2. **多路端口与 CSRF 智能探测**：自动通过 `lsof` 扫描监听中的 `agy` / `language_server` 进程端口，并从进程参数或 `/tmp/agy_csrf_token` 安全提取鉴权令牌，自适应支持 HTTPS 与 HTTP。
3. **安全线程模型**：所有的网络 RPC 通信、CLI 子命令调用及 SQLite 读写均运行在 Background/Utility 队列，UI 主线程保持 100% 流畅，绝不卡死菜单栏。

---

## 编译与安装

### 系统要求
* macOS 13.0 (Ventura) 或更高版本（支持 Apple Silicon M 系列与 Intel 芯片）
* 已安装 Xcode Command Line Tools（可在终端运行 `xcode-select --install`）

### 编译与一键安装
在项目根目录下直接运行构建脚本：

```bash
./build.sh
```

脚本将自动进行全模块优化编译，生成应用并安装至：
```
/Applications/Agy Usage.app
```

### 启动应用
```bash
open -a "/Applications/Agy Usage.app"
```

启动后即可在 macOS 右上角状态栏看到极简的 `G` 配额图标。

---

## 快捷键一览

| 快捷键 | 功能 | 说明 |
| :--- | :--- | :--- |
| <kbd>⌘</kbd> + <kbd>T</kbd> | **打开统计面板** | 唤起 Token 流速与历史用量分析仪表盘 |
| <kbd>⌘</kbd> + <kbd>R</kbd> | **手动刷新** | 立即重新探测后台 Language Server 并更新配额 |
| <kbd>⌘</kbd> + <kbd>Q</kbd> | **退出应用** | 退出 Agy Usage 常驻程序 |

---

## 设置开机自动启动

### 方法一：终端一行命令设置
```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Agy Usage.app", hidden:false}'
```

### 方法二：macOS 系统设置
1. 打开 **系统设置** → **通用** → **登录项**；
2. 在“登录时打开”列表中点击 **+**，选择 `/Applications/Agy Usage.app` 即可。

---

## Git 提交规范 (Commit Convention)

本项目全面采用符合业界标准的 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 约定式提交规范。详尽的作用域、主题长度与正文说明限制参见 [COMMIT_CONVENTION.md](COMMIT_CONVENTION.md)。

```bash
# 基本格式
<type>(<scope>): <subject>

# 示例
feat(menubar): show 'R' suffix when remote control daemon is running
fix(tokens): resolve SQLite WAL lock contention and speed overcalculation
```

---

## 开源协议

本项目采用 [MIT 许可证](LICENSE)。

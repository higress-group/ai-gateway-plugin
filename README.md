# AI Gateway Management

> 🎮 一个用于管理 Higress AI Gateway 的可视化技能插件，支持主题切换、备份重置、Worker 状态动画和实时监控。

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![HiClaw](https://img.shields.io/badge/HiClaw-Compatible-green.svg)](https://github.com/higress-group/hiclaw)

## ✨ 功能特性

### 🎨 主题切换
- **Pixel** - 经典绿色终端风格
- **Cyber** - 霓虹粉/青赛博朋克风格
- **Office** - 温暖棕色复古办公室风格

### 🤖 Worker 状态动画
像素小人头像实时显示 Worker 状态：
- 🟢 **Idle** - 空闲等待
- 🟡 **Busy** - 正在处理任务
- 🔵 **Sleeping** - 休眠中
- 🔴 **Offline** - 离线

### 💾 备份与重置
- 所有操作前自动创建配置备份
- 一键恢复到上次备份状态
- 备份存储在浏览器 localStorage

### 📊 Pilot-Agent 监控面板
- CPU 使用率
- 内存使用率
- 每分钟请求数 (RPM)
- 活跃连接数

### ⚡ 即时生效
- 模型设置后立即重载配置
- 无需重启容器
- 会话立即应用新模型

## 📦 安装

### 方式一：作为 HiClaw Skill 安装

将此仓库克隆到 Manager 的 skills 目录：

```bash
cd /opt/hiclaw/agent/skills/
git clone https://github.com/nillikechatchat/ai-gateway-management.git
```

运行安装脚本：

```bash
cd ai-gateway-management
bash scripts/install.sh
```

安装脚本会自动：
1. 启动 Monitor API 服务 (端口 18080)
2. 添加 `monitor` 服务来源到 Higress
3. 创建 `/ni_status` 路由
4. 授权 Manager 访问监控接口

### 方式二：手动安装

1. 复制文件到目标位置
2. 启动监控服务：
   ```bash
   bash scripts/monitor-server.sh start
   ```
3. 配置 Higress 路由

## 🚀 使用

### Web UI

访问管理界面：

```
http://manager-local.hiclaw.io:8080
```

### Monitor API

```
http://aigw-local.hiclaw.io:8080/ni_status/
```

### API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/ni_status/metrics` | 获取系统指标 |
| POST | `/ni_status/reload` | 重载配置 |
| GET | `/ni_status/health` | 健康检查 |
| GET | `/ni_status/assignment/manager` | 获取 Manager 模型 |
| PUT | `/ni_status/assignment/manager` | 设置 Manager 模型 |
| GET | `/ni_status/assignment/workers/{name}` | 获取 Worker 模型 |
| PUT | `/ni_status/assignment/workers/{name}` | 设置 Worker 模型 |

## 📁 目录结构

```
ai-gateway-management/
├── SKILL.md                    # 技能文档（Agent 读取）
├── README.md                   # 本文件
├── scripts/
│   ├── install.sh             # 安装脚本
│   ├── monitor-server.sh      # 监控 API 服务
│   ├── set-model.sh           # 设置模型
│   ├── create-provider.sh     # 创建供应商
│   ├── list-providers.sh      # 列出供应商
│   └── get-assignment.sh      # 获取模型分配
├── web/
│   └── index.html             # 管理界面
└── references/
    └── api-reference.md       # API 参考文档
```

## 🛠️ 脚本使用

### 设置模型

```bash
# 设置 Manager 模型
bash scripts/set-model.sh \
  --target manager \
  --provider qwen \
  --model qwen3.5-plus

# 设置 Worker 模型
bash scripts/set-model.sh \
  --target worker:alice \
  --provider deepseek \
  --model deepseek-chat
```

### 列出供应商

```bash
bash scripts/list-providers.sh
```

### 创建供应商

```bash
bash scripts/create-provider.sh \
  --type qwen \
  --name qwen \
  --token "sk-xxx"
```

### 监控服务管理

```bash
# 启动
bash scripts/monitor-server.sh start

# 停止
bash scripts/monitor-server.sh stop

# 状态
bash scripts/monitor-server.sh status

# 重启
bash scripts/monitor-server.sh restart
```

## 📸 截图

### Pixel 主题
经典的绿色终端风格，适合极客和开发者。

### Cyber 主题
霓虹粉/青赛博朋克风格，未来感十足。

### Office 主题
温暖棕色复古办公室风格，舒适的工作氛围。

## 🔧 配置

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MONITOR_PORT` | 18080 | Monitor API 端口 |
| `HICLAW_ADMIN_USER` | admin | Higress 管理员用户名 |
| `HICLAW_ADMIN_PASSWORD` | - | Higress 管理员密码 |
| `HICLAW_MANAGER_GATEWAY_KEY` | - | Manager Gateway Key |

### 模型分配存储

模型分配存储在 MinIO 中：

- Manager: `/agents/manager/model.json`
- Workers: `/agents/{worker-name}/model.json`

格式示例：

```json
{
  "provider": "qwen",
  "model": "qwen3.5-plus",
  "contextWindow": 200000,
  "maxTokens": 64000,
  "reasoning": true,
  "updatedAt": "2024-01-15T10:30:00Z"
}
```

## 🏗️ 架构

```
┌─────────────────────────────────────────────────────────────┐
│                     Higress AI Gateway                       │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Route: /ni_status/* → monitor service (this skill)     ││
│  │  Route: /v1/*         → AI Providers (LLM proxy)        ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │ Manager  │    │ Worker 1 │    │ Worker N │
        │ (model A)│    │ (model B)│    │ (model C)│
        └──────────┘    └──────────┘    └──────────┘
```

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

Apache License 2.0

## 🔗 相关链接

- [HiClaw](https://github.com/higress-group/hiclaw) - Agent Teams 系统
- [Higress](https://github.com/alibaba/higress) - AI Gateway
- [OpenClaw](https://github.com/higress-group/openclaw) - Agent 框架

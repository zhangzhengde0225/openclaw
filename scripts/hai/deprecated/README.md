# HPC 多用户 OpenClaw Docker 部署方案

## 概述

本方案为 HPC 集群环境设计，支持管理员为 50+ 用户部署独立的 OpenClaw 实例。每个用户通过 SLURM 调度获得专属容器，使用 SSH 访问 CLI 和 Web UI 访问网关服务。AI 模型由 HepAI Provider (`https://aiapi.ihep.ac.cn/apiv2`) 提供。

容器启动后，容器内包含预配置的 OpenClaw 环境、软件本体；挂载了用户 HAI 集群 home 目录 `/.hai-openclaw` 作为持久化存储，用户数据和配置保存在其中；默认配置了 HepAI 的 API Key 和模型，用户可根据需要修改配置文件切换模型或调整参数。

用户通过 SSH 登录容器后，可使用 `openclaw` CLI 或 Web UI 访问 OpenClaw 的功能；支持用户更新 API Key、切换模型、管理 Agent 会话等操作。

**核心特性：**
- **Lustre 兼容**：通过动态 UID/GID 匹配解决 `root_squash` 权限问题
- **自动配置**：首次启动时自动从模板生成配置文件，无需手动 `onboard`
- **非 root 运行**：用户以 `clawuser` 身份登录，拥有 passwordless sudo 权限

## 架构特点

- **隔离性**: 每用户独立容器、独立端口、独立 API Key
- **持久化**: 配置和工作区挂载到共享文件系统 (`/aifs`)，容器重启数据不丢失
- **Lustre 兼容**: 容器内用户 UID/GID 动态匹配宿主机用户，绕过 Lustre `root_squash` 限制
- **可扩展**: 端口自动分配 (SSH: `22000+index`, Gateway: `18100+index`)，避免冲突
- **SLURM 集成**: 容器作为 SLURM 作业运行，支持资源配额和时间限制
- **自动配置**: 首次启动时自动从模板生成配置文件，无需手动初始化

## 工作原理

### UID/GID 动态匹配（Lustre root_squash 解决方案）

Lustre 文件系统的 `root_squash` 策略会阻止容器内 root 用户（UID 0）写入挂载的目录。本方案通过动态创建匹配宿主机 UID/GID 的用户来解决：

1. **SLURM 脚本启动时检测**宿主机目录的所有者：
   ```bash
   HOST_UID=$(stat -c '%u' "/aifs/user/home/alice/.hai-openclaw")  # 例如：21927
   HOST_GID=$(stat -c '%g' "/aifs/user/home/alice/.hai-openclaw")  # 例如：600
   ```

2. **环境变量传递给容器**：
   ```bash
   docker run -e HOST_UID=21927 -e HOST_GID=600 ...
   ```

3. **容器入口脚本创建匹配的用户**：
   ```bash
   useradd -u 21927 -g 600 -s /bin/bash clawuser
   ```

4. **结果**：容器内 `clawuser` 的 UID/GID 与宿主机 `alice` 完全一致，可以无缝读写挂载的 Lustre 目录。

### 自动配置初始化

首次启动容器时，如果 `~/.openclaw/openclaw.json` 不存在，入口脚本会自动：

1. 从 `/tmp/openclaw-template.json5` 读取模板
2. 替换 `${HEPAI_API_KEY}` 占位符为实际 API Key
3. 以 `clawuser` 身份复制到 `~/.openclaw/openclaw.json`（绕过 root_squash）

这样用户登录后即可直接使用 `openclaw` 命令，无需手动运行 `openclaw onboard`。

## 用户视角

```bash
# 1. SSH 登录容器
ssh -p 22001 clawuser@<compute-node>

# 2. 容器内使用 CLI
openclaw models list              # 查看可用模型
openclaw send "你好"              # 发送消息
openclaw agent start              # 启动代理会话

# 3. 浏览器访问 Web UI
http://<compute-node>:18101       # Gateway Web 界面
```

## 管理员视角

```bash
# 1. 构建镜像
./hai-admin.sh build

# 2. 注册用户
./hai-admin.sh add-user alice sk-alice-hepai-key-xxx

# 3. 启动容器
./hai-admin.sh start alice

# 4. 查看所有用户状态
./hai-admin.sh status

# 5. 获取用户连接信息
./hai-admin.sh info alice

# 6. 停止容器
./hai-admin.sh stop alice

# 7. 批量操作
./hai-admin.sh start-all          # 启动所有已注册用户
./hai-admin.sh stop-all           # 停止所有运行中的用户
```

## 文件说明

### 核心文件

| 文件 | 用途 |
|------|------|
| `hai-admin.sh` | 管理脚本 (CLI 入口) |
| `Dockerfile.multiuser` | 多用户镜像定义（生成 `hai-openclaw:latest`） |
| `entrypoint-multiuser.sh` | 容器入口脚本（动态创建 UID 匹配的用户，启动 sshd） |
| `openclaw-template.json5` | HepAI 配置模板（首次启动时自动初始化） |
| `users.csv` | 用户注册表（自动维护） |

### users.csv 格式

```csv
username,user_index,hepai_api_key,ssh_port,gateway_port,status,slurm_job_id
alice,1,sk-alice-key,22001,18101,running,12345
bob,2,sk-bob-key,22002,18102,stopped,
```

### 用户持久化目录

每个用户在 `/aifs/user/home/<username>/.hai-openclaw/` 下有如下结构:

```
.hai-openclaw/
├── config/                      # → /home/clawuser/.openclaw (OpenClaw 配置)
│   ├── openclaw.json            # 用户配置文件（自动从模板生成）
│   ├── agents/                  # Agent 会话数据
│   └── credentials/             # 凭证存储
├── workspace/                   # → /home/clawuser/workspace (用户工作区)
├── openclaw-template.json5      # HepAI 配置模板副本（只读）
├── .gateway-token               # Gateway 认证令牌（随机生成）
├── connection-info.txt          # 连接信息（start 后生成）
├── slurm-job.sh                 # SLURM 批处理脚本（自动生成）
├── slurm-<jobid>.out            # SLURM 标准输出
└── slurm-<jobid>.err            # SLURM 错误输出
```

## 部署步骤

### 1. 前置条件

- Docker 已安装且当前用户可运行 `docker` 命令
- SLURM 集群正常工作 (`sbatch`, `squeue`, `scancel` 可用)
- 共享文件系统 `/aifs/user/home` 可被所有计算节点访问
- 用户已在 `/aifs/user/home/<username>/.ssh/` 下准备好 SSH 公钥

### 2. 构建镜像

```bash
cd /path/to/openclaw
./scripts/hai/hai-admin.sh build
```

输出示例:
```
=== Building base openclaw:local image ===
...
=== Building hai-openclaw:latest image ===
...
Build complete.
```

### 3. 注册用户

```bash
./scripts/hai/hai-admin.sh add-user alice sk-alice-hepai-key-xxx
```

执行内容:
- 自动分配 `user_index` (递增)
- 计算端口: SSH = `22001`, Gateway = `18101`
- 创建持久化目录 `/aifs/user/home/alice/.hai-openclaw/`
- 生成随机 gateway token (存储在 `.gateway-token`)
- 写入 `users.csv`

### 4. 启动容器

```bash
./scripts/hai/hai-admin.sh start alice
```

执行流程:
1. 生成 SLURM 批处理脚本 (`slurm-job.sh`)
2. 提交到 SLURM (`sbatch`)
3. 轮询作业状态直到 `RUNNING`
4. 获取分配的计算节点名
5. 生成 `connection-info.txt`

输出示例:
```
========================================
 OpenClaw Connection Info (User: alice)
========================================
SSH Access:     ssh -p 22001 clawuser@compute-03
Web UI:         http://compute-03:18101
Gateway Token:  a1b2c3d4e5f6...
SLURM Job ID:   12345
Compute Node:   compute-03
========================================
```

### 5. 通知用户

将 `connection-info.txt` 内容发送给用户，或者:

```bash
./scripts/hai/hai-admin.sh info alice
```

### 6. 查看状态

```bash
./scripts/hai/hai-admin.sh status
```

输出示例:
```
USERNAME        INDEX  SSH_PORT   GW_PORT    STATUS     NODE            JOB_ID
-------         -----  --------   -------    ------     ----            ------
alice           1      22001      18101      running    compute-03      12345
bob             2      22002      18102      stopped    -               -
charlie         3      22003      18103      running    compute-01      12347
```

### 7. 停止容器

```bash
./scripts/hai/hai-admin.sh stop alice
```

等同于 `scancel <job_id>`，容器立即停止。用户数据保留在持久化目录。

## 配置参数

### 环境变量覆盖

通过环境变量自定义 SLURM 资源和路径:

```bash
# 示例: 使用 GPU 分区并分配更多资源
export HAI_PARTITION=gpu
export HAI_QOS=gpunormal
export HAI_CPUS=8
export HAI_MEM=16G
export HAI_TIME=14-00:00:00  # 14天

./scripts/hai/hai-admin.sh start alice
```

完整参数列表:

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `HAI_HOME_BASE` | `/aifs/user/home` | 用户主目录根路径 |
| `HAI_PARTITION` | `cpu` | SLURM 分区 |
| `HAI_QOS` | `cpunormal` | SLURM QoS |
| `HAI_CPUS` | `4` | 每容器 CPU 核数 |
| `HAI_MEM` | `8G` | 每容器内存 |
| `HAI_TIME` | `7-00:00:00` | SLURM 时间限制 (7天) |
| `HAI_DOCKER_IMAGE` | `hai-openclaw:latest` | Docker 镜像名 |

### 端口分配规则

- **SSH 端口**: `22000 + user_index`
- **Gateway 端口**: `18100 + user_index`

例如 `user_index=1` 的用户:
- SSH: `22001`
- Gateway: `18101`

端口全局唯一，即使多个用户调度到同一节点也不会冲突。

## HepAI 模型配置

`openclaw-template.json5` 中预定义了两个模型:

```json5
{
  models: {
    providers: {
      hepai: {
        baseUrl: "https://aiapi.ihep.ac.cn/apiv2",
        apiKey: "${HEPAI_API_KEY}",  // 从环境变量注入
        models: [
          {
            id: "aliyun/qwen3-max",
            name: "Qwen 3 Max (HepAI)",
            contextWindow: 128000,
            maxTokens: 8192,
          },
          {
            id: "openai/gpt-5",
            name: "GPT-5 (HepAI)",
            contextWindow: 200000,
            maxTokens: 16384,
          },
        ],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: "hepai/aliyun/qwen3-max" },  // 默认模型
    },
  },
}
```

### 添加新模型

编辑 `openclaw-template.json5`，在 `models` 数组中追加:

```json5
{
  id: "zhipu/glm-4-plus",
  name: "GLM-4 Plus (HepAI)",
  reasoning: false,
  input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  contextWindow: 128000,
  maxTokens: 8192,
}
```

重新启动用户容器后生效 (已运行的容器需要 stop 再 start)。

## 用户使用指南

### SSH 连接

用户使用管理员提供的端口和节点名连接：

```bash
ssh -p 22001 clawuser@compute-03
```

**登录信息：**
- **用户名**: `clawuser`（非 root）
- **默认密码**: `openclaw123`
- **首次登录后请立即修改密码**: `passwd`
- **权限**: 拥有 passwordless sudo 权限，需要管理员操作时运行 `sudo <command>`

容器支持密码和公钥两种认证方式。如需配置 SSH 公钥：

```bash
# 登录后
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "your-public-key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

登录成功后，OpenClaw CLI 已全局可用，环境变量和别名已自动加载（通过 `.bash_profile` → `.bashrc`）。

### 验证 UID/GID

登录后可验证容器用户的 UID/GID 是否与宿主机匹配：

```bash
id
# 输出示例: uid=21927(clawuser) gid=600(clawgrp) groups=600(clawgrp)

ls -lnd ~/.openclaw
# 输出示例: drwx------ 2 21927 600 4096 Jan 1 12:00 /home/clawuser/.openclaw
```

如果 UID/GID 匹配，则可以正常读写挂载的 Lustre 目录。

### 常用命令

```bash
# 查看容器资源限制
show_limits

# 查看配置
openclaw config show

# 列出可用模型
openclaw models list

# 切换模型
openclaw models set hepai/openai/gpt-5

# 发送消息 (快速测试)
openclaw send "请用中文介绍量子计算"

# 启动交互式 Agent 会话
openclaw agent start

# 启动 Gateway（前台运行）
openclaw gateway run --bind lan --port 18789

# 使用 pm2 后台运行 Gateway（推荐）
pm2 start openclaw --name gateway -- gateway run --bind lan --port 18789
# 或使用别名
ocl-pm2

# 查看 pm2 进程
pm2 list
pm2 logs gateway  # 查看日志
pm2 stop gateway  # 停止
pm2 restart gateway  # 重启
pm2 delete gateway  # 删除

# 在工作区创建项目
cd ~/workspace
mkdir my-project && cd my-project
openclaw send "帮我创建一个 Python 数据分析脚本"
```

### Web UI 访问

浏览器打开 `http://<compute-node>:<gateway_port>`:

1. 输入 Gateway Token (见 `connection-info.txt`)
2. 进入 Web 界面，可使用图形化聊天、文件上传、会话管理等功能

## 故障排查

### 问题 1: Permission denied 无法写入 `.openclaw` 或 `workspace`

**症状**: 登录后运行 `openclaw` 命令报错：
```
Error: EACCES: permission denied, mkdir '/home/clawuser/.openclaw/agents'
```

**原因**: 容器内 `clawuser` 的 UID/GID 与宿主机目录所有者不匹配，无法通过 Lustre `root_squash` 策略。

**排查**:
1. 检查容器内用户的 UID/GID：
   ```bash
   id  # 应显示与宿主机目录匹配的 UID/GID
   ```

2. 检查宿主机目录的所有者（在登录节点或 SLURM 脚本日志中）：
   ```bash
   stat -c 'UID=%u GID=%g' /aifs/user/home/alice/.hai-openclaw
   ```

3. 检查 SLURM 脚本日志（`slurm-<jobid>.out`）中的 `Detected HOST_UID` 行，应显示正确检测到的 UID/GID。

**解决方案**:
- 如果 UID/GID 不匹配，重新启动容器（会重新检测）：
  ```bash
  ./hai-admin.sh stop alice
  ./hai-admin.sh start alice
  ```

- 如果目录所有者被意外修改，恢复正确的所有权：
  ```bash
  # 在有权限的节点上运行
  sudo chown -R 21927:600 /aifs/user/home/alice/.hai-openclaw
  ```

### 问题 2: SSH 连接失败

### 问题 2: SSH 连接失败

**症状**: `ssh -p 22001 clawuser@compute-03` 连接超时或被拒绝

**排查**:
1. 确认容器正在运行:
   ```bash
   squeue -j <jobid>  # 查看作业状态
   docker ps | grep openclaw-alice  # 在计算节点上检查容器
   ```
2. 检查容器日志:
   ```bash
   tail -f /aifs/user/home/alice/.hai-openclaw/slurm-<jobid>.out
   ```
3. 确认 sshd 已启动:
   ```bash
   docker exec openclaw-alice pgrep sshd
   ```
4. 尝试使用默认密码 `openclaw123` 登录

### 问题 3: Gateway 无法访问

### 问题 3: Gateway 无法访问

**症状**: 浏览器打开 `http://compute-03:18101` 超时

**排查**:
1. 确认容器端口映射正确:
   ```bash
   ssh admin@compute-03 'docker port openclaw-alice'
   ```
   应输出 `18789/tcp -> 0.0.0.0:18101`

2. 检查防火墙规则 (计算节点):
   ```bash
   ssh admin@compute-03 'iptables -L -n | grep 18101'
   ```

3. 查看 gateway 日志:
   ```bash
   tail -f /aifs/user/home/alice/.hai-openclaw/slurm-<jobid>.out
   ```
   应看到 `[entrypoint] Starting OpenClaw gateway on port 18789...`

### 问题 4: 容器启动后立即退出

### 问题 4: 容器启动后立即退出

**症状**: `squeue` 中看不到作业，或作业状态为 `FAILED`

**排查**:
1. 查看 SLURM 错误日志:
   ```bash
   cat /aifs/user/home/alice/.hai-openclaw/slurm-<jobid>.err
   ```

2. 常见原因:
   - Docker 镜像不存在: 重新运行 `hai-admin.sh build`
   - 端口冲突: 检查 `users.csv` 中是否有重复的 `user_index`
   - HepAI API Key 无效: 验证 `users.csv` 中的 `hepai_api_key` 列

3. 手动测试容器启动:
   ```bash
   docker run --rm -it hai-openclaw:latest /bin/bash
   ```

### 问题 5: 用户数据丢失

### 问题 5: 用户数据丢失

**症状**: 重启容器后之前的 Agent 会话或工作区文件不见了

**原因**: 持久化目录未正确挂载

**解决**:
1. 确认挂载路径存在:
   ```bash
   ls /aifs/user/home/alice/.hai-openclaw/config
   ls /aifs/user/home/alice/.hai-openclaw/workspace
   ```

2. 检查 `slurm-job.sh` 中的 `-v` 参数:
   ```bash
   cat /aifs/user/home/alice/.hai-openclaw/slurm-job.sh | grep '\-v'
   ```
   应包含:
   ```
   -v /aifs/user/home/alice/.hai-openclaw/config:/home/clawuser/.openclaw
   -v /aifs/user/home/alice/.hai-openclaw/workspace:/home/clawuser/workspace
   ```

### 问题 6: SLURM 作业长时间 PENDING

### 问题 6: SLURM 作业长时间 PENDING

**症状**: `hai-admin.sh start` 提交作业后一直等待，`squeue` 显示 `PENDING`

**原因**: 集群资源不足或分区/QoS 配置错误

**解决**:
1. 查看作业等待原因:
   ```bash
   squeue -j <jobid> -o "%.18i %.9P %.8j %.8u %.2t %.10M %.10l %.6D %.20R"
   ```
   `NODELIST(REASON)` 列会显示原因 (如 `Resources`, `Priority`, `QOSMaxCpuPerUserLimit`)

2. 调整资源请求:
   ```bash
   export HAI_CPUS=2
   export HAI_MEM=4G
   ./hai-admin.sh start alice
   ```

3. 更改分区:
   ```bash
   export HAI_PARTITION=short
   export HAI_QOS=shortnormal
   ./hai-admin.sh start alice
   ```

### 问题 7: Gateway Token 不匹配

**症状**: Web UI 输入 token 后提示 `Invalid token`

**解决**:
1. 重新生成 token:
   ```bash
   openssl rand -hex 32 > /aifs/user/home/alice/.hai-openclaw/.gateway-token
   ```

2. 重启容器 (重新注入环境变量):
   ```bash
   ./hai-admin.sh stop alice
   ./hai-admin.sh start alice
   ```

3. 查看新的 token:
   ```bash
   ./hai-admin.sh info alice
   ```

## 高级用法

### 批量导入用户

创建用户列表文件 `new_users.txt`:
```
alice sk-alice-key-xxx
bob sk-bob-key-yyy
charlie sk-charlie-key-zzz
```

批量注册:
```bash
while read username apikey; do
  ./hai-admin.sh add-user "$username" "$apikey"
done < new_users.txt
```

批量启动:
```bash
./hai-admin.sh start-all
```

### 自定义容器启动命令

如果需要传递额外的 Docker 参数 (如 `--shm-size`, `--ulimit`)，可以直接编辑用户的 `slurm-job.sh`:

```bash
vi /aifs/user/home/alice/.hai-openclaw/slurm-job.sh
```

在 `docker run` 命令中添加参数后重新提交:
```bash
./hai-admin.sh stop alice
./hai-admin.sh start alice
```

### 监控容器资源使用

在计算节点上:
```bash
ssh compute-03 'docker stats openclaw-alice'
```

输出实时 CPU/内存/网络使用情况。

### 延长 SLURM 作业时间

默认时间限制为 7 天 (`HAI_TIME=7-00:00:00`)。如需延长:

**方法 1**: 重新启动时设置更长时间
```bash
export HAI_TIME=30-00:00:00  # 30天
./hai-admin.sh stop alice
./hai-admin.sh start alice
```

**方法 2**: 使用 `scontrol update` (如果集群支持)
```bash
scontrol update JobId=<jobid> TimeLimit=30-00:00:00
```

## 安全建议

1. **立即修改默认密码**: 所有用户首次登录后应立即运行 `passwd` 修改默认密码 `openclaw123`

2. **SSH 公钥认证（推荐）**: 配置 SSH 公钥后，可编辑 `/etc/ssh/sshd_config` 禁用密码认证：
   ```bash
   sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   sudo pkill -HUP sshd  # 重新加载配置
   ```

3. **限制 sudo 权限（可选）**: 默认 `clawuser` 拥有 passwordless sudo，用于管理容器。如需限制：
   ```bash
   sudo visudo -f /etc/sudoers.d/clawuser
   # 改为需要密码: clawuser ALL=(ALL) ALL
   ```

4. **定期轮换 API Key**: 更新 `users.csv` 中的 `hepai_api_key` 列，然后 stop/start 容器

5. **限制 Gateway Token 暴露**: `connection-info.txt` 包含敏感信息，仅通过安全渠道发送给用户

6. **审计日志**: SLURM 日志 (`slurm-*.out`) 记录所有容器操作和检测到的 UID/GID，定期归档审计

7. **端口防火墙**: 在计算节点上配置 iptables 限制 SSH/Gateway 端口仅从授权网段访问

8. **UID/GID 审计**: 定期检查 SLURM 日志中的 `Detected HOST_UID/HOST_GID` 行，确保与预期一致

## 常见运维任务

### 更新 OpenClaw 版本

1. 拉取最新代码:
   ```bash
   cd /path/to/openclaw
   git pull origin main
   ```

2. 重新构建镜像:
   ```bash
   ./scripts/hai/hai-admin.sh build
   ```

3. 滚动重启用户容器:
   ```bash
   for user in alice bob charlie; do
     echo "Restarting $user..."
     ./scripts/hai/hai-admin.sh stop "$user"
     sleep 2
     ./scripts/hai/hai-admin.sh start "$user"
   done
   ```

### 迁移用户数据

如需将用户从节点 A 迁移到节点 B (不同集群):

1. 在原节点停止容器:
   ```bash
   ./hai-admin.sh stop alice
   ```

2. 打包持久化目录:
   ```bash
   tar czf alice-data.tar.gz /aifs/user/home/alice/.hai-openclaw/
   ```

3. 传输到目标节点并解压到相同路径

4. 在目标节点重新注册并启动:
   ```bash
   ./hai-admin.sh add-user alice sk-alice-key-xxx  # 会跳过已存在的目录
   ./hai-admin.sh start alice
   ```

### 清理旧日志

SLURM 日志会不断累积，定期清理:

```bash
# 删除 30 天前的日志
find /aifs/user/home/*/.hai-openclaw -name "slurm-*.out" -mtime +30 -delete
find /aifs/user/home/*/.hai-openclaw -name "slurm-*.err" -mtime +30 -delete
```

## 参考资料

- [OpenClaw 官方文档](https://docs.openclaw.ai/)
- [Docker 容器网络](https://docs.docker.com/network/)
- [SLURM 作业调度](https://slurm.schedmd.com/quickstart.html)
- [HepAI API 文档](https://aiapi.ihep.ac.cn/docs)

## 联系支持

- **问题反馈**: 在 `scripts/hai/` 目录下创建 `issues.txt` 记录遇到的问题
- **功能建议**: 提交 PR 或联系集群管理员 (zdzhang)

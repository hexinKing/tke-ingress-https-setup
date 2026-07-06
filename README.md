# TKE Ingress HTTPS Setup

将腾讯云 TKE 上 HTTPS Ingress 的端到端配置流程集成到 AI Agent 中，覆盖从证书签发到 DNS 写入的完整链路。

## 解决了什么问题

给一批域名上线 HTTPS，原本需要辗转 4 个系统手工操作：

1. 登录 ITSM 签发 Let's Encrypt 通配证书
2. 登录腾讯云控制台上传证书到 SSL 管理
3. 手动申请 EIP、创建 CLB、写 K8s Secret/Ingress
4. 登录 AWS Route53 添加 A 记录

本工具将以上步骤自动化，你只需准备好域名清单和凭证，跑两条命令即可。

## 目录结构

```
├── shell/                               # 核心脚本
│   ├── sync-cert-from-itsm-to-tencent.sh     # Phase 1: 签发证书并上传腾讯云
│   ├── list-clb-inputs.sh                    # Phase 2: 查询网络参数（只读）
│   ├── create-ingress-and-clb.sh             # Phase 3: 创建 CLB+EIP+Ingress+DNS
│   ├── USAGE.md                              # 详细使用文档
│   ├── template/
│   │   ├── secret.yaml                       # K8s Secret 模板
│   │   ├── ingress.yaml                      # K8s Ingress 模板（HTTPS）
│   │   └── ingress-80.yaml                   # K8s Ingress 模板（HTTP）
│   ├── log/                                  # 运行日志（*.txt 记录成功, *.err 记录失败）
│   └── backup/                               # 历史版本备份
├── python/itsm/                         # Phase 1 依赖的 Python 脚本
│   ├── itsm_session.py                       # ITSM 登录/会话管理
│   ├── call_itsm_2_gen_ssl.py                # 调用 ITSM 签发证书
│   └── call_itsm_2_download_cert.py          # 从内部数据库下载证书
└── SKILL.md                              # AI 助手操作手册
```

---

## 前置条件

以下所有内容只需在**首次使用前**配置一次。

### 运行环境

项目脚本在 **Git Bash**（Windows 自带 `mingw64`）下运行。**不要用 CMD 或 PowerShell**，否则基础命令（awk / tr / sed / grep 等）和 PATH 都可能出问题。

### 1. 安装命令行工具

除 Git Bash 自带的 coreutils 外，还需要手动安装以下工具：

#### jq（JSON 解析器）

```bash
curl -L -o ~/bin/jq.exe https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe
```

#### kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/windows/amd64/kubectl.exe"
mv kubectl.exe ~/bin/kubectl.exe
```

#### tccli（腾讯云 CLI）

```bash
pip install tccli
```

安装后在 `C:\Users\<用户名>\AppData\Local\Programs\Python\Python3xx\Scripts\` 下。

#### aws（AWS CLI）

从 [AWS 官网](https://aws.amazon.com/cli/) 下载 Windows 安装包，默认安装到 `C:\Program Files\Amazon\AWSCLIV2\`。

#### Python3（修复 WindowsApps stub 问题）

Windows 11 的 `python3` 命令指向 App Execution Alias（无权限 stub），需要创建脚本包装：

```bash
rm -f ~/bin/python3.exe ~/bin/python3
echo '#!/bin/bash
/c/Users/hexin/AppData/Local/Programs/Python/Python313/python "$@"' > ~/bin/python3
chmod +x ~/bin/python3
```

> 将路径中的 `hexin` 和 `Python313` 替换为你的实际用户名和 Python 版本号。

#### 验证工具安装

```bash
for c in jq tccli kubectl aws python3; do
    command -v "$c" >/dev/null && echo "$c: ok" || echo "$c: MISSING"
done
```

### 2. 配置 PATH（~/.bashrc）

将自定义工具路径和常用系统路径写入 `~/.bashrc`，确保每次打开 Git Bash 都能找到它们：

```bash
cat > ~/.bashrc <<'EOF'
export PATH="$HOME/bin:$PATH"
export PATH="/c/Users/hexin/AppData/Local/Programs/Python/Python313/Scripts:$PATH"
export PATH="/c/Program Files/Amazon/AWSCLIV2:$PATH"
EOF
source ~/.bashrc
```

### 3. Python 第三方包

Phase 1 的 Python 脚本依赖以下包（连接 ITSM 系统用）：

```bash
pip install mysql-connector-python pymysql requests urllib3 pyOpenSSL PyYAML
```

验证：

```bash
python3 -c "import mysql.connector, pymysql, requests, urllib3, OpenSSL, yaml; print('ok')"
```

### 4. 腾讯云 tccli 凭证

用有权限的 SecretId/SecretKey 创建 profile：

```bash
tccli configure set secretId  --profile adnetwork
tccli configure set secretKey --profile adnetwork
```

配置保存在 `~/.tccli/adnetwork.credential`。验证：

```bash
tccli --profile adnetwork cvm DescribeRegions --output json | jq '.RegionSet[:3]'
```

### 5. ITSM 凭证

创建凭证文件并设置 600 权限（避免明文泄漏）：

```bash
cat > ~/.itsm-creds <<'EOF'
export ITSM_DB_PASSWORD='<MySQL 密码>'
export ITSM_USER='<ITSM 登录用户名>'
export ITSM_PASSWORD='<ITSM 登录密码>'
EOF
chmod 600 ~/.itsm-creds
```

| 变量 | 说明 |
|---|---|
| `ITSM_DB_PASSWORD` | 内部 ops 库 MySQL 密码（host: `10.147.0.9`，database: `ops`） |
| `ITSM_USER` | ITSM 登录用户名（`https://itsm.zhizhengroup.com`） |
| `ITSM_PASSWORD` | ITSM 登录密码 |

如果 MySQL 用户不是默认的 `ops`，需修改两个 Python 文件中的 `user` 字段：
- `python/itsm/call_itsm_2_gen_ssl.py` 第 26 行
- `python/itsm/call_itsm_2_download_cert.py` 第 28 行

### 6. K8s kubeconfig

从腾讯云 TKE 控制台下载对应集群的内网 kubeconfig 文件，然后合并到本地配置：

```bash
# 下载文件通常名为 "cls-xxx-config" 或 "Root Account-kubeconfig"
# 假设下载到 ~/Downloads/ 目录

# 合并到现有 kubeconfig
KUBECONFIG="$HOME/Downloads/<下载的文件名>:$HOME/.kube/config" \
    kubectl config view --flatten > /tmp/merged \
    && mv /tmp/merged ~/.kube/config \
    && chmod 600 ~/.kube/config
```

合并后需要把 context 重命名为脚本要求的格式（`k8s-<context_region>-prod-<project>-tke-1`）：

```bash
# 查看当前有哪些 context
kubectl config get-contexts

# 重命名为脚本要求的名称（以 adnetwork / vg 为例）
kubectl config rename-context <原 context 名> k8s-vg-prod-adnetwork-tke-1
```

验证：

```bash
kubectl config get-contexts k8s-vg-prod-adnetwork-tke-1
```

### 7. AWS CLI 凭证

配置有 Route53 写权限的 Access Key：

```bash
aws configure
```

交互式输入：
- `AWS Access Key ID`: 你的 Access Key
- `AWS Secret Access Key`: 你的 Secret Key
- `Default region name`: `us-east-1`
- `Default output format`: `json`（直接回车）

验证：

```bash
aws sts get-caller-identity
```

确保输出的 Account 下确实有目标域名的 Route53 hosted zone。

---

## 前置条件检查清单

首次配置完成后，逐项验证：

```bash
# 1. 工具
for c in jq tccli kubectl aws python3; do
    command -v "$c" >/dev/null && echo "$c: ok" || echo "$c: MISSING"
done

# 2. Python 依赖
python3 -c "import mysql.connector, pymysql, requests, urllib3, OpenSSL, yaml; print('python deps: ok')"

# 3. 腾讯云
tccli --profile adnetwork cvm DescribeRegions --output json >/dev/null 2>&1 \
    && echo "tccli: ok" || echo "tccli: MISSING"

# 4. ITSM 凭证
source ~/.itsm-creds
[[ -n "$ITSM_DB_PASSWORD" ]] && echo "ITSM_DB_PASSWORD: set" || echo "ITSM_DB_PASSWORD: MISSING"
{ [[ -n "$ITSM_USER" && -n "$ITSM_PASSWORD" ]] || [[ -n "$ITSM_SESSIONID" ]]; } \
    && echo "ITSM login creds: ok" || echo "ITSM login creds: MISSING"

# 5. K8s
kubectl config get-contexts k8s-vg-prod-adnetwork-tke-1 >/dev/null 2>&1 \
    && echo "kube context: ok" || echo "kube context: MISSING"

# 6. AWS
aws sts get-caller-identity >/dev/null 2>&1 && echo "aws: ok" || echo "aws: MISSING"
```

任一项 `MISSING` → 回到对应小节补齐。

---

## 完整发布链路

```
Phase 1  sync-cert    → ITSM 签发通配证书 → 上传腾讯云 SSL
Phase 2  list-clb     → 查 region/VPC/subnet（可选，只读）
Phase 3  create       → 建 EIP+CLB+K8s Secret+Ingress → 写 Route53 A 记录
```

---

### Phase 1 — 签发证书并上传腾讯云

为 apex 域名（如 `example.com`）签发 Let's Encrypt 通配证书（`*.example.com`），下载到本地，上传到腾讯云 SSL 证书管理。

**域名清单文件格式**（仅接受 apex，即 1 个点）：

```text
mybiz.com
otherbiz.com
```

```bash
cd shell
source ~/.itsm-creds
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list /tmp/domains.txt
```

跑完检查结果：

```bash
grep -h '' log/*.err 2>/dev/null || echo '(无错误)'
ls ../certificate/adnetwork/
```

> 腾讯云已存在的证书会自动跳过（幂等）。单个域名失败只写 `log/*.err`，不影响其他域名。
> 签发阶段（call_itsm_2_gen_ssl）默认等 70 秒让 Let's Encrypt 完成签发，如果 DB 迟迟没有记录，手动等几分钟后重跑即可。

---

### Phase 2 — 查询网络参数（可选）

在不确定 region、VPC、子网 ID 时使用，纯只读。

```bash
# 查有哪些 region
./list-clb-inputs.sh --project adnetwork

# 查某 region 下有哪些 VPC + 子网
./list-clb-inputs.sh --project adnetwork --region na-ashburn

# 查某 VPC 下的子网详情
./list-clb-inputs.sh --project adnetwork --region na-ashburn --vpc-id vpc-m7t7q9rf
```

挑选子网时关注 `ZONE`（可用区）和 `AVAIL_IPS`（剩余 IP，<10 建议换一个）。

---

### Phase 3 — 创建基础设施并部署 Ingress

一次完成：申请 EIP → 创建内网 CLB → 绑定 EIP → 建 K8s Secret → 下发 Ingress → 写 Route53 A 记录。

> **执行前必须人工确认。Phase 3 会真实创建云资源和 DNS 记录，不可撤销。**

**域名清单文件格式**（接受 1 或 2 个点）：

```text
# 留空 = 独立新建一套 EIP+CLB
api.example.com

# @group = 同组共用一套新建的 EIP+CLB
www.example.com       @web
m.example.com         @web

# lb-xxxx = 复用已存在的 CLB
static.example.com    lb-abcd1234
```

```bash
cd shell
./create-ingress-and-clb.sh \
    --domain-list /tmp/hosts.txt \
    --project adnetwork \
    --context-region vg \
    --vpc-id vpc-m7t7q9rf \
    --subnet-id subnet-rl7vqmvm \
    --namespace default \
    --svc my-app \
    --port 80 \
    --region na-ashburn
```

跑完检查结果：

```bash
for f in log/*.err; do [[ -s "$f" ]] && { echo "--- $f ---"; cat "$f"; }; done
tail -20 log/route53_changes.log
```

> 如果 Phase 3 跑完后 Route53 报"找不到 hosted zone"，检查 AWS 账号是否正确（`aws sts get-caller-identity`），切换 profile 后可单独补写 DNS 记录。

---

## 日志说明

所有脚本的运行日志在 `shell/log/` 下：

| 文件 | 内容 |
|---|---|
| `create_cert_by_itsm.txt` | 哪些域名发起了签发 |
| `create_cert_by_itsm.err` | 签发失败的域名 |
| `download_cert_from_itsm.err` | 证书下载失败的域名 |
| `upload_cert_to_tencent.err` | 上传腾讯云失败的域名 |
| `create_k8s_secret.txt` | 创建的 K8s Secret |
| `create_k8s_secret.err` | Secret 创建失败 |
| `create_k8s_ingress.txt` | 创建的 Ingress |
| `create_k8s_ingress.err` | Ingress 创建失败 |
| `route53.err` | Route53 写入失败/冲突 |
| `route53_changes.log` | Route53 写入审计记录（append-only，跨次保留） |

每次运行会清空 `*.txt` 和 `*.err`，仅 `route53_changes.log` 保留全部历史。

## 资源命名规则

| 资源 | 独立模式 | group 模式 |
|---|---|---|
| EIP | `eip-ingress-<dashed-domain>` | `eip-ingress-grp-<groupId>` |
| CLB | `clb-<dashed-domain>` | `clb-grp-<groupId>` |
| K8s Secret | `<apex-dashed>-<certId>` | 同左 |
| K8s Ingress | `ingress-<dashed-domain>` | 同左 |

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| 整体退出 0 但有域名未生效 | 单域名失败只写 `*.err` 不阻塞整体 | 跑完必须 grep err |
| `preflight: 域名层级不符合要求` | Phase 1 只接受 apex（1 个点），Phase 3 接受 1~2 个点 | 修正域名清单 |
| `获取 X 证书id失败` | 该 apex 没在腾讯云 SSL 有 Status=1 的证书 | 先跑 Phase 1 |
| Route53 `halt` | 已有 A 记录指向不同 IP 或有 CNAME 冲突 | 人工确认后处理 |
| CLB 创建失败 | 配额/子网 IP 不足/凭证问题 | 查看终端输出 |
| `Access denied for user 'ops'@'...'` | MySQL 用户或密码不匹配 | 检查 `~/.itsm-creds` 和 Python 脚本中的 `user` 字段 |
| Route53 "找不到 hosted zone" | AWS 默认 profile 下没有该域名的 zone | `aws sts get-caller-identity` 确认账号，切换后重试 |
| `command not found: jq/kubectl/python3...` | PATH 未包含 `~/bin` | `source ~/.bashrc` 或重开 Git Bash |
| 下载证书时 DB 暂无记录 | Let's Encrypt 验证需要更多时间 | 等几分钟后重跑脚本 |

# 使用说明

覆盖：
- [`sync-cert-from-itsm-to-tencent.sh`](#sync-cert-from-itsm-to-tencentsh) — 签发证书并同步到腾讯云
- [`list-clb-inputs.sh`](#list-clb-inputssh) — 查 region / VPC / subnet 可选值（create-ingress 入参辅助）
- [`create-ingress-and-clb.sh`](#create-ingress-and-clbsh) — 创建 CLB+EIP+Ingress 并写 Route53 A 记录

完整发布链路：`sync-cert` → （`list-clb-inputs` 查参）→ `create-ingress-and-clb`。

---

## sync-cert-from-itsm-to-tencent.sh

通过内部 ITSM 系统用 Let's Encrypt 签发通配符证书，下载到本地，上传到腾讯云 SSL。

### 1. 命令格式

```bash
cd <workspace>/shell
./sync-cert-from-itsm-to-tencent.sh --project <project> --cert-list <itsm_cert_list_file>
```

| 参数 | 含义 |
|---|---|
| `--project <name>` | 腾讯云 tccli 的 profile 名（对应 `~/.tccli/<name>.credential`） |
| `--cert-list <file>` | 待签发的 apex 域名清单文件路径 |
| `-h`, `--help` | 显示帮助 |

参数支持 `--key value` 与 `--key=value` 两种写法。

### 2. 必需的环境变量

| 变量 | 说明 |
|---|---|
| `ITSM_DB_PASSWORD` | 内部 ops 库 MySQL 密码 |
| `ITSM_USER` + `ITSM_PASSWORD` | ITSM 登录凭证（自动登录路径） |
| **或** `ITSM_SESSIONID` | 手抓的 sessionid（escape hatch，覆盖自动登录） |

### 3. 可选的环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ITSM_CERT_GEN_WAIT_SECONDS` | `70` | 每个域名调 ITSM 后等待签发完成的秒数 |
| `ITSM_SESSION_TTL` | `43200` (12h) | sessionid 本地缓存的安全窗口 |
| `ITSM_BASE_URL` | `https://itsm.zhizhengroup.com` | ITSM 入口 URL |

### 4. 域名清单文件格式

```text
# 注释行（# 开头）跳过
# 空行也跳过
# 必须是 apex（1 个点），违规会让脚本立刻 exit 1

example.com
labelleads.net
otherdomain.com
```

**违规示例**：
- `a.example.com`（2 个点）
- `nodot`（0 个点）
- `a.b.example.com`（3 个点）

行首尾的空白（CRLF/空格/Tab）会被自动清理，不用手动处理。

### 5. 凭证管理的常见姿势

#### 5.1 日常：自动登录 + 12h 缓存

```bash
export ITSM_DB_PASSWORD='...'
export ITSM_USER='...'
export ITSM_PASSWORD='...'
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list ./itsm.txt
```

第一次跑自动登录，sessionid 缓存到 `~/.itsm-session`（权限 0600，12h 内复用）。

#### 5.2 紧急：用手抓的 sessionid 绕过登录

```bash
export ITSM_DB_PASSWORD='...'
export ITSM_SESSIONID='<REDACTED>'
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list ./itsm.txt
```

适用场景：自动登录端点临时挂了 / 凭证不可用 / 一次性应急。

设了 `ITSM_SESSIONID` 时：
- **不写缓存**——临时绕过手段，不污染下一次自动登录路径
- **失效时报错而不是悄悄重登**——保护用户的明确意图

#### 5.3 推荐：`.env` 文件 + source

```bash
cat > ~/.itsm-creds <<'EOF'
export ITSM_DB_PASSWORD='...'
export ITSM_USER='...'
export ITSM_PASSWORD='...'
EOF
chmod 600 ~/.itsm-creds

source ~/.itsm-creds
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list ./itsm.txt
```

`~/.itsm-creds` 加入 `.gitignore` / 不入 git。

### 6. 执行流程

```
preflight_domain_list       ← 校验域名层级，违规 exit 1
   ↓
create_cert_by_itsm         ← 调 ITSM 触发 Let's Encrypt 签发
   ├─ python 检 DB 已有未过期证书 → 退 2 → shell 跳过 sleep
   ├─ DB 没记录 → 调 ITSM /generate/ → 退 0 → sleep 70s 等签发
   └─ 出错 → 退 1 → 写 .err 不 sleep
   ↓
download_cert_from_itsm     ← 从 DB 读 pem/key 写到 ../certificate/<project>/
   ↓
upload_cert_to_tencent      ← tccli 检证书是否已存在；不存在则上传
```

### 7. 输出位置

```
shell/log/
├── create_cert_by_itsm.txt        # 哪些域名发起了签发
├── create_cert_by_itsm.err        # 签发调用失败的
├── download_cert_from_itsm.txt    # 哪些域名下载了
├── download_cert_from_itsm.err    # 下载失败的
└── upload_cert_to_tencent.err     # 上传腾讯云失败的

../certificate/<project>/
├── example.com.pem                # 证书（上传腾讯云时用作 CertificatePublicKey）
└── example.com.key                # 私钥（上传腾讯云时用作 CertificatePrivateKey）

~/.itsm-session                    # sessionid 缓存，权限 0600
```

每次跑前 `*.txt` 会被 `rm -f` 清空。`*.err` 也一样。要看历史得自己留份。

### 8. 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 跑完了（不代表所有域名都成功，需要看 `log/*.err`） |
| `1` | preflight 失败 / 文件不存在 / 其他致命错误 |

**注意**：单个域名的失败不会让脚本退非 0，只写 `log/*.err`。整体退出 0 不等于全部成功，**必须 grep 一下 err 文件**才确定。

### 9. 常见错误

| 报错 | 排查方向 |
|---|---|
| `ITSM_DB_PASSWORD 环境变量未设置` | 漏 export DB 密码 |
| `ITSM_USER 或 ITSM_PASSWORD 环境变量未设置；或通过 ITSM_SESSIONID 直接提供 sessionid` | 自动登录凭证不全；或换用 `ITSM_SESSIONID` |
| `ITSM 登录失败：POST /login/ 状态码 200（期望 302）...` | 凭证密码错 |
| `ITSM_SESSIONID 已失效。请刷新该值，或 unset 以走自动登录。` | escape hatch 模式下手抓的 sid 过期 |
| `preflight: 第 N 行域名层级不符合要求` | 域名清单含非 apex |
| `证书下载失败` | DB 里没找到该域名签好的有效证书（检查 `nginxconf_ssl` 表 `endtime > now()`） |
| `Server Error (500)` 来自 ITSM | 通常是绕开 GET 直接 POST `/login/`；自动登录路径已修过此问题 |

### 10. 完整的"从零跑通"示例

```bash
# 0. 准备凭证文件（一次性）
cat > ~/.itsm-creds <<'EOF'
export ITSM_DB_PASSWORD='<REDACTED>'
export ITSM_USER='<REDACTED>'
export ITSM_PASSWORD='<REDACTED>'
EOF
chmod 600 ~/.itsm-creds

# 1. 准备域名清单
cat > /tmp/itsm-domains.txt <<'EOF'
# 这次要签的域名（apex 形态）
mybiz.com
otherbiz.com
EOF

# 2. 加载凭证 + 切目录
source ~/.itsm-creds
cd /mnt/c/Users/Administrator/Desktop/zzjt/workspace/shell

# 3. 跑
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list /tmp/itsm-domains.txt

# 4. 检查结果
echo "=== 错误检查 ==="
grep -h '' log/*.err 2>/dev/null || echo '(无错误)'
echo ""
echo "=== 已下载的证书 ==="
ls ../certificate/adnetwork/
```

### 11. 测试脚本

`test-pr5.sh` 是 PR-5 ITSM 自动登录功能的集成测试，可独立跑：

```bash
source ~/.itsm-creds
cd <workspace>/shell
./test-pr5.sh
```

参考脚本顶部注释了解测试覆盖范围。

---

## list-clb-inputs.sh

辅助查询脚本：在跑 `create-ingress-and-clb.sh` 之前，用它确认 `--region` / `--vpc-id` / `--subnet-id` 的可选值，避免手抄/猜错 ID。只读，不产生任何变更。

### 1. 命令格式

```bash
cd <workspace>/shell
./list-clb-inputs.sh --project <name> [--region <region>] [--vpc-id <id>]
```

| 参数 | 含义 | 示例 |
|---|---|---|
| `--project <name>` | tccli profile 名（对应 `~/.tccli/<name>.credential`） | `adnetwork` |
| `--region <region>` | 腾讯云 region；不传则只列所有 region | `na-ashburn` |
| `--vpc-id <id>` | 限定 subnet 查询到该 VPC（需与 `--region` 一起用） | `vpc-m7t7q9rf` |
| `-h`, `--help` | 显示帮助 | — |

参数支持 `--key value` 与 `--key=value` 两种写法。

### 2. 必需的环境/凭证

| 资源 | 说明 |
|---|---|
| tccli 凭证 | `~/.tccli/<project>.credential` 配好；脚本只读调用 `vpc DescribeRegions / DescribeVpcs / DescribeSubnets` |
| `jq` | 输出解析依赖 |

### 3. 渐进查询用法

```bash
# 1) 不知道有哪些 region：先看 region 列表
./list-clb-inputs.sh --project adnetwork

# 2) 选定 region 后看该 region 下所有 VPC + subnet
./list-clb-inputs.sh --project adnetwork --region na-ashburn

# 3) 选定 VPC 后只看其下 subnet（含 zone、可用 IP 数）
./list-clb-inputs.sh --project adnetwork --region na-ashburn --vpc-id vpc-m7t7q9rf
```

### 4. 输出说明

- region 列表列：`REGION` / `REGION_NAME` / `STATE`
- VPC 列表列：`VPC_ID` / `VPC_NAME` / `CIDR` / `IS_DEFAULT`
- subnet 列表列：`SUBNET_ID` / `SUBNET_NAME` / `VPC_ID` / `CIDR` / `ZONE` / `AVAIL_IPS`

挑选 subnet 时关注两点：
- `ZONE` — 同 region 内可能跨可用区，CLB 通常单可用区
- `AVAIL_IPS` — 可用 IP 太少时建 CLB 会失败

### 5. 注意事项

- VPC / subnet 查询默认 `--Limit 100`，单 region 资源更多时需要手工分页（脚本目前未做）
- profile 名错或 tccli 凭证缺失，由 tccli 自身报错，脚本不再二次包装
- 输出只供肉眼挑选，**不要 grep 出 ID 直接拼到自动化里**——脚本输出格式可能调整

---

## create-ingress-and-clb.sh

为已签发证书的域名创建腾讯云 CLB + EIP，部署 TKE Ingress，并自动在 AWS Route53 加 A 记录。

### 1. 命令格式

```bash
cd <workspace>/shell
./create-ingress-and-clb.sh \
    --domain-list <file> \
    --project <name> \
    --context-region <region> \
    --vpc-id <id> \
    --subnet-id <id> \
    --namespace <ns> \
    --svc <name> \
    --port <port> \
    --region <region>
```

| 参数 | 含义 | 示例 |
|---|---|---|
| `--domain-list <file>` | 域名清单文件（支持 1 或 2 列）| `./domains.txt` |
| `--project <name>` | tccli profile 名 | `adnetwork` |
| `--context-region <region>` | k8s context 拼接用（`k8s-<region>-prod-<project>-tke-1`）| `vg` / `sg` |
| `--vpc-id <id>` | 腾讯云 VPC ID | `vpc-m7t7q9rf` |
| `--subnet-id <id>` | 腾讯云子网 ID | `subnet-rl7vqmvm` |
| `--namespace <ns>`（别名 `--ns`） | k8s namespace | `default` |
| `--svc <name>` | 后端 Service 名 | `my-app` |
| `--port <port>` | 后端 Service 端口 | `80` |
| `--region <region>` | 腾讯云 region | `na-ashburn` / `ap-singapore` |
| `-h`, `--help` | 显示帮助 | — |

参数支持 `--key value` 与 `--key=value` 两种写法，顺序无关。

### 2. 必需的环境变量

| 变量 | 说明 |
|---|---|
| `tccli` 凭证 | `~/.tccli/<project>.credential` 配好对应 profile |
| `aws` 凭证 | `~/.aws/credentials` 默认 profile 有 Route53 写权限 |
| `kubectl` 凭证 | `~/.kube/config` 中有名为 `k8s-<context_region>-prod-<project>-tke-1` 的 context |

### 3. 可选环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DRY_RUN` | `0` | 设为 `1` 时 Route53 写入只打印不执行（CLB/EIP 仍真做） |

### 4. 域名清单文件格式

```text
# 第一列: host (必须 1 或 2 个点)
# 第二列: 可选，控制 CLB 行为
#   留空        -> 为该域名独立新建 EIP + CLB
#   @<group>    -> 同一 group 的多个域名共用一套新建的 EIP + CLB
#   lb-xxxxxxxx -> 复用已存在的 CLB（脚本会校验存在性并反查其 EIP）

# 1) 独立新建 CLB（无第二列）
api.example.com
admin.example.com

# 2) 同组共用一套新建 CLB（@web 这一组共用）
www.example.com       @web
m.example.com         @web
shop.example.com      @web

# 3) apex 域名（1 个点也合法）
example.com           @web

# 4) 复用已存在的 CLB
static.example.com    lb-abcd1234
cdn.example.com       lb-abcd1234

# 5) 另一个独立 group
api.foo.io            @foo-api
admin.foo.io          @foo-api

# 6) 再来一个 group 共用 CLB（@bar-portal 这一组共用一套新建的 EIP + CLB）
portal.bar.com        @bar-portal
user.bar.com          @bar-portal
help.bar.com          @bar-portal
bar.com               @bar-portal

# 7) lb- 复用已有 CLB（多域名挂到同一个已存在的 CLB 上）
gw.baz.io             lb-1a2b3c4d
api.baz.io            lb-1a2b3c4d
admin.baz.io          lb-1a2b3c4d
baz.io                lb-1a2b3c4d
```

**注意约束**：
- 不允许 `a.b.example.com` 这种 3+ 段域名（preflight 直接 exit 1）
- apex 和子域**共用一张通配证书**（SAN 包 apex），所以 secret 也是共享的——同 apex 下不会重复建 secret

**要点**：
- **列分隔**：用空格或 tab 都行，脚本走 `awk '{print $1}' / '{print $2}'`。
- **层级**：`preflight_domain_list ... "1,2"` 只放行 1 或 2 个点的域名；`a.b.c.example.com`（3 个点）会直接报错退出。
- **Secret/证书匹配**：脚本用域名的最后两段（如 `sub.example.com` → `example.com`）去 `tccli ssl DescribeCertificates` 缓存里找 `Status==1` 的证书，所以腾讯云 SSL 里得有对应 apex 的有效证书（通常是泛域名）。
- **大小写**：host 会被转小写，写大写也没事。
- **注释/空行**：`#` 开头和空行会被跳过。
- **Route53**：每行最后都会拿对应 CLB 的 EIP 写一条 A 记录到 `apex` 所在的 hosted zone；想先演练就 `DRY_RUN=1` 跑一遍。

#### 4.1 各 CLB 模式行为说明

**`@group` 共用新建 CLB**：

- 脚本第一次遇到某个 `@group` 时，调 `create_clb` 新建一套 EIP + CLB，CLB 名字是 `clb-grp-<group>`，EIP 名字是 `eip-ingress-grp-<group>`（label 取自 group 名，不是域名）。
- 后续同组的域名命中 `group_clb[<group>]` 缓存，直接复用，不再新建。
- 每个域名仍然各自创建独立的 K8S Secret 和 Ingress（Ingress 通过注解绑到同一个 `clb_id`），并各自写一条指向同一 EIP 的 Route53 A 记录。

**`lb-` 复用已有 CLB**：

- 脚本对每行执行 `tccli clb DescribeLoadBalancers --LoadBalancerIds '["lb-xxxx"]'` 校验该 CLB 真实存在，不存在就把这一行写进 `log/create_k8s_ingress.err` 跳过，不会新建。
- 然后用 `tccli vpc DescribeAddresses --Filters.0.Name instance-id --Filters.0.Values.0 lb-xxxx` 反查这个 CLB 已绑的 EIP IP，作为 Route53 A 记录目标。**前提是这个 CLB 之前确实绑过 EIP**，否则 `eip_ip` 拿不到，这行会被跳过。
- 不会新申请 EIP，也不会改动这个 CLB 的现有监听器/规则，只是新增 Ingress 通过注解把域名挂上去；每个域名仍然各自建 Secret、各自下发 Ingress、各自写一条指向同一 EIP 的 Route53 A 记录。
- 与 `@group` 不同：`@group` 是"在本次执行内新建并在组内复用"；`lb-` 是"复用执行外早已存在的 CLB"，不要混用同一批 CLB。

### 5. 执行流程

```
preflight_domain_list           ← 校验域名层级（1 或 2 个点）
   ↓
prefetch_certs                  ← 一次性拉取腾讯云证书清单到 /tmp 缓存
   ↓
create_k8s_secret               ← 为每个域名建 k8s secret 关联证书
   ↓
create_k8s_ingress              ← 主体循环：
   ├─ 解析第二列 → 决定 CLB 模式
   │    空      → create_clb 新建 EIP+CLB（label=域名）
   │    @group  → 首位新建（label=grp-<id>）/ 后续复用缓存
   │    lb-xxx  → 校验存在 + 反查关联 EIP IP
   │
   ├─ create_clb 内部：
   │    申请 EIP → 创建 CLB（INTERNAL）→ 绑定 EIP → 查 EIP IP
   │    （CLB 创建失败时自动 ReleaseAddresses 释放 EIP）
   │
   ├─ kubectl apply ingress     ← 渲染模板 + 关联 secret + existLbId
   │
   └─ write_route53_a           ← 4 状态判定：
        无记录       → CREATE A 记录，TTL=300
        同 A 同 IP   → 跳过（幂等）
        A 但值不同   → halt，写 .err，不自动覆盖
        类型冲突     → halt
        多条记录     → halt
```

### 6. 输出位置

```
shell/log/
├── create_k8s_secret.txt        # 创建的 secret
├── create_k8s_secret.err        # 失败的
├── create_k8s_ingress.txt       # 创建的 ingress + clb 关联
├── create_k8s_ingress.err       # 失败的
├── route53.err                  # Route53 失败/halt
└── route53_changes.log          # ★ append-only ★ 所有 Route53 写入审计
```

`route53_changes.log` 跨次运行**保留**，是审计 DNS 变更的依据。其他 `.txt` 每次跑会被 `rm -f` 清空。

### 7. 资源命名规则

| 资源 | 独占模式 | group 模式 |
|---|---|---|
| EIP 名 | `eip-ingress-<dashed-domain>` | `eip-ingress-grp-<groupId>` |
| CLB 名 | `clb-<dashed-domain>` | `clb-grp-<groupId>` |
| k8s secret | `<apex-dashed>-<lowercase-cid>`（数字开头自动加 `wildcard-` 前缀） | 同左 |
| k8s ingress | `ingress-<dashed-domain>` | 同左 |

### 8. DRY_RUN 模式

```bash
DRY_RUN=1 ./create-ingress-and-clb.sh ...
```

效果：
- ✅ Route53 写入只打印 `[DRY-RUN] CREATE A x.example.com -> 1.2.3.4`，不真调 AWS
- ❌ EIP / CLB / k8s secret / k8s ingress 仍真创建（DRY_RUN 当前不覆盖这些）

适合验证 Route53 决策正确（比如确认目标 zone、查冲突）但不真改 DNS。

### 9. 失败语义

整体跑完都是 exit 0，单个域名失败只写到 `*.err` + 跳过该域名继续下一个。**完整跑完后必须 grep `log/*.err`** 才知道哪些域名出问题。

### 10. 完整跑通示例

```bash
cd <workspace>/shell

# 准备域名清单
cat > /tmp/new-domains.txt <<'EOF'
api.mybiz.com    @grpA
img.mybiz.com    @grpA
foo.com
EOF

# DRY_RUN 先验证 Route53 决策
DRY_RUN=1 ./create-ingress-and-clb.sh \
    --domain-list /tmp/new-domains.txt \
    --project adnetwork \
    --context-region vg \
    --vpc-id vpc-m7t7q9rf \
    --subnet-id subnet-rl7vqmvm \
    --namespace default \
    --svc my-app \
    --port 80 \
    --region na-ashburn

# 看一下 log/route53.err 有没有冲突，有就停下处理
[[ -s log/route53.err ]] && cat log/route53.err

# 没问题就真跑
./create-ingress-and-clb.sh \
    --domain-list /tmp/new-domains.txt \
    --project adnetwork \
    --context-region vg \
    --vpc-id vpc-m7t7q9rf \
    --subnet-id subnet-rl7vqmvm \
    --namespace default \
    --svc my-app \
    --port 80 \
    --region na-ashburn

# 检查
echo "=== 错误检查 ==="
for f in log/*.err; do [[ -s "$f" ]] && { echo "--- $f ---"; cat "$f"; }; done
echo ""
echo "=== Route53 写入历史 ==="
tail -20 log/route53_changes.log
```

### 11. 常见错误

| 报错 | 排查方向 |
|---|---|
| `preflight: 域名层级不符合要求` | 域名清单含 `a.b.example.com` 这种 3+ 段域名 |
| `获取 X 证书id失败` | 该 apex 没在腾讯云上传过通配证书；先跑 `sync-cert-from-itsm-to-tencent.sh` |
| `clb创建失败` | tccli 配额/网络/凭证问题；详细错误看终端 stderr |
| `指定的 CLB 不存在: lb-xxx` | 第二列写的 CLB ID 错了或在另一个 region |
| `无法查到 CLB lb-xxx 关联的 EIP IP` | 该 CLB 是 OPEN 类型自带 IP，没绑独立 EIP |
| `Route53: ... 找不到 hosted zone` | apex 的 hosted zone 不在当前 AWS profile 下 |
| `Route53: ... 现有 A 记录 X ≠ 目标 Y, halt` | 旧 A 记录指向其他 IP，需要人工决定是否覆盖 |
| `Route53: ... 已有 CNAME 记录, 类型冲突` | 域名之前用过 CNAME，需先删 |


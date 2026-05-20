---
name: setup-tke-ingress-https
description: 为新域名在腾讯云 TKE 上端到端配置 HTTPS Ingress 的向导。串联本仓库 shell/ 下三个脚本——ITSM 签发通配证书并同步到腾讯云 SSL → 查询 region/VPC/subnet → 创建 EIP+CLB+K8s Secret+Ingress 并写 AWS Route53 A 记录。触发场景示例："给 xxx.com 上线 HTTPS"、"新域名签证书并发布"、"在 TKE 上配 Ingress"、"为这批域名办证书+建 CLB"、"上线域名走完整链路"。任何时候用户提到证书签发、CLB/EIP 创建、TKE Ingress 部署、Route53 写 A 记录中两项或以上的串联操作，都应触发本 skill。
---

# Setup TKE Ingress HTTPS — 完整链路向导

## 何时进入本 skill

用户提到以下任意场景时进入：

- "给一批域名上线 HTTPS"、"新域名走完整发布链路"
- "签证书 + 建 CLB + 发 Ingress"任意组合
- 单步操作但显式提到 `create-ingress-and-clb.sh` / `sync-cert-from-itsm-to-tencent.sh` / `list-clb-inputs.sh`

用户只是想看 region 列表 / 只是想下个证书 / 只是想建个 Ingress 等**纯单步**任务时，也可以入口本 skill，但要明确告知用户只跑哪一段、跳过其余段。

## 关键工作约定

- **工作目录**：所有命令在 `<repo-root>/shell/` 下执行（`cd` 进去再跑），脚本内对 `../python/`、`../certificate/`、`template/`、`log/` 是相对引用。
- **不修改脚本**：本 skill 只调度脚本，不改脚本本身。如发现 bug 先告知用户、让其决策。
- **失败语义**：所有三个脚本整体退出码 0 ≠ 全部成功。单域名失败只写 `log/*.err`。每段跑完**必须**主动 grep `log/*.err` 给用户看，不能装作没事。
- **Phase 3 必须人工确认才执行**：拼好命令、列出将被新建/修改的资源（EIP/CLB/Secret/Ingress/Route53 记录数量与目标 host 清单）后，**停下来等用户显式回复"确认执行"/"go"/"跑"** 之类的肯定答复才真跑。不要默认进入实跑，也不要替用户决定。
- **凭证不要回显到对话**：`ITSM_PASSWORD` / `ITSM_DB_PASSWORD` / `ITSM_SESSIONID` 之类绝不打印或粘贴到响应中；提示用户 `source ~/.itsm-creds` 而不是让其在 prompt 里贴明文。
- **域名层级约束**：`sync-cert` 仅接受 apex（1 个点）；`create-ingress-and-clb` 接受 1 或 2 个点；3+ 段一律拒绝。这是 preflight 硬约束。

## 依赖的命令行工具与环境

依赖矩阵（按脚本拆，按需要补齐工具；从脚本源码反推得到）：

| 工具 | sync-cert | list-clb-inputs | create-ingress-and-clb | 用途 |
|---|---|---|---|---|
| `bash` | ✓ | ✓ | ✓ | 全部脚本宿主 |
| `awk` / `sed` / `tr` / `grep` / `head` / `mktemp` / `printf` / `date` / `sleep` / `mkdir` / `rm` / `cat` | ✓ | ✓ | ✓ | 文本处理 / 临时文件 / 日志（coreutils + busybox 范畴，几乎都默认有） |
| `jq` | ✓ | ✓ | ✓ | 解析 tccli / aws 输出 JSON |
| `tccli` | ✓ | ✓ | ✓ | 腾讯云 CLI（profile: `~/.tccli/<project>.credential`） |
| `python3` | ✓ |  |  | 执行 `../python/itsm/call_itsm_2_*.py` |
| `kubectl` |  |  | ✓ | 操作 k8s，context = `k8s-<context-region>-prod-<project>-tke-1` |
| `aws` |  |  | ✓ | AWS CLI，写 Route53（`route53 list-hosted-zones-by-name` / `list-resource-record-sets` / `change-resource-record-sets`） |

Phase 1 通过 `python3` 调到的 Python 第三方包（在执行 ITSM 调用机器上需要 `pip install` 就位）：

- `mysql-connector-python`（`mysql.connector`）
- `pymysql`
- `requests`、`urllib3`
- `pyOpenSSL`（`OpenSSL`）
- `PyYAML`（`yaml`）

tccli 子命令调用面（仅供 Claude 验证 profile 权限是否够）：

- `ssl DescribeCertificates`、`ssl UploadCertificate`
- `cvm DescribeRegions`
- `vpc DescribeVpcs`、`vpc DescribeSubnets`、`vpc AllocateAddresses`、`vpc DescribeAddresses`、`vpc AssociateAddress`、`vpc ReleaseAddresses`
- `clb CreateLoadBalancer`、`clb DescribeLoadBalancers`

aws 子命令调用面：

- `route53 list-hosted-zones-by-name`
- `route53 list-resource-record-sets`
- `route53 change-resource-record-sets`
- `sts get-caller-identity`（仅用于 Phase 0 自检账号）

### Phase 0 依赖自检（按需挑选执行）

不打印任何凭证内容，只回报 `ok` / `MISSING`：

```bash
# 通用工具
for c in jq tccli kubectl aws python3; do
    command -v "$c" >/dev/null && echo "$c: ok" || echo "$c: MISSING"
done

# Phase 1 Python 依赖
python3 - <<'PY'
import importlib, sys
mods = ["mysql.connector", "pymysql", "requests", "urllib3", "OpenSSL", "yaml"]
miss = [m for m in mods if importlib.util.find_spec(m) is None]
print("python deps:", "ok" if not miss else "MISSING " + ",".join(miss))
PY

# Profile / 凭证（替换 <project> / <context_region>）
ls ~/.tccli/<project>.credential 2>/dev/null || echo "tccli profile MISSING"
aws sts get-caller-identity >/dev/null 2>&1 && echo "aws creds: ok" || echo "aws creds: MISSING"
kubectl config get-contexts k8s-<context_region>-prod-<project>-tke-1 >/dev/null 2>&1 \
    && echo "kube context: ok" || echo "kube context: MISSING"

# Phase 1 ITSM 凭证（任选一种登录方式）
[[ -n "$ITSM_DB_PASSWORD" ]] && echo "ITSM_DB_PASSWORD: set" || echo "ITSM_DB_PASSWORD: MISSING"
{ [[ -n "$ITSM_USER" && -n "$ITSM_PASSWORD" ]] || [[ -n "$ITSM_SESSIONID" ]]; } \
    && echo "ITSM login creds: ok" || echo "ITSM login creds: MISSING"
```

任一项 MISSING → 让用户先补齐再进入对应 Phase。不要替用户绕过。

## 整体链路

```
Phase 0  收集 & 校验基础信息（profile / 域名清单形态 / 目标 region 是否已知 / 凭证就位）
   ↓
Phase 1  sync-cert-from-itsm-to-tencent.sh
         → ITSM 触发签发 → 下载 pem/key → tccli 上传腾讯云 SSL
         （只在腾讯云上还没有该 apex 的有效证书时跑）
   ↓
Phase 2  list-clb-inputs.sh
         → 渐进式查 region / VPC / subnet
         （只在用户不知道这些参数时跑；已知就跳过）
   ↓
Phase 3  拼装完整命令 + 列出将要新建/变更的资源摘要
   ↓
         ⏸  等待用户人工确认（"确认执行" / "go"）
   ↓
         create-ingress-and-clb.sh             ← 实跑
   ↓
         必跑：grep log/*.err；展示 log/route53_changes.log 尾部
```

## Phase 0 — 收集基础信息

按以下顺序问，**问到一个就记一个，不要一次性弹一长串**：

1. **腾讯云 profile 名**（对应 `~/.tccli/<name>.credential`）。常见值如 `adnetwork`。
2. **本次涉及的域名形态**：是只签证书 / 只发 Ingress / 还是端到端？
   - 端到端：需要 apex 清单（给 Phase 1）+ host 清单（给 Phase 3）。两份清单可以不同：apex 清单是要签的根域，host 清单是要发 Ingress 的具体 host（可以是 apex 自己也可以是子域）。
   - 仅 Phase 3：用户应当确认证书在腾讯云 SSL 已存在；否则强烈建议补 Phase 1。
3. **k8s 上下文参数**（仅 Phase 3 需要）：`--context-region`（如 `vg` / `sg`）、`--namespace`、`--svc`、`--port`。
4. **网络参数**（仅 Phase 3 需要）：`--region`、`--vpc-id`、`--subnet-id`。用户不确定后两者 → 进 Phase 2。
5. **依赖与凭证就绪检查**：直接跑上面"Phase 0 依赖自检"那段脚本，逐行报 ok/MISSING。缺啥让用户补啥，**不要替用户硬塞**，也不要回显凭证内容。

## Phase 1 — sync-cert-from-itsm-to-tencent.sh

### 前置确认

- 检查域名清单**只能是 apex（1 个点）**。脚本会 preflight，但提前在 Claude 这边过一遍可以早失败：

  ```bash
  awk 'NF && $1 !~ /^#/ { dots = gsub(/\./, ".", $1); if (dots != 1) print NR": "$1 }' <清单文件>
  ```

  有输出 → 拒绝继续，让用户改清单。

- 主动问用户：是否所有 apex 都希望签**通配证书**？（脚本就是签通配的，不接受裸 apex 单证）

### 调用

```bash
cd <repo>/shell
source ~/.itsm-creds            # 让用户自己 source，不要在 prompt 里收明文
./sync-cert-from-itsm-to-tencent.sh --project <profile> --cert-list <file>
```

如果用户偏好 `ITSM_SESSIONID` 应急路径，按 [`shell/USAGE.md`](../../../shell/USAGE.md) §5.2 走。

### 完成后必跑

```bash
grep -h '' log/create_cert_by_itsm.err log/download_cert_from_itsm.err log/upload_cert_to_tencent.err 2>/dev/null || echo '(无错误)'
ls ../certificate/<project>/
```

把 `*.err` 内容如实展示给用户。任何一条都不要默默吞掉。

### 已签发的跳过

`upload_cert_to_tencent` 内部已用 `tccli ssl DescribeCertificates` 检查 Domain+Status==1；已上传过的会"证书已存在"跳过。这是正常幂等，不要误报。

## Phase 2 — list-clb-inputs.sh

只在用户不确定 region/VPC/subnet 时跑。**纯只读**，可以放心多跑。

### 渐进式三步

```bash
# 1) 不知道 region
./list-clb-inputs.sh --project <profile>

# 2) 已知 region，看 VPC + subnet
./list-clb-inputs.sh --project <profile> --region <region>

# 3) 已知 region+vpc，看 subnet 详情
./list-clb-inputs.sh --project <profile> --region <region> --vpc-id <vpc>
```

### 帮用户挑 subnet

提示用户关注两列：

- `ZONE` — CLB 通常单可用区；多个候选时让用户决定。
- `AVAIL_IPS` — 可用 IP 太少建 CLB 会失败，<10 时主动警告。

**不要**从 `list-clb-inputs.sh` 输出里 grep 出 ID 直接喂给 Phase 3（USAGE.md 明确反对）。让用户**眼挑**或显式确认。

## Phase 3 — create-ingress-and-clb.sh

### 前置确认（必做）

1. **域名清单层级**：1 或 2 个点；3+ 段会 preflight exit 1。

   ```bash
   awk 'NF && $1 !~ /^#/ { dots = gsub(/\./, ".", $1); if (dots < 1 || dots > 2) print NR": "$1 }' <清单文件>
   ```

2. **腾讯云证书就位**：清单每行的 apex（最后两段）必须在腾讯云 SSL 有 Status==1 的证书。可以用一段脚本批量预查：

   ```bash
   awk 'NF && $1 !~ /^#/ {
       n=split($1, p, ".");
       print p[n-1]"."p[n]
   }' <清单文件> | sort -u | while read d; do
       cnt=$(tccli --profile <profile> ssl DescribeCertificates --SearchKey "$d" --output json \
              | jq --arg d "$d" '[.Certificates[] | select(.Domain == $d) | select(.Status == 1)] | length')
       echo "$d  available_certs=$cnt"
   done
   ```

   有 `available_certs=0` 的 → 退回 Phase 1 补签。

3. **第二列语义跟用户对一次**（防止误解）：

   - 留空 = 每行独立新建 EIP+CLB
   - `@<group>` = 同组共用**本次新建**的一套 EIP+CLB
   - `lb-xxxxxxxx` = 复用**已存在**的 CLB（脚本反查它已绑的 EIP IP 用作 Route53 目标）

   引用：[`shell/USAGE.md` §4.1](../../../shell/USAGE.md)。

### 人工确认门（必做，不可跳过）

把完整命令、目标 region/VPC/subnet/context/namespace/svc/port、清单 host 数量、将要创建的 EIP+CLB+Secret+Ingress 数量、以及预计写入的 Route53 记录摘要**一次性发给用户**，然后**停下来等用户显式肯定回复**（"确认"/"go"/"跑"/"yes"）才执行下一步。

- 用户没明确确认前，**不要**调用脚本。
- 用户只回"嗯"/"好的"等模糊回复时，再追问一次"确认实跑吗？"，避免误判。
- 用户要求修改参数或清单 → 改完重新发一次确认摘要，再等确认。

确认摘要示例（参考格式）：

```
即将执行 Phase 3：
  命令：./create-ingress-and-clb.sh --domain-list /tmp/hosts.txt --project adnetwork \
        --context-region vg --vpc-id vpc-m7t7q9rf --subnet-id subnet-rl7vqmvm \
        --namespace default --svc my-app --port 80 --region na-ashburn
  清单 host 数：N（其中独立新建 X 行 / @group Y 行 / 复用 lb- Z 行）
  将新建：EIP × a、CLB × a、Secret × b、Ingress × N
  Route53：将在 hosted zone <zone> 写入 N 条 A 记录指向新 EIP
请回复"确认执行"以继续；或回复具体修改点。
```

### 实跑

收到用户肯定回复后才执行：

```bash
cd <repo>/shell
./create-ingress-and-clb.sh \
    --domain-list <file> \
    --project <profile> \
    --context-region <ctx-region> \
    --vpc-id <vpc> \
    --subnet-id <subnet> \
    --namespace <ns> \
    --svc <svc> \
    --port <port> \
    --region <region>
```

### 完成后必跑

```bash
echo "=== errors ==="
for f in log/*.err; do [[ -s "$f" ]] && { echo "--- $f ---"; cat "$f"; }; done

echo "=== route53 changes ==="
tail -20 log/route53_changes.log
```

`route53_changes.log` 是 append-only DNS 审计文件，**永远展示给用户**作为变更回执。

## 易错点（写给执行此 skill 的 Claude）

1. **不要在 prompt 里要 ITSM 明文密码**。让用户 `source ~/.itsm-creds` 或类似机制；如果他不小心粘了明文，提醒他清屏 + 改密码。
2. **不要 grep `list-clb-inputs.sh` 的输出当数据用**。它是给人看的表格，列宽/排序随时可能调。
3. **Phase 3 一旦执行就会真建资源**（EIP/CLB/Secret/Ingress/Route53 全部真做）。脚本里的 `DRY_RUN` 环境变量仅作用于 Route53，且不再作为本流程的预演步骤。**杜绝"先跑一下看看"思路**——必须用人工确认门拦截，确认后一把过。
4. **`@group` 和 `lb-` 是两种不同语义**：`@group` 是"本次执行内新建并组内共用"，`lb-` 是"复用执行外早已存在的 CLB"。同一批清单**混用同一组 ID** 没意义且会让人误解，发现时主动提醒。
5. **apex 与子域共享 Secret**：脚本拿域名最后两段去匹配腾讯云证书，apex 和其子域命中同一张通配证书 → 同一个 k8s secret 名。这是设计，不是 bug。
6. **不要试图"修一下"重复跑被跳过的域名**。脚本对 secret/ingress/cert 都是幂等跳过，"已存在"就是 OK，不是错误。
7. **Route53 hosted zone 必须在当前 aws CLI 默认 profile 下**。如果用户多 AWS 账号，提前确认 `aws sts get-caller-identity` 是不是对的 account；猜错就会 "找不到 hosted zone"。
8. **CLB 是 `INTERNAL` 类型**（脚本 hardcode）+ 单独申请的 EIP 关联，所以 `lb-` 复用模式下，**那个 CLB 之前必须真绑过 EIP**，否则反查 EIP IP 拿不到，该行会跳过。

## 完整链路调用示例（写给 Claude 内部记忆）

```bash
cd <repo>/shell

# Phase 1
source ~/.itsm-creds
./sync-cert-from-itsm-to-tencent.sh --project adnetwork --cert-list /tmp/apex.txt
grep -h '' log/*.err 2>/dev/null || echo '(Phase 1 无错误)'

# Phase 2（可选）
./list-clb-inputs.sh --project adnetwork --region na-ashburn --vpc-id vpc-m7t7q9rf

# Phase 3 — 先把完整命令 + 资源摘要发给用户，等"确认执行"再继续
# （此处不能直接调用脚本；必须等人工肯定回复后再执行下面这条）

# Phase 3 — 真跑（用户已明确确认后）
./create-ingress-and-clb.sh \
    --domain-list /tmp/hosts.txt \
    --project adnetwork \
    --context-region vg --vpc-id vpc-m7t7q9rf --subnet-id subnet-rl7vqmvm \
    --namespace default --svc my-app --port 80 \
    --region na-ashburn

# 收尾
for f in log/*.err; do [[ -s "$f" ]] && { echo "--- $f ---"; cat "$f"; }; done
tail -20 log/route53_changes.log
```

## 参考文档

- 完整 USAGE：[`shell/USAGE.md`](../../../shell/USAGE.md)
- 各脚本本体：`shell/sync-cert-from-itsm-to-tencent.sh`、`shell/list-clb-inputs.sh`、`shell/create-ingress-and-clb.sh`
- 模板：`shell/template/secret.yaml`、`shell/template/ingress.yaml`

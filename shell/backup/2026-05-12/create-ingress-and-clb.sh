#!/bin/bash

domain_list=$1
project=$2
context_region=$3
VPC_ID=$4
SUBNET_ID=$5
k8s_context=k8s-${context_region}-prod-${project}-tke-1
operation_log_dir=log
ns=$6
svc=$7
port=$8
REGION=$9

if [[ ! -d $operation_log_dir ]];then
mkdir $operation_log_dir
fi

secret_template="template/secret.yaml"
ingress_template="template/ingress.yaml"
cert_cache=""

prefetch_certs() {
    cert_cache=$(mktemp /tmp/tencent-certs.XXXXXX.json)
    trap "rm -f $cert_cache" EXIT
    local total pages offset tmp
    total=$(tccli --profile $project ssl DescribeCertificates --output json | jq -r '.TotalCount')
    pages=$(( (total + 999) / 1000 ))
    offset=0
    tmp=$(mktemp)
    : > "$tmp"
    for ((i=0; i<pages; i++)); do
        tccli --profile $project ssl DescribeCertificates \
            --Offset $offset --Limit 1000 --output json \
            | jq -c '.Certificates[]' >> "$tmp"
        offset=$((offset + 1000))
    done
    jq -s '.' "$tmp" > "$cert_cache"
    rm -f "$tmp"
    echo "已缓存 $(jq 'length' "$cert_cache") 个证书到 $cert_cache" >&2
}

preflight_domain_list() {
    local file=$1
    local expect_dots_csv=$2
    if [[ ! -f "$file" ]]; then
        echo "preflight: 域名列表文件不存在: $file" >&2
        exit 1
    fi
    local has_err=0 line_num=0 d actual
    while IFS= read -r raw; do
        line_num=$((line_num + 1))
        d=$(awk '{print $1}' <<< "$raw" | tr -d '\r\n')
        [[ -z "$d" || "$d" == \#* ]] && continue
        actual=$(awk -F. '{print NF-1}' <<< "$d")
        if [[ ! ",$expect_dots_csv," == *",$actual,"* ]]; then
            echo "preflight: 第 $line_num 行域名层级不符合要求: '$d' (实际 $actual 个点, 期望: $expect_dots_csv)" >&2
            has_err=1
        fi
    done < "$file"
    if [[ "$has_err" -ne 0 ]]; then
        echo "preflight: 域名校验失败，终止" >&2
        exit 1
    fi
}

create_clb() {
DOMAIN=`echo $1|tr '.' '-'`
group=$2
if [[ -n "$group" ]]; then
    label="grp-$group"
else
    label="$DOMAIN"
fi

# 创建EIP
echo "正在创建EIP..." >&2
eip_output=$(tccli --profile=$project  vpc AllocateAddresses --cli-unfold-argument \
  --AddressCount 1 \
  --InternetChargeType TRAFFIC_POSTPAID_BY_HOUR \
  --InternetMaxBandwidthOut 200 \
  --AddressName "eip-ingress-$label" \
  --region $REGION)

eip_id=$(echo $eip_output | jq -r '.AddressSet[0]')

echo "EIP创建成功: ID=$eip_id" >&2

CLB_NAME="clb-$label"

echo "正在创建CLB..." >&2
clb_output=$(tccli --profile=$project clb CreateLoadBalancer --cli-unfold-argument \
  --LoadBalancerType INTERNAL \
  --Forward 1 \
  --VpcId $VPC_ID \
  --SubnetId $SUBNET_ID \
  --LoadBalancerName "$CLB_NAME" \
  --region $REGION)

if [[ $? -ne 0 ]];then
   echo "CLB 创建失败，释放已申请的 EIP $eip_id" >&2
   tccli --profile=$project vpc ReleaseAddresses --cli-unfold-argument \
     --AddressIds $eip_id --region $REGION >&2 || true
   return 1
fi

clb_id=$(echo $clb_output | jq -r '.LoadBalancerIds[0]')

echo "CLB创建成功: ID=$clb_id" >&2

# 等待CLB创建完成
echo "等待CLB创建完成..." >&2
sleep 10

# 绑定EIP到CLB
echo "正在绑定EIP到CLB..." >&2
tccli --profile=$project vpc AssociateAddress --cli-unfold-argument \
  --AddressId $eip_id \
  --InstanceId $clb_id \
  --region $REGION >&2

eip_ip=""
for _ in {1..20}; do
    eip_ip=$(tccli --profile=$project vpc DescribeAddresses --cli-unfold-argument \
      --AddressIds $eip_id --region $REGION --output json \
      | jq -r '.AddressSet[0].AddressIp // empty')
    [[ -n "$eip_ip" && "$eip_ip" != "null" ]] && break
    sleep 3
done

if [[ -z "$eip_ip" || "$eip_ip" == "null" ]]; then
    echo "EIP $eip_id 拿不到 IP 地址" >&2
    return 1
fi
echo "EIP IP: $eip_ip" >&2

echo "$clb_id $eip_ip"
}

write_route53_a() {
    local host=$1
    local target_ip=$2
    local apex zone_id existing count type value change_batch

    # 提取 apex（host 必须是 1 或 2 个点的形态，preflight 已校验）
    local dots=$(awk -F. '{print NF-1}' <<< "$host")
    case "$dots" in
        1) apex="$host" ;;
        2) apex="${host#*.}" ;;
        *) echo "Route53: $host 域名层级异常" >> $operation_log_dir/route53.err; return 1 ;;
    esac

    # 找 hosted zone
    zone_id=$(aws route53 list-hosted-zones-by-name \
        --dns-name "$apex." --max-items 1 \
        --query 'HostedZones[0].Id' --output text 2>/dev/null)
    if [[ -z "$zone_id" || "$zone_id" == "None" ]]; then
        echo "Route53: $host 找不到 $apex 的 hosted zone" >> $operation_log_dir/route53.err
        return 1
    fi

    # 查现状
    existing=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --query "ResourceRecordSets[?Name=='${host}.']" \
        --output json 2>/dev/null)
    count=$(jq 'length' <<<"$existing")

    case "$count" in
        0) ;;  # 无记录，可以 CREATE
        1)
            type=$(jq -r '.[0].Type' <<<"$existing")
            value=$(jq -r '.[0].ResourceRecords[0].Value' <<<"$existing")
            if [[ "$type" != "A" ]]; then
                echo "Route53: $host 已有 $type 记录，类型冲突，halt" >> $operation_log_dir/route53.err
                return 1
            fi
            if [[ "$value" == "$target_ip" ]]; then
                echo "Route53: $host 已是 $target_ip，跳过"
                return 0
            fi
            echo "Route53: $host 现有 A 记录 $value ≠ 目标 $target_ip，halt（不自动覆盖）" >> $operation_log_dir/route53.err
            return 1
            ;;
        *)
            echo "Route53: $host 在 zone 有 $count 条记录，状态异常，halt" >> $operation_log_dir/route53.err
            return 1
            ;;
    esac

    # DRY_RUN 模式：打印不执行
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "[DRY-RUN] Route53 CREATE A $host -> $target_ip (zone=$zone_id)"
        return 0
    fi

    # 实际写入
    change_batch="{\"Changes\":[{\"Action\":\"CREATE\",\"ResourceRecordSet\":{\"Name\":\"${host}.\",\"Type\":\"A\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"$target_ip\"}]}}]}"
    aws route53 change-resource-record-sets \
        --hosted-zone-id "$zone_id" \
        --change-batch "$change_batch" >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') CREATE A $host -> $target_ip zone=$zone_id" >> $operation_log_dir/route53_changes.log
        echo "Route53: $host A记录已创建 → $target_ip"
        return 0
    else
        echo "Route53: $host 写入失败" >> $operation_log_dir/route53.err
        return 1
    fi
}

make_k8s_secret_name() {
    d=`echo $1|awk -F. '{print $(NF-1)"."$(NF)}'`
    d=`echo $d|tr -d '\r\n'`
    cid=$(jq -r --arg name "$d" '.[] | select(.Domain == $name) | select(.Status == 1) | .CertificateId' "$cert_cache" | head -1)
    secret_prefix=`echo $d|tr -d '\r\n'|tr '.' '-'`
    secret_suffix=`echo $cid| tr '[:upper:]' '[:lower:]'`
    secret_name=${secret_prefix}-${secret_suffix}
    echo $secret_name |grep -q '^[0-9]'
    if [[ $? -eq 0 ]];then
    secret_name=wildcard-$secret_name
    fi
    echo "$secret_name $cid"
}

create_k8s_secret() {
create_k8s_secret_file=$operation_log_dir/create_k8s_secret.txt
rm -f $create_k8s_secret_file
while IFS= read -r raw; do
raw=$(echo "$raw" | tr -d '\r\n')
[[ -z "$raw" || "$raw" == \#* ]] && continue
host=$(awk '{print $1}' <<< "$raw")
host=$(echo "$host" | tr '[:upper:]' '[:lower:]')
res=$(make_k8s_secret_name "$host")
echo "Secret名称与证书ID: $res"
secret_name=`echo $res|awk '{print $1}'`
cid=`echo $res|awk '{print $2}'`
if [[ -z $cid ]];then
echo "获取 $host 证书id失败" >> $operation_log_dir/create_k8s_secret.err
continue
fi
if [[ -z $secret_name ]];then
echo "构造 $host 证书secret名称为空" >> $operation_log_dir/create_k8s_secret.err
continue
fi
echo "创建K8S Secret: $secret_name" >> $create_k8s_secret_file
kubectl --context=$k8s_context -n $ns get secret $secret_name
# 相同域名不用创建
if [[ $? -eq 0 ]];then
continue
fi
cat $secret_template | sed -e "s#\$cid#$cid#g" -e "s#\$secret_name#$secret_name#g" -e "s#\$ns#$ns#g" |kubectl --context=$k8s_context -n $ns apply -f -
if [[ $? -ne 0 ]];then
exit 1
fi
echo "Secret $secret_name 已创建."
done < "$domain_list"
}

create_k8s_ingress() {
create_k8s_ingress_file=$operation_log_dir/create_k8s_ingress.txt
declare -A group_clb group_eip
while IFS= read -r raw; do
raw=$(echo "$raw" | tr -d '\r\n')
[[ -z "$raw" || "$raw" == \#* ]] && continue
host=$(awk '{print $1}' <<< "$raw")
col2=$(awk '{print $2}' <<< "$raw")
host=$(echo "$host" | tr '[:upper:]' '[:lower:]')
res=$(make_k8s_secret_name "$host")
secret_name=`echo $res|awk '{print $1}'`
cid=`echo $res|awk '{print $2}'`
if [[ -z $cid ]];then
echo "获取 $host 证书id失败" >> $operation_log_dir/create_k8s_ingress.err
continue
fi
echo "关联Secret: $secret_name"
ingress_name=ingress-`echo $host|tr '.' '-'`
echo "关联K8S Ingress: $ingress_name"

kubectl --context=$k8s_context -n $ns get ingress $ingress_name
if [[ $? -eq 0 ]];then
echo "$ingress_name 这个对象已存在." >> $operation_log_dir/create_k8s_ingress.err
continue
fi

unset clb_id eip_ip
case "$col2" in
    '')
        read -r clb_id eip_ip <<< "$(create_clb "$host")"
        ;;
    @*)
        group="${col2#@}"
        if [[ -n "${group_clb[$group]:-}" ]]; then
            clb_id="${group_clb[$group]}"
            eip_ip="${group_eip[$group]}"
            echo "[group:$group] 复用 CLB $clb_id (EIP $eip_ip)"
        else
            read -r clb_id eip_ip <<< "$(create_clb "$host" "$group")"
            if [[ -n "$clb_id" && -n "$eip_ip" ]]; then
                group_clb[$group]=$clb_id
                group_eip[$group]=$eip_ip
            fi
        fi
        ;;
    lb-*)
        tccli --profile $project clb DescribeLoadBalancers \
            --LoadBalancerIds "[\"$col2\"]" --region $REGION --output json 2>/dev/null \
            | jq -e '.TotalCount > 0' >/dev/null
        if [[ $? -ne 0 ]]; then
            echo "$host: 指定的 CLB 不存在: $col2" >> $operation_log_dir/create_k8s_ingress.err
            continue
        fi
        clb_id="$col2"
        # 反查这个 CLB 关联的 EIP IP
        eip_ip=$(tccli --profile=$project vpc DescribeAddresses --cli-unfold-argument \
            --Filters.0.Name instance-id --Filters.0.Values.0 "$col2" \
            --region $REGION --output json 2>/dev/null \
            | jq -r '.AddressSet[0].AddressIp')
        if [[ -z "$eip_ip" || "$eip_ip" == "null" ]]; then
            echo "$host: 无法查到 CLB $col2 关联的 EIP IP" >> $operation_log_dir/create_k8s_ingress.err
            continue
        fi
        ;;
    *)
        echo "$host: 第二列格式无法识别 '$col2' (期望: 空 / @group / lb-...)" >> $operation_log_dir/create_k8s_ingress.err
        continue
        ;;
esac

if [[ -z $clb_id ]];then
echo "clb创建失败: $host" >> $operation_log_dir/create_k8s_ingress.err
continue
fi
echo "Ingress bind clb: $clb_id, $ingress_name" >> $create_k8s_ingress_file
cat $ingress_template | sed -e "s#\$svc#$svc#g" -e "s#\$port#$port#g" -e "s#\$host#$host#g" -e "s#\$ingress_name#$ingress_name#g" -e "s#\$ns#$ns#g" -e "s#\$secret_name#$secret_name#g" -e "s#\$clb#$clb_id#g"|kubectl --context=$k8s_context -n $ns apply -f -
echo "已完成创建Ingress bind clb: $clb_id, $ingress_name"

# 写 Route53 A 记录
write_route53_a "$host" "$eip_ip"

echo ""
sleep 5
done < "$domain_list"
}

main() {
    preflight_domain_list "$domain_list" "1,2"
    prefetch_certs
    create_k8s_secret
    create_k8s_ingress
}

main
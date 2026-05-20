#!/bin/bash
#
# 列出可作为 create-ingress-and-clb.sh 入参的 region / vpc-id / subnet-id。
#
# 用法（渐进式查询）：
#   1) 列所有 region：
#        ./list-clb-inputs.sh --project <profile>
#   2) 列某 region 的所有 VPC + subnet：
#        ./list-clb-inputs.sh --project <profile> --region <region>
#   3) 限定到某个 VPC 的 subnet：
#        ./list-clb-inputs.sh --project <profile> --region <region> --vpc-id <vpc-id>

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: list-clb-inputs.sh [options]

Required:
  --project <name>     tccli profile 名（对应 ~/.tccli/<name>.credential）

Optional:
  --region <region>    腾讯云 region；不传则列出所有 region
  --vpc-id <id>        限定 subnet 查询到该 VPC；仅与 --region 一起有意义
  -h, --help           显示本帮助
EOF
}

project=""
region=""
vpc_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)    project="$2"; shift 2 ;;
        --project=*)  project="${1#*=}"; shift ;;
        --region)     region="$2"; shift 2 ;;
        --region=*)   region="${1#*=}"; shift ;;
        --vpc-id)     vpc_id="$2"; shift 2 ;;
        --vpc-id=*)   vpc_id="${1#*=}"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "未知参数: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$project" ]]; then
    echo "缺少必填参数: --project" >&2
    usage
    exit 1
fi

if [[ -n "$vpc_id" && -z "$region" ]]; then
    echo "--vpc-id 需要同时指定 --region" >&2
    exit 1
fi

list_regions() {
    echo "== Regions (profile=$project) =="
    printf "%-20s %-30s %s\n" "REGION" "REGION_NAME" "STATE"
    tccli --profile "$project" cvm DescribeRegions --output json \
        | jq -r '.RegionSet[] | [.Region, .RegionName, .RegionState] | @tsv' \
        | awk -F'\t' '{ printf "%-20s %-30s %s\n", $1, $2, $3 }'
}

list_vpcs() {
    local r=$1
    echo "== VPCs (profile=$project, region=$r) =="
    printf "%-20s %-30s %-20s %s\n" "VPC_ID" "VPC_NAME" "CIDR" "IS_DEFAULT"
    tccli --profile "$project" vpc DescribeVpcs --region "$r" --Limit 100 --output json \
        | jq -r '.VpcSet[] | [.VpcId, .VpcName, .CidrBlock, (.IsDefault|tostring)] | @tsv' \
        | awk -F'\t' '{ printf "%-20s %-30s %-20s %s\n", $1, $2, $3, $4 }'
}

list_subnets() {
    local r=$1
    local v=${2:-}
    if [[ -n "$v" ]]; then
        echo "== Subnets (profile=$project, region=$r, vpc=$v) =="
    else
        echo "== Subnets (profile=$project, region=$r, 全部 VPC) =="
    fi
    printf "%-22s %-30s %-20s %-20s %-15s %s\n" "SUBNET_ID" "SUBNET_NAME" "VPC_ID" "CIDR" "ZONE" "AVAIL_IPS"

    local filter_args=()
    if [[ -n "$v" ]]; then
        filter_args+=(--cli-unfold-argument --Filters.0.Name vpc-id --Filters.0.Values "$v")
    fi

    tccli --profile "$project" vpc DescribeSubnets \
        --region "$r" --Limit 100 --output json "${filter_args[@]}" \
        | jq -r '.SubnetSet[] | [.SubnetId, .SubnetName, .VpcId, .CidrBlock, .Zone, (.AvailableIpAddressCount|tostring)] | @tsv' \
        | awk -F'\t' '{ printf "%-22s %-30s %-20s %-20s %-15s %s\n", $1, $2, $3, $4, $5, $6 }'
}

if [[ -z "$region" ]]; then
    list_regions
    cat >&2 <<EOF

提示：选定一个 region 后再跑：
  $0 --project $project --region <REGION>
EOF
    exit 0
fi

list_vpcs "$region"
echo ""
list_subnets "$region" "$vpc_id"

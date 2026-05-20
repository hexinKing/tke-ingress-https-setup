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
## adnetwork
# VPC_ID="vpc-m7t7q9rf"
# SUBNET_ID="subnet-rl7vqmvm"
## ddj
# VPC_ID="vpc-bhr1r65h"
# SUBNET_ID="subnet-on5cvlni"
# 设置区域（根据实际情况修改）
# REGION="na-ashburn"
# REGION="ap-singapore"

if [[ ! -d $operation_log_dir ]];then
mkdir $operation_log_dir
fi

secret_template="template/secret.yaml"
ingress_template="template/ingress.yaml"

create_clb() {
DOMAIN=`echo $1|tr '.' '-'`

# 创建EIP
echo "正在创建EIP..."
# tccli vpc AllocateAddresses --cli-unfold-argument --region na-ashburn --AddressCount 1 --InternetChargeType TRAFFIC_POSTPAID_BY_HOUR --InternetMaxBandwidthOut 10
# eip_output=$(tccli --profile=$project  vpc AllocateAddresses \
#   --AddressCount 1 \
#   --InternetChargeType TRAFFIC_POSTPAID_BY_HOUR \
#   --InternetMaxBandwidthOut 200 \
#   --AddressType EXTERNAL \
#   --Region $REGION)
eip_output=$(tccli --profile=$project  vpc AllocateAddresses --cli-unfold-argument \
  --AddressCount 1 \
  --InternetChargeType TRAFFIC_POSTPAID_BY_HOUR \
  --InternetMaxBandwidthOut 200 \
  --AddressName "eip-ingress-$DOMAIN" \
  --region $REGION)

eip_id=$(echo $eip_output | jq -r '.AddressSet[0]')

echo "EIP创建成功: ID=$eip_id"

# 创建CLB（替换为您的VPC和子网ID）
## adnetwork
# VPC_ID="vpc-m7t7q9rf"
# SUBNET_ID="subnet-rl7vqmvm"
## ddj
# VPC_ID="vpc-bhr1r65h"
# SUBNET_ID="subnet-on5cvlni"
# CLB_NAME="clb-vg-prod-adnetwork-ingress-$DOMAIN"
CLB_NAME="clb-$DOMAIN"

echo "正在创建CLB..."
# tccli --profile=$project clb CreateLoadBalancer --cli-unfold-argument --region na-ashburn --LoadBalancerType OPEN --Forward 1 --LoadBalancerName test --VpcId vpc-m7t7q9rf --SubnetId subnet-rl7vqmvm
clb_output=$(tccli --profile=$project clb CreateLoadBalancer --cli-unfold-argument \
  --LoadBalancerType INTERNAL \
  --Forward 1 \
  --VpcId $VPC_ID \
  --SubnetId $SUBNET_ID \
  --LoadBalancerName "$CLB_NAME" \
  --region $REGION)

if [[ $? -ne 0 ]];then
   return
fi

clb_id=$(echo $clb_output | jq -r '.LoadBalancerIds[0]')

echo "CLB创建成功: ID=$clb_id"

# 等待CLB创建完成
echo "等待CLB创建完成..."
sleep 10

# 绑定EIP到CLB
echo "正在绑定EIP到CLB..."
# tccli vpc AssociateAddress --cli-unfold-argument --region na-ashburn
tccli --profile=$project vpc AssociateAddress --cli-unfold-argument \
  --AddressId $eip_id \
  --InstanceId $clb_id \
  --region $REGION
}

make_k8s_secret_name() {
    d=`echo $1|awk -F. '{print $(NF-1)"."$(NF)}'`
    d=`echo $d|tr -d '\r\n'`
    per_page=1000
    offset=0
    total=`tccli --profile $project ssl DescribeCertificates --output json|jq -r '.TotalCount'`
    pages=$(( (total + per_page - 1) / per_page ))
    for ((i=0; i<pages; i++)); do
    # cid=`tccli --profile $project ssl DescribeCertificates --output json|jq -r --arg name $d '.Certificates[] | select(.Alias == $name) | select(.Status == 1)|.CertificateId'`
    cid=`tccli --profile $project ssl DescribeCertificates --Offset $offset --Limit $per_page  --output json|jq -r --arg name $d '.Certificates[] | select(.Domain == $name) | select(.Status == 1)|.CertificateId'`
    if [[ ! -z $cid ]];then
    break
    fi
    let offset+=$per_page
    done
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
rm -f create_k8s_secret_file
for i in `cat $domain_list`;do
# cid=`tccli --profile $project ssl DescribeCertificates --output json|jq -r --arg name $i '.Certificates[] | select(.Alias == $name) | select(.Status == 1)|.CertificateId'`
# secret_prefix=`echo $i|tr -d '\r\n'`|tr '.' '-'`
# secret_suffix=`echo $cid| tr '[:upper:]' '[:lower:]'`
res=$(make_k8s_secret_name $i)
echo "Secret名称与证书ID: $res"
secret_name=`echo $res|awk '{print $1}'`
cid=`echo $res|awk '{print $2}'`
if [[ -z $cid ]];then
echo "获取 $i 证书id失败" >> $operation_log_dir/create_k8s_secret.err
continue
fi
if [[ -z $secret_name ]];then
echo "构造 $i 证书secret名称为空" >> $operation_log_dir/create_k8s_secret.err
continue
fi
echo "创建K8S Secret: $secret_name" >> $create_k8s_secret_file
kubectl --context=$k8s_context -n $ns get secret $secret_name
# 相同域名不用创建
if [[ $? -eq 0 ]];then
continue
fi
# cat $secret_template | sed -e "s#\$cid#$cid#g" -e "s#\$secret_name#$secret_name#g" -e "s#\$ns#$ns#g" 
cat $secret_template | sed -e "s#\$cid#$cid#g" -e "s#\$secret_name#$secret_name#g" -e "s#\$ns#$ns#g" |kubectl --context=$k8s_context -n $ns apply -f -
if [[ $? -ne 0 ]];then
exit 1
fi
echo "Secret $secret_name 已创建."
done
}

create_k8s_ingress() {
create_k8s_ingress_file=$operation_log_dir/create_k8s_ingress.txt
for i in `cat $domain_list`;do
host=`echo $i|tr -d '\r\n'`
host=`echo $host|tr '[:upper:]' '[:lower:]'`
res=$(make_k8s_secret_name $host)
secret_name=`echo $res|awk '{print $1}'`
cid=`echo $res|awk '{print $2}'`
if [[ -z $cid ]];then
echo "获取 $i 证书id失败" >> $operation_log_dir/create_k8s_ingress.err
continue
fi
echo "关联Secret: $secret_name"
ingress_name=ingress-`echo $host|tr '.' '-'`
echo "关联K8S Ingress: $ingress_name"
grep -q $ingress_name $create_k8s_ingress_file

if [[ $? -eq 0 ]];then
echo "$ingress_name 已存在关联，请检查." >> $operation_log_dir/create_k8s_ingress.err
continue
fi

kubectl --context=$k8s_context -n $ns get ingress $ingress_name
if [[ $? -eq 0 ]];then
echo "$ingress_name 这个对象已存在." >> $operation_log_dir/create_k8s_ingress.err
continue
fi

create_clb $host
# clb_id=$()
if [[ -z $clb_id ]];then
echo "clb创建失败: $host" >> $operation_log_dir/create_k8s_ingress.err
continue
fi
echo "Ingress bind clb: $clb_id, $ingress_name" >> $create_k8s_ingress_file
# cat $ingress_template 
# export clb_id svc port host ingress_name ns secret_name
# envsubst < create-ingress-template.sed > create-ingress.sed
# sed -f create-ingress.sed $ingress_template
cat $ingress_template | sed -e "s#\$svc#$svc#g" -e "s#\$port#$port#g" -e "s#\$host#$host#g" -e "s#\$ingress_name#$ingress_name#g" -e "s#\$ns#$ns#g" -e "s#\$secret_name#$secret_name#g" -e "s#\$clb#$clb_id#g"|kubectl --context=$k8s_context -n $ns apply -f -
# cat $ingress_template | sed -e "s#\$clb_id#$clb_id#g" -e "s#\$svc#$svc#g" -e "s#\$svc_port#$svc_port#g" -e "s#\$host#$host#g" -e "s#\$ingress_name#$ingress_name#g" -e "s#\$ns#$ns#g" -e "s#\$secret_name#$secret_name#g" |kubectl --context=$k8s_context -n $ns apply -f -
echo "已完成创建Ingress bind clb: $clb_id, $ingress_name"
echo ""
sleep 5
done
}

create_k8s_80_ingress() {
create_k8s_ingress_file=$operation_log_dir/create_k8s_ingress.txt
for i in `cat $domain_list`;do
host=`echo $i|tr -d '\r\n'`
host=`echo $host|tr '[:upper:]' '[:lower:]'`
ingress_name=ingress-`echo $host|tr '.' '-'`
echo "关联K8S Ingress: $ingress_name"
grep -q $ingress_name $create_k8s_ingress_file

if [[ $? -eq 0 ]];then
echo "$ingress_name 已存在关联，请检查." >> $operation_log_dir/create_k8s_ingress.err
continue
fi

kubectl --context=$k8s_context -n $ns get ingress $ingress_name
if [[ $? -eq 0 ]];then
echo "$ingress_name 这个对象已存在." >> $operation_log_dir/create_k8s_ingress.err
continue
fi

create_clb $host
# clb_id=$()
if [[ -z $clb_id ]];then
echo "clb创建失败: $host" >> $operation_log_dir/create_k8s_ingress.err
continue
fi
echo "Ingress bind clb: $clb_id, $ingress_name" >> $create_k8s_ingress_file
cat "template/ingress-80.yaml" | sed -e "s#\$svc#$svc#g" -e "s#\$port#$port#g" -e "s#\$host#$host#g" -e "s#\$ingress_name#$ingress_name#g" -e "s#\$ns#$ns#g" -e "s#\$clb#$clb_id#g"|kubectl --context=$k8s_context -n $ns apply -f -
echo "已完成创建Ingress bind clb: $clb_id, $ingress_name"
echo ""
sleep 5
done
}

main() {
    create_k8s_secret
    create_k8s_ingress
    # create_k8s_80_ingress
}

main
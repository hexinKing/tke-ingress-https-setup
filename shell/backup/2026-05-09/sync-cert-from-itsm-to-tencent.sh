#!/bin/bash

gcp_cert_list_file=$2
itsm_cert_list_file=$3
dns_record_dir=dns-delete
operation_log_dir=log
project=$1

if [[ ! -d $dns_record_dir ]];then
mkdir $dns_record_dir
fi

if [[ ! -d $operation_log_dir ]];then
mkdir $operation_log_dir
fi

delete_cname_record() {
    delete_cname_record_file=$operation_log_dir/delete_cname_record.txt
    rm -f $delete_cname_record_file
    for i in `cat $gcp_cert_list_file`;do
    d=`echo $i|tr -d '\r\n'`
    echo "正在删除 $d CNAME 记录" >> $delete_cname_record_file
    id=`aws route53 list-hosted-zones --query "HostedZones[?Name=='$d.'].Id"|jq .[0]|tr -d '"'`
    dns_file=$dns_record_dir/dns-cname-acme-$d.json
    tmp_file=$dns_record_dir/change-batch-$d.json
    # aws route53 list-resource-record-sets --hosted-zone-id "$id" --query "ResourceRecordSets[?Type == 'CNAME' && contains(Name, '_acme-challenge')]"|jq '.[0]' > $dns_file
    aws route53 list-resource-record-sets --hosted-zone-id "$id" --query "ResourceRecordSets[?Type == 'CNAME' && Name == '_acme-challenge.$d.']"|jq '.[0]' > $dns_file
    jq -n '{"Changes": [{"Action": "DELETE", "ResourceRecordSet": input}]}' $dns_file > $tmp_file
    aws route53 change-resource-record-sets --hosted-zone-id "$id" --change-batch file://$tmp_file
    sleep 2
    done
}

create_cert_by_itsm() {
    create_cert_by_itsm_file=$operation_log_dir/create_cert_by_itsm.txt
    rm -f $create_cert_by_itsm_file
    for i in `cat $itsm_cert_list_file`;do
    d=`echo $i|tr -d '\r\n'`
    echo "正在创建 $d 证书" >> $create_cert_by_itsm_file
    python3 ../python/itsm/call_itsm_2_gen_ssl.py $d
    sleep 70
    done
}

download_cert_from_itsm() {
    download_cert_from_itsm_file=$operation_log_dir/download_cert_from_itsm.txt
    rm -f $download_cert_from_itsm_file
    for i in `cat $itsm_cert_list_file`;do
    # sleep 15
    d=`echo $i|tr -d '\r\n'`
    echo "正在下载 $d 证书" >> $download_cert_from_itsm_file
    python3 ../python/itsm/call_itsm_2_download_cert.py $d $project
    if [[ $? -ne 0 ]];then
    echo "---- $i ----"
    echo "证书下载失败: $d `date +'%Y%m%d-%H:%M:%S'`"
    echo "证书下载失败: $d `date +'%Y%m%d-%H:%M:%S'`" >> $operation_log_dir/download_cert_from_itsm.err
    fi
    done
}

upload_cert_to_tencent() {
    upload_cert_to_tencent_file=$operation_log_dir/upload_cert_to_tencent.txt
    rm -f $upload_cert_to_tencent_file
    cert_dir=../certificate/$project
    for i in `cat $itsm_cert_list_file`;do
    d=`echo $i|tr -d '\r'|tr -d '\n'`
    cid=`tccli --profile $project ssl DescribeCertificates --Offset 0 --Limit 1000 --output json|jq -r --arg name $d '.Certificates[] | select(.Domain == $name) | select(.Status == 1)|.CertificateId'`
    if [[ ! -z $cid ]];then
    echo "证书已存在: $d"
    continue
    fi

    if [[ ! -f "$cert_dir/$d.pem" ]];then
    echo "Download the certificate failed: $cert_dir/$d.pem `date +'%Y%m%d-%H:%M:%S'`" >> $operation_log_dir/upload_cert_to_tencent.err
    continue
    fi

    if [[ ! -f "$cert_dir/$d.key" ]];then
    echo "Download the private key failed: $cert_dir/$d.key `date +'%Y%m%d-%H:%M:%S'`" >> $operation_log_dir/upload_cert_to_tencent.err
    continue
    fi
    tccli --profile $project ssl UploadCertificate \
  --CertificatePublicKey "`cat $cert_dir/$d.pem`" \
  --CertificatePrivateKey "`cat $cert_dir/$d.key`" \
  --Alias $i \
  --ProjectId 0 \
  --CertificateType SVR
    sleep 2
    done
}

main() {
    # delete_cname_record
    create_cert_by_itsm
    download_cert_from_itsm
    upload_cert_to_tencent
}

main

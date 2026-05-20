#!/bin/bash

itsm_cert_list_file=$2
operation_log_dir=log
project=$1
itsm_gen_wait=${ITSM_CERT_GEN_WAIT_SECONDS:-70}

if [[ ! -d $operation_log_dir ]];then
mkdir $operation_log_dir
fi

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

create_cert_by_itsm() {
    create_cert_by_itsm_file=$operation_log_dir/create_cert_by_itsm.txt
    rm -f $create_cert_by_itsm_file
    for i in `cat $itsm_cert_list_file`;do
    d=`echo $i|tr -d '\r\n'`
    echo "正在创建 $d 证书" >> $create_cert_by_itsm_file
    python3 ../python/itsm/call_itsm_2_gen_ssl.py $d
    rc=$?
    case $rc in
        0) sleep $itsm_gen_wait ;;
        2) echo "[skip wait] $d 证书已存在" ;;
        *) echo "$d 调用 ITSM 失败 rc=$rc" >> $operation_log_dir/create_cert_by_itsm.err ;;
    esac
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
  --Alias "$d" \
  --ProjectId 0 \
  --CertificateType SVR
    sleep 2
    done
}

main() {
    preflight_domain_list "$itsm_cert_list_file" "1"
    create_cert_by_itsm
    download_cert_from_itsm
    upload_cert_to_tencent
}

main

import os
import sys

import mysql.connector
from mysql.connector import Error

import itsm_session


def main():
    if len(sys.argv) != 2:
        print("用法: python script.py <domain>")
        sys.exit(1)

    domain = sys.argv[1]
    print(f"接收到的域名: {domain}")

    db_password = os.environ.get('ITSM_DB_PASSWORD')
    if not db_password:
        print('ITSM_DB_PASSWORD 环境变量未设置')
        sys.exit(1)

    db_config = {
        'host': '10.147.0.9',
        'database': 'ops',
        'user': 'ops',
        'password': db_password,
        'charset': 'utf8mb4'
    }

    try:
        conn = mysql.connector.connect(**db_config)
        cursor = conn.cursor()

        cursor.execute(
            "SELECT * from nginxconf_ssl where name = %s and endtime > now();",
            (domain,)
        )
        if cursor.fetchone() is not None:
            print(f"已存在域名证书 '{domain}'")
            cursor.close()
            conn.close()
            sys.exit(2)

        cursor.execute(
            "SELECT id FROM bres_domainlist WHERE domain = %s",
            (domain,)
        )
        result = cursor.fetchone()
        if result is None:
            print(f"未找到域名 '{domain}' 对应的ID")
            cursor.close()
            conn.close()
            sys.exit(1)

        domain_id = result[0]
        print(f"查询到的ID: {domain_id}")
        cursor.close()
        conn.close()

    except Error as e:
        print(f"数据库查询错误: {e}")
        sys.exit(1)

    try:
        response = itsm_session.post_with_retry(
            '/nginxconf/nginx/ssl/generate/',
            data={'domain': domain_id},
        )
        print(f"HTTP状态码: {response.status_code}")
        print(f"响应内容: {response.text}")
        if response.status_code == 200:
            print("请求成功完成")
        else:
            print(f"请求失败，状态码: {response.status_code}")
    except RuntimeError as e:
        print(f"ITSM 调用失败: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"HTTP请求错误: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

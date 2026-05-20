import sys
import mysql.connector
from mysql.connector import Error
import requests
import urllib3
from urllib3.exceptions import InsecureRequestWarning

# 禁用SSL警告
urllib3.disable_warnings(InsecureRequestWarning)

def main():
    # 1. 检查命令行参数
    if len(sys.argv) != 2:
        print("用法: python script.py <domain>")
        sys.exit(1)
    
    domain = sys.argv[1]
    print(f"接收到的域名: {domain}")
    
    # 2. 查询MySQL数据库获取ID
    try:
        # 数据库连接配置 - 请根据实际情况修改
        db_config = {
            'host': '10.147.0.9',
            'database': 'ops',
            'user': 'ops',
            'password': '<REDACTED>',
            'charset': 'utf8mb4'
        }
        
        # 建立数据库连接
        conn = mysql.connector.connect(**db_config)
        cursor = conn.cursor()

        # 查询是否已经存在使用的证书
        query = "SELECT * from nginxconf_ssl where name = %s and endtime > now();"
        cursor.execute(query, (domain,))
        result = cursor.fetchone()

        if result is not None:
            print(f"已存在域名证书 '{domain}'")
            cursor.close()
            conn.close()
            sys.exit(1)
        
        # 执行查询
        query = "SELECT id FROM bres_domainlist WHERE domain = %s"
        cursor.execute(query, (domain,))
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
    
    # 3. 发送HTTP请求
    url = 'http://itsm.zhizhengroup.com/nginxconf/nginx/ssl/generate/'
    
    headers = {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Origin': 'http://itsm.zhizhengroup.com',
        'Pragma': 'no-cache',
        'Referer': 'http://itsm.zhizhengroup.com/nginxconf/nginx/ssl/generate/',
        'Upgrade-Insecure-Requests': '1',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36'
    }
    
    cookies = {
        'sessionid': '<REDACTED>'
    }
    
    data = {
        'domain': domain_id
    }
    
    try:
        response = requests.post(
            url,
            headers=headers,
            cookies=cookies,
            data=data,
            verify=False  # 相当于curl的--insecure，不推荐在生产环境使用
        )
        
        print(f"HTTP状态码: {response.status_code}")
        print(f"响应内容: {response.text}")
        
        # 检查请求是否成功
        if response.status_code == 200:
            print("请求成功完成")
        else:
            print(f"请求失败，状态码: {response.status_code}")
            
    except requests.exceptions.RequestException as e:
        print(f"HTTP请求错误: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
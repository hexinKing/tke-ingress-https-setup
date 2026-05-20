import sys
import mysql.connector
from mysql.connector import Error

def main():
    # 1. 检查命令行参数
    if len(sys.argv) != 3:
        print("用法: python script.py <name> <project>")
        sys.exit(1)
    
    name = sys.argv[1]
    project = sys.argv[2]
    print(f"接收到的名称: {name}")
    cert_dir = "../certificate/" + project
    
    # 2. 查询MySQL数据库获取key和pem
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
        
        # 执行查询
        query = "SELECT `key`, `pem` FROM nginxconf_ssl WHERE `name` = %s and endtime > now();"
        cursor.execute(query, (name,))
        result = cursor.fetchone()
        
        if result is None:
            print(f"未找到名称 '{name}' 对应的记录")
            cursor.close()
            conn.close()
            sys.exit(1)
            
        cert_content = result[0]
        key_content = result[1]
        
        print(f"成功查询到记录")
        
        cursor.close()
        conn.close()
        
    except Error as e:
        print(f"数据库查询错误: {e}")
        sys.exit(1)
    
    try:
        cert_filename = f"{name}.pem"
        with open(cert_dir + '/' + cert_filename, 'w') as pem_file:
            pem_file.write(cert_content)
        print(f"cert已保存到文件: {cert_filename}")
        
        key_filename = f"{name}.key"
        with open(cert_dir + '/' + key_filename, 'w') as key_file:
            key_file.write(key_content)
        print(f"key已保存到文件: {key_filename}")
        
        print("文件保存成功完成")
        
    except IOError as e:
        print(f"文件保存错误: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
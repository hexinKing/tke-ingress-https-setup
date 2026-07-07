#!/usr/bin/env python3

import argparse
import pymysql
from pathlib import Path
from datetime import datetime
import logging
import sys
import shutil
import OpenSSL


class CertificateSync:
    def __init__(self):
        self.setup_logging()
        self.setup_config()
        
    def setup_config(self):
        """硬编码配置参数"""
        self.config = {
            'database': {
                'host': '10.147.0.9',
                'port': 3306,
                'user': 'ops',
                'password': os.environ.get('ITSM_DB_PASSWORD', ''),
                'name': 'ops',
                'table': 'nginxconf_ssl'
            },
            'paths': {
                'cfs_path': '/mnt/cfs-sg-1/ssl',
                'temp_path': '/tmp',
                'cleanup_temp': True
            },
            'logging': {
                'level': 'INFO',
                'format': '%(asctime)s - %(levelname)s - %(message)s',
                'file': '/tmp/mysql_cert_sync.log'
            }
        }
    
    def setup_logging(self):
        """设置日志"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.StreamHandler(sys.stdout),
                logging.FileHandler('/tmp/mysql_cert_sync.log')
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def check_certificate_expiry(self, cert_path):
        """检查证书到期时间，返回剩余天数"""
        try:
            with open(cert_path, 'rb') as f:
                cert_data = f.read()
            
            cert = OpenSSL.crypto.load_certificate(OpenSSL.crypto.FILETYPE_PEM, cert_data)
            expiry_date = cert.get_notAfter().decode('ascii')
            
            # 解析证书到期时间 (格式: YYYYMMDDHHMMSSZ)
            expiry_datetime = datetime.strptime(expiry_date, '%Y%m%d%H%M%SZ')
            current_datetime = datetime.utcnow()
            
            # 计算剩余天数
            days_until_expiry = (expiry_datetime - current_datetime).days
            
            return days_until_expiry
            
        except Exception as e:
            self.logger.error(f"检查证书 {cert_path} 时出错: {e}")
            return None
    
    def find_expiring_certificates(self):
        """查找即将过期或已过期的证书"""
        cfs_path = self.config['paths']['cfs_path']
        expiring_domains = []
        
        try:
            path = Path(cfs_path)
            if not path.exists():
                self.logger.error(f"CFS路径不存在: {cfs_path}")
                return []
            
            # 遍历所有子目录
            for domain_dir in path.iterdir():
                if domain_dir.is_dir():
                    domain = domain_dir.name
                    cert_file = domain_dir / f"{domain}.crt"
                    
                    if cert_file.exists():
                        days_left = self.check_certificate_expiry(cert_file)
                        
                        if days_left is not None:
                            if days_left <= 7:
                                status = "已过期" if days_left < 0 else f"{days_left}天后过期"
                                self.logger.info(f"发现即将过期证书: {domain} ({status})")
                                expiring_domains.append(domain)
                        else:
                            self.logger.warning(f"无法读取证书有效期: {domain}")
                    else:
                        self.logger.warning(f"证书文件不存在: {cert_file}")
            
            self.logger.info(f"共找到 {len(expiring_domains)} 个需要更新的证书")
            return expiring_domains
            
        except Exception as e:
            self.logger.error(f"查找过期证书时出错: {e}")
            return []
    
    def query_certificates(self, domain_names):
        """查询MySQL数据库获取证书"""
        if not domain_names:
            return {}
            
        certificates = {}
        db_config = self.config['database']
        
        try:
            connection = pymysql.connect(
                host=db_config.get('host', 'localhost'),
                port=db_config.get('port', 3306),
                user=db_config['user'],
                password=db_config['password'],
                database=db_config['name'],
                charset='utf8mb4',
                cursorclass=pymysql.cursors.DictCursor
            )
            
            with connection.cursor() as cursor:
                # 构建查询条件
                placeholders = ','.join(['%s'] * len(domain_names))
                query = f"""
                SELECT name, pem, `key`, starttime 
                FROM {db_config.get('table', 'certificates')} 
                WHERE name IN ({placeholders})
                AND endtime > now()
                """
                
                cursor.execute(query, domain_names)
                results = cursor.fetchall()
                
                for row in results:
                    certificates[row['name']] = {
                        'pem': row['key'],
                        'key': row['pem']
                    }
            
            connection.close()
            self.logger.info(f"从数据库查询到 {len(certificates)} 个证书")
            
        except Exception as e:
            self.logger.error(f"数据库查询失败: {e}")
            raise
        
        return certificates
    
    def process_certificates(self, certificates):
        """处理证书文件"""
        paths_config = self.config['paths']
        temp_path = paths_config.get('temp_path', '/tmp/cert_sync')
        cfs_path = paths_config.get('cfs_path', '/mnt/cfs/ssl')
        cleanup_temp = paths_config.get('cleanup_temp', False)
        
        success_count = 0
        for name, cert_data in certificates.items():
            try:
                # 创建临时目录
                temp_dir = Path(temp_path) / name
                temp_dir.mkdir(parents=True, exist_ok=True)
                
                # 写入证书文件
                cert_file = temp_dir / f"{name}.crt"
                key_file = temp_dir / f"{name}.key"
                
                # 注意：根据你的数据库结构，可能需要调整pem和key的对应关系
                cert_file.write_text(cert_data['pem'])
                key_file.write_text(cert_data['key'])
                
                # 设置权限
                cert_file.chmod(0o644)
                key_file.chmod(0o600)  # 私钥文件权限应该更严格
                
                # 同步到CFS
                target_dir = Path(cfs_path) / name
                target_dir.mkdir(parents=True, exist_ok=True)
                
                shutil.copy2(cert_file, target_dir / cert_file.name)
                shutil.copy2(key_file, target_dir / key_file.name)
                
                self.logger.info(f"成功同步证书: {name}")
                success_count += 1
                
                # 验证同步后的证书
                synced_cert_path = target_dir / cert_file.name
                days_left = self.check_certificate_expiry(synced_cert_path)
                if days_left is not None:
                    self.logger.info(f"同步后证书 {name} 剩余有效期: {days_left} 天")
                
                # 清理临时文件（可选）
                if cleanup_temp:
                    shutil.rmtree(temp_dir)
                    self.logger.debug(f"已清理临时目录: {temp_dir}")
                    
            except Exception as e:
                self.logger.error(f"处理证书 {name} 时出错: {e}")
        
        return success_count
    
    def run(self, check_only=False):
        """执行同步流程"""
        try:
            # 1. 查找即将过期的证书
            self.logger.info("开始检查证书有效期...")
            expiring_domains = self.find_expiring_certificates()
            
            if not expiring_domains:
                self.logger.info("未找到需要更新的证书")
                return 0
            
            if check_only:
                self.logger.info(f"检查模式: 找到 {len(expiring_domains)} 个需要更新的证书")
                for domain in expiring_domains:
                    self.logger.info(f"需要更新: {domain}")
                return 0
            
            # 2. 查询证书
            self.logger.info(f"从数据库查询 {len(expiring_domains)} 个证书...")
            certificates = self.query_certificates(expiring_domains)
            
            if not certificates:
                self.logger.error("未查询到证书信息")
                return 0
            
            # 3. 处理证书文件
            self.logger.info("开始同步证书...")
            success_count = self.process_certificates(certificates)
            
            self.logger.info(f"证书同步完成，成功同步 {success_count}/{len(certificates)} 个证书")
            return 0 if success_count > 0 else 1
            
        except Exception as e:
            self.logger.error(f"执行失败: {e}")
            return 1


def main():
    """主函数"""
    # parser = argparse.ArgumentParser(description='证书同步脚本')
    # parser.add_argument(
    #     '--check-only',
    #     action='store_true',
    #     help='仅检查过期证书，不执行同步'
    # )
    
    # args = parser.parse_args()
    
    # 运行同步任务
    sync = CertificateSync()
    # return sync.run(check_only=args.check_only)
    return sync.run()


if __name__ == "__main__":
    sys.exit(main())
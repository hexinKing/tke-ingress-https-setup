#!/usr/bin/env python3

import argparse
import yaml
import pymysql
from pathlib import Path
from datetime import datetime
import logging
import sys
import shutil


class CertificateSync:
    def __init__(self, config):
        self.config = config
        self.setup_logging()
        
    def setup_logging(self):
        """设置日志"""
        log_config = self.config.get('logging', {})
        logging.basicConfig(
            level=getattr(logging, log_config.get('level', 'INFO')),
            format=log_config.get('format', '%(asctime)s - %(levelname)s - %(message)s'),
            handlers=[
                logging.StreamHandler(sys.stdout),
                logging.FileHandler(log_config.get('file', '/tmp/cert_sync.log'))
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def load_config_from_file(self, config_path):
        """从文件加载配置"""
        try:
            with open(config_path, 'r') as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            self.logger.error(f"配置文件不存在: {config_path}")
            return None
        except yaml.YAMLError as e:
            self.logger.error(f"配置文件格式错误: {e}")
            return None
        except Exception as e:
            self.logger.error(f"读取配置文件失败: {e}")
            return None
    
    def get_subdirectories(self, base_path):
        """获取子目录"""
        try:
            path = Path(base_path)
            if not path.exists():
                self.logger.error(f"路径不存在: {base_path}")
                return []
            return [d.name for d in path.iterdir() if d.is_dir()]
        except Exception as e:
            self.logger.error(f"获取子目录失败: {e}")
            return []
    
    def query_certificates(self, names):
        """查询MySQL数据库获取证书"""
        if not names:
            return {}
            
        # today = datetime.now().strftime('%Y-%m-%d')
        today = datetime.now().strftime('%Y-%m')
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
                placeholder_names = ','.join(['%s'] * len(names))
                today = '%' + today + '%'
                query = f"""
                SELECT name, pem, `key`, starttime 
                FROM {db_config.get('table', 'certificates')} 
                WHERE name IN ({placeholder_names}) AND starttime like %s
                """
                params = names + [today]
                last_executed_sql = cursor.mogrify(query, params)
                print(last_executed_sql)
                cursor.execute(query, params)
                results = cursor.fetchall()
                for row in results:
                    certificates[row['name']] = {
                        'pem': row['key'],
                        'key': row['pem']
                    }
            
            connection.close()
            self.logger.info(f"从MySQL查询到 {len(certificates)} 个证书")
            
        except Exception as e:
            self.logger.error(f"数据库查询失败: {e}")
            raise
        
        return certificates
    
    def process_certificates(self, certificates):
        """处理证书文件"""
        paths_config = self.config['paths']
        temp_path = paths_config.get('temp_path', '/tmp')
        cfs_path = paths_config.get('cfs_path', '/mnt/cfs/ssl')
        cleanup_temp = paths_config.get('cleanup_temp', False)
        
        for name, cert_data in certificates.items():
            try:
                # 创建临时目录
                temp_dir = Path(temp_path) / name
                temp_dir.mkdir(exist_ok=True)
                
                # 写入证书文件
                cert_file = temp_dir / f"{name}.crt"
                key_file = temp_dir / f"{name}.key"
                
                cert_file.write_text(cert_data['pem'])
                key_file.write_text(cert_data['key'])
                
                # 设置权限
                cert_file.chmod(0o644)
                key_file.chmod(0o644)
                
                # 同步到CFS
                target_dir = Path(cfs_path) / name
                if target_dir.exists():
                    shutil.copy2(cert_file, target_dir / cert_file.name)
                    shutil.copy2(key_file, target_dir / key_file.name)
                    self.logger.info(f"成功同步证书: {name}")
                else:
                    self.logger.warning(f"目标目录不存在: {target_dir}")
                
                # 清理临时文件（可选）
                if cleanup_temp:
                    shutil.rmtree(temp_dir)
                    self.logger.info(f"已清理临时目录: {temp_dir}")
                    
            except Exception as e:
                self.logger.error(f"处理证书 {name} 时出错: {e}")
    
    def run(self):
        """执行同步流程"""
        try:
            # 获取配置
            paths_config = self.config['paths']
            cfs_path = paths_config.get('cfs_path', '/mnt/cfs/ssl')
            
            # 1. 获取子目录
            subdirs = self.get_subdirectories(cfs_path)
            if not subdirs:
                self.logger.error("未找到任何子目录")
                return 1
            
            # 2. 查询证书
            certificates = self.query_certificates(subdirs)
            if not certificates:
                self.logger.error("未查询到证书信息")
                return 1
            
            # 3. 处理证书文件
            self.process_certificates(certificates)
            
            self.logger.info("证书同步完成")
            return 0
            
        except Exception as e:
            self.logger.error(f"执行失败: {e}")
            return 1


def load_config(config_path):
    """加载配置文件"""
    try:
        with open(config_path, 'r') as f:
            return yaml.safe_load(f)
    except Exception as e:
        print(f"加载配置文件失败: {e}")
        return None


def main():
    """主函数 - 通过命令行参数传入配置文件"""
    parser = argparse.ArgumentParser(description='MySQL证书同步脚本')
    parser.add_argument(
        '-c', '--config', 
        required=True,
        help='配置文件路径 (YAML格式)'
    )
    parser.add_argument(
        '--check-config',
        action='store_true',
        help='检查配置文件格式并退出'
    )
    
    args = parser.parse_args()
    
    # 加载配置文件
    config = load_config(args.config)
    if config is None:
        return 1
    
    # 检查配置模式
    if args.check_config:
        print("配置文件格式正确:")
        print(yaml.dump(config, default_flow_style=False))
        return 0
    
    # 运行同步任务
    sync = CertificateSync(config)
    return sync.run()


if __name__ == "__main__":
    sys.exit(main())
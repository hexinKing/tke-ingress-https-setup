import os
import time

import requests
import urllib3
from urllib.parse import urljoin, urlparse
from urllib3.exceptions import InsecureRequestWarning

urllib3.disable_warnings(InsecureRequestWarning)

ITSM_BASE = os.environ.get('ITSM_BASE_URL', 'https://itsm.zhizhengroup.com')
ITSM_DOMAIN = urlparse(ITSM_BASE).hostname
TTL_SAFE = int(os.environ.get('ITSM_SESSION_TTL', '43200'))
CACHE = os.path.expanduser('~/.itsm-session')


def _read_cache():
    try:
        if not os.path.exists(CACHE):
            return None
        if time.time() - os.path.getmtime(CACHE) >= TTL_SAFE:
            return None
        with open(CACHE) as f:
            sid = f.read().strip()
            return sid or None
    except (OSError, IOError):
        return None


def _write_cache(sid):
    with open(CACHE, 'w') as f:
        f.write(sid)
    os.chmod(CACHE, 0o600)


def _login_fresh():
    user = os.environ.get('ITSM_USER')
    password = os.environ.get('ITSM_PASSWORD')
    if not user or not password:
        raise RuntimeError(
            'ITSM_USER 或 ITSM_PASSWORD 环境变量未设置；'
            '或通过 ITSM_SESSIONID 直接提供 sessionid。'
        )
    s = requests.Session()
    s.verify = False
    # ITSM 的 login view 要求 POST 进来时已经带 sessionid cookie，所以先 GET /login/ 让服务器种一个匿名 sessionid
    s.get(urljoin(ITSM_BASE, '/login/'), timeout=10)
    # allow_redirects=False 才能看到原始 302（这是 ITSM 登录成功的明确信号）
    r = s.post(urljoin(ITSM_BASE, '/login/'),
               data={'username': user, 'password': password},
               timeout=10,
               allow_redirects=False)
    if r.status_code not in (301, 302):
        raise RuntimeError(
            f'ITSM 登录失败：POST /login/ 状态码 {r.status_code}（期望 302），检查 ITSM_USER/ITSM_PASSWORD'
        )
    sid = s.cookies.get('sessionid')
    if not sid:
        raise RuntimeError('ITSM 登录失败：返回 302 但 cookies 里没有 sessionid')
    _write_cache(sid)
    return s


def get_session():
    """优先级: ITSM_SESSIONID env > 本地缓存(mtime 在 TTL_SAFE 内) > 自动登录"""
    s = requests.Session()
    s.verify = False

    manual_sid = os.environ.get('ITSM_SESSIONID')
    if manual_sid:
        s.cookies.set('sessionid', manual_sid, domain=ITSM_DOMAIN)
        s._manual_sid = True
        return s

    cached_sid = _read_cache()
    if cached_sid:
        s.cookies.set('sessionid', cached_sid, domain=ITSM_DOMAIN)
        return s

    return _login_fresh()


def _is_session_invalid(response):
    return response.status_code in (401, 403) or '/login/' in response.url


def post_with_retry(path, **kwargs):
    """POST 到 ITSM。会话失效时：自动登录路径下重登一次重试；手动 sid 路径下直接报错。"""
    kwargs.setdefault('timeout', 30)
    s = get_session()
    r = s.post(urljoin(ITSM_BASE, path), **kwargs)
    if _is_session_invalid(r):
        if getattr(s, '_manual_sid', False):
            raise RuntimeError(
                'ITSM_SESSIONID 已失效。请刷新该值，或 unset 以走自动登录。'
            )
        if os.path.exists(CACHE):
            try:
                os.remove(CACHE)
            except OSError:
                pass
        s = _login_fresh()
        r = s.post(urljoin(ITSM_BASE, path), **kwargs)
    return r

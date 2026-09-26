#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本机回环地址上的 HTTP —— 一律绕开代理。

为什么值得单独拎一个模块
------------------------
实测抓到的现场（就在开发机上复现了）：

    $ env | grep -i proxy
    HTTP_PROXY=http://127.0.0.1:50539
    HTTPS_PROXY=http://127.0.0.1:50539
    （没有 NO_PROXY）

`urllib` 默认**照着环境变量走代理**，于是连 `http://127.0.0.1:8765`
这种本机地址也被丢给代理。代理当然不认 127.0.0.1，回一个 502，
或者干脆报「主机名解析不了」。

为什么这值得认真对待
--------------------
装过 VPN / 代理类客户端（RelyVPN、ProtonVPN、Clash、公司客户端……）的
Mac 上，这类环境变量被注入是**常事**。而看板的后端跟自己的调试端口、
跟自己 8765 之间全是 127.0.0.1 调用。一旦被代理挡掉，用户看到的是一堆
彼此毫无关系、且都指向错误方向的报错：

    · 「看板没应答」            —— 其实服务好端端跑着
    · 「登录失败，检查账号密码后重试」—— 后端只是问了下自己
    · 「浏览器起来了但调试端口不通」  —— 端口明明通着

每一条都会把用户引去改密码、重装、换网络 —— 全是在浪费时间。
而这一条只要一行 `ProxyHandler({})` 就能根除，且**零风险**：
本机地址本来就该直连，没有任何场景需要把它交给代理。

用法
----
    from netlocal import open_local, json_local, raw_local

    with open_local("http://127.0.0.1:8765/api/status", timeout=10) as r:
        d = json.loads(r.read())

设计上刻意不包成 HTTP 客户端库：调用点想怎么解包就怎么解包，
出错也能原样抛出（上层的人话翻译逻辑不用改）。
"""
import json
import urllib.error
import urllib.parse
import urllib.request

# 一个「永不使用代理」的 opener。复用同一个实例，省掉每次新建的开销。
DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))

_LOOPBACK = ("127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0")


def is_local(url):
    """这个地址是不是本机回环。"""
    try:
        host = (urllib.parse.urlparse(url).hostname or "").lower()
    except Exception:
        return False
    return host in _LOOPBACK or host.startswith("127.")


def open_local(url, data=None, headers=None, method=None, timeout=10):
    """发一个请求。本机地址强制直连；外网地址保持原样（该走代理就走）。

    返回的是一个可 `with` 的 response 对象，和 urlopen 一样。
    """
    req = urllib.request.Request(url, data=data,
                                 headers=headers or {}, method=method)
    if is_local(url):
        return DIRECT.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


def raw_local(url, timeout=4, headers=None, method=None, data=None):
    """读回原始字节；失败就抛（调用方自己决定怎么翻译成人话）。"""
    with open_local(url, data=data, headers=headers, method=method,
                    timeout=timeout) as r:
        return r.read()


def json_local(url, timeout=4, headers=None, method=None, data=None):
    """读回 JSON。"""
    b = raw_local(url, timeout=timeout, headers=headers, method=method, data=data)
    return json.loads(b.decode("utf-8", "replace"))


def post_json(url, obj, timeout=30):
    """POST 一个 JSON 上去，读回 JSON。"""
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    b = raw_local(url, timeout=timeout, data=body,
                  headers={"Content-Type": "application/json"}, method="POST")
    return json.loads(b.decode("utf-8", "replace"))


def direct_opener():
    """给需要自己控制重定向 / 证书的场景用。"""
    return DIRECT

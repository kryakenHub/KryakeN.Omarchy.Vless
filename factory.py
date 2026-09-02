#!/usr/bin/env python3
"""kryaken.omarchy.vless profile factory.

Builds a complete xray client config from a vless:// link, from a standalone
outbound JSON, or from a full xray/v2rayN client config (JSON file).

Usage:
    factory.py vless <uri> [--probe]
    factory.py outbound <outbound-json-file> [--probe]
    factory.py import <client-config-json-file> [--probe]

Prints two lines: NAME:<profile-name> followed by the config JSON.
With --probe the config listens on 127.0.0.1:1083/1084 and has only
socks/http inbounds (no root privileges needed to run it).
"""
import json
import os
import sys
import urllib.parse as up

SKIP_PROTOCOLS = ("freedom", "blackhole", "loopback", "dns")


def inbounds_std():
    return [
        {
            "tag": "socks-inbound",
            "port": 1080,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
        },
        {
            "tag": "http-inbound",
            "port": 1081,
            "listen": "127.0.0.1",
            "protocol": "http",
            "settings": {"timeout": 0},
        },
        {
            "tag": "transparent-inbound",
            "port": 1082,
            "listen": "0.0.0.0",
            "protocol": "dokodemo-door",
            "settings": {"network": "tcp", "followRedirect": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls"]},
        },
    ]


def inbounds_probe():
    return [
        {
            "tag": "socks-inbound",
            "port": 1083,
            "listen": "127.0.0.1",
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
        },
        {
            "tag": "http-inbound",
            "port": 1084,
            "listen": "127.0.0.1",
            "protocol": "http",
            "settings": {"timeout": 0},
        },
    ]


def build_config(outbound, probe):
    ob = dict(outbound)
    ob["tag"] = "proxy"
    ins = inbounds_probe() if probe else inbounds_std()
    route_tags = [i["tag"] for i in ins]
    return {
        "log": {"loglevel": "warning"},
        "inbounds": ins,
        "outbounds": [
            ob,
            {"tag": "direct", "protocol": "freedom", "settings": {}},
            {"tag": "blocked", "protocol": "blackhole", "settings": {}},
        ],
        "routing": {
            "domainStrategy": "IPOnDemand",
            "rules": [{"inboundTag": route_tags, "outboundTag": "proxy"}],
        },
    }


def parse_vless(uri):
    if not uri.lower().startswith("vless://"):
        raise ValueError("not a vless:// link")
    body = uri[len("vless://"):]
    name = ""
    if "#" in body:
        body, _, frag = body.rpartition("#")
        name = up.unquote(frag)
    q = ""
    if "?" in body:
        body, _, q = body.rpartition("?")
    qp = dict(up.parse_qsl(q, keep_blank_values=True))
    if "@" not in body:
        raise ValueError("malformed vless:// link (missing uuid@host)")
    uuid, _, hostport = body.partition("@")
    hostport = up.unquote(hostport)
    if hostport.startswith("["):
        host, _, rest = hostport[1:].partition("]")
        port = up.unquote(rest.lstrip(":") or "443")
    else:
        host, _, port = hostport.rpartition(":")
    host = up.unquote(host)
    try:
        port = int(port)
    except (ValueError, TypeError):
        port = 443
    if not host or not uuid:
        raise ValueError("malformed vless:// link")

    ob = {
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [
                        {
                            "id": uuid,
                            "encryption": qp.get("encryption", "none"),
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": qp.get("type", "tcp").lower(),
            "security": qp.get("security", "none").lower(),
        },
    }
    flow = qp.get("flow", "")
    if flow:
        ob["settings"]["vnext"][0]["users"][0]["flow"] = flow

    sec = ob["streamSettings"]["security"]
    ss = ob["streamSettings"]
    if sec == "tls":
        tls = {
            "serverName": qp.get("sni") or qp.get("peer") or host,
        }
        fp = qp.get("fp", "")
        if fp:
            tls["fingerprint"] = fp
        alpn = [a for a in qp.get("alpn", "").replace("%2C", ",").split(",") if a]
        if alpn:
            tls["alpn"] = alpn
        if qp.get("allowInsecure", "").lower() in ("1", "true", "yes"):
            tls["allowInsecure"] = True
        ss["tlsSettings"] = tls
    elif sec == "reality":
        r = {}
        for k, v in (
            ("serverName", qp.get("sni") or qp.get("peer") or host),
            ("fingerprint", qp.get("fp", "")),
            ("publicKey", qp.get("pbk", "")),
            ("shortId", qp.get("sid", "")),
            ("spiderX", qp.get("spx", "")),
        ):
            if v:
                r[k] = v
        ss["realitySettings"] = r

    net = ob["streamSettings"]["network"]
    if net == "ws":
        path = qp.get("path", "")
        ws = {}
        if path:
            ws["path"] = path
        h = qp.get("host", "")
        if h:
            ws["headers"] = {"Host": up.unquote(h)}
        if ws:
            ss["wsSettings"] = ws
    elif net == "grpc":
        svc = qp.get("serviceName", "") or qp.get("path", "").lstrip("/")
        g = {}
        if svc:
            g["serviceName"] = svc
        if qp.get("authority", ""):
            g["authority"] = qp["authority"]
        if qp.get("mode", "").lower() == "multi":
            g["multiMode"] = True
        if g:
            ss["grpcSettings"] = g
    elif net in ("http", "h2"):
        h = qp.get("host", "")
        path = qp.get("path", "/") or "/"
        hs = {"path": [path]}
        if h:
            hs["host"] = [up.unquote(h)]
        ss["httpSettings"] = hs
    elif net == "tcp":
        if qp.get("headerType", "").lower() and qp["headerType"].lower() != "none":
            ss["tcpSettings"] = {"header": {"type": qp["headerType"]}}

    if not name:
        name = "%s:%s" % (host, port)
    return ob, name


def extract_outbound(cfg_path):
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
    obs = cfg.get("outbounds") or []
    target = None
    for o in obs:
        if (o or {}).get("protocol") not in SKIP_PROTOCOLS:
            target = o
            break
    if target is None and obs:
        target = obs[0]
    if target is None:
        raise ValueError("no outbound found in config")
    name = str(target.get("tag") or os.path.splitext(os.path.basename(cfg_path))[0])
    return target, name


def main():
    if len(sys.argv) < 3:
        print("usage: factory.py {vless|outbound|import} ARG [--probe]", file=sys.stderr)
        return 2
    mode, arg = sys.argv[1], sys.argv[2]
    probe = "--probe" in sys.argv[3:]
    try:
        if mode == "vless":
            outbound, name = parse_vless(arg)
        elif mode == "outbound":
            with open(arg, encoding="utf-8") as fh:
                outbound = json.load(fh)
            name = "default"
        elif mode == "import":
            outbound, name = extract_outbound(arg)
        else:
            print("unknown factory mode: %s" % mode, file=sys.stderr)
            return 2
        cfg = build_config(outbound, probe)
        print("NAME:" + name)
        print(json.dumps(cfg, indent=2))
        return 0
    except Exception as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
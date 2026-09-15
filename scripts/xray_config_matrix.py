#!/usr/bin/env python3
"""Check every configuration AorusVlessLink can generate against the REAL Xray loader.

Why this exists
---------------
`AorusVlessLink.xrayConfiguration` hands the in-process core a JSON document, and the core
builds that document **as a whole**. One key the core does not like is not one outbound
failing — it is `runXrayFromJson` refusing outright, so the core never starts and every other
server in the user's list goes down with it. Unit tests cannot see that: only the core's own
configuration loader knows which spellings it still accepts.

Xray also removes features. Between the version this client was written against and the one it
links today, `allowInsecure`, the `h2`/`http` transport, three Shadowsocks ciphers and REALITY
over WebSocket all stopped being accepted — each of them a silent "VPN does not work" for
whoever had such a key. This script is how those were found, and how the next batch will be.

Running it
----------
Needs Go and network access. It builds a small program against the exact `xray-core` revision
`LIBXRAY_VERSION` pins (read out of the workflow), then feeds it a matrix of configurations
transcribed from `xrayConfiguration`. Not part of CI: it downloads a Go module tree and takes a
few minutes. Run it by hand after touching the generator, or after moving the core's pin.

    python3 scripts/xray_config_matrix.py

Keeping the transcription honest
--------------------------------
The model below mirrors the Swift. When you change `xrayConfiguration`, change it here too —
a check that has drifted from the code proves nothing. The Swift test suite pins the generated
keys field by field, so the two drifting apart shows up there.
"""
import itertools
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "build-aorusgram.yml"

# Mirrors of the sets in AorusVlessLink.swift.
SUPPORTED_NETWORKS = ["tcp", "ws", "grpc", "httpupgrade", "xhttp"]
SUPPORTED_SECURITIES = ["none", "tls", "reality"]
SUPPORTED_FINGERPRINTS = ["chrome", "firefox", "safari", "ios", "android", "edge",
                          "360", "qq", "random", "randomized"]
SUPPORTED_VMESS_CIPHERS = ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"]
SUPPORTED_SS_METHODS = ["aes-128-gcm", "aes-256-gcm", "chacha20-poly1305", "xchacha20-poly1305",
                        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
                        "2022-blake3-chacha20-poly1305"]
REALITY_NETWORKS = {"tcp", "xhttp", "grpc"}
XHTTP_MODES = {"auto", "packet-up", "stream-up", "stream-one"}

UUID = "00000000-0000-4000-8000-000000000001"
REALITY_PBK = "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"
SS2022_16 = "MTIzNDU2Nzg5MGFiY2RlZg=="
SS2022_32 = "MTIzNDU2Nzg5MGFiY2RlZjEyMzQ1Njc4OTBhYmNkZWY="

CHECKER_GO = '''package main

import (
\t"fmt"
\t"os"
\t"strings"

\t"github.com/xtls/xray-core/infra/conf/serial"
\t_ "github.com/xtls/xray-core/main/distro/all"
)

func main() {
\tdata, err := os.ReadFile(os.Args[1])
\tif err != nil {
\t\tfmt.Println("READ ERROR:", err)
\t\tos.Exit(2)
\t}
\tif _, err := serial.LoadJSONConfig(strings.NewReader(string(data))); err != nil {
\t\tfmt.Println("REJECTED:", err)
\t\tos.Exit(1)
\t}
\tfmt.Println("ACCEPTED")
}
'''


def server(**kw):
    base = dict(proto="vless", address="edge.example.com", port=443, credential=UUID,
                encryption="", flow="", network="tcp", security="none", serverName=None,
                fingerprint=None, publicKey=None, shortId=None, spiderX=None, alpn=[],
                path=None, host=None, serviceName=None, headerType=None, mode=None,
                allowInsecure=False, obfsPassword=None, pinnedCertSha256=None, portHopping=None)
    base.update(kw)
    return base


def xray_configuration(s, local_port=10800, udp=True, mux=True):
    """A transcription of AorusVlessLink.xrayConfiguration."""
    if s["proto"] == "hysteria2":
        return hysteria2_configuration(s, local_port, udp)

    settings = {}
    if s["proto"] == "vmess":
        user = {"id": s["credential"], "alterId": 0,
                "security": s["encryption"] or "auto", "level": 0}
        settings["vnext"] = [{"address": s["address"], "port": s["port"], "users": [user]}]
        settings["packetEncoding"] = "xudp" if udp else "none"
    elif s["proto"] == "trojan":
        settings["servers"] = [{"address": s["address"], "port": s["port"],
                                "password": s["credential"]}]
    elif s["proto"] == "shadowsocks":
        settings["servers"] = [{"address": s["address"], "port": s["port"],
                                "method": s["encryption"], "password": s["credential"]}]
    else:
        user = {"id": s["credential"], "encryption": "none"}
        if s["flow"]:
            user["flow"] = s["flow"]
        settings["vnext"] = [{"address": s["address"], "port": s["port"], "users": [user]}]
        settings["packetEncoding"] = "xudp" if udp else "none"

    stream = {"network": s["network"], "security": s["security"]}
    if s["security"] == "reality":
        reality = {"serverName": s["serverName"] or "", "publicKey": s["publicKey"] or "",
                   "fingerprint": s["fingerprint"] or "chrome"}
        if s["shortId"]:
            reality["shortId"] = s["shortId"]
        if s["spiderX"] is not None:
            reality["spiderX"] = s["spiderX"]
        stream["realitySettings"] = reality
    elif s["security"] == "tls":
        # No allowInsecure: the core removed it and refuses the whole document over it.
        tls = {"serverName": s["serverName"] or s["address"]}
        if s["fingerprint"] is not None:
            tls["fingerprint"] = s["fingerprint"]
        if s["alpn"]:
            tls["alpn"] = s["alpn"]
        if s["pinnedCertSha256"]:
            tls["pinnedPeerCertSha256"] = s["pinnedCertSha256"]
        stream["tlsSettings"] = tls

    net = s["network"]
    if net == "ws":
        ws = {"path": s["path"] or "/"}
        if s["host"] is not None:
            ws["headers"] = {"Host": s["host"]}
        stream["wsSettings"] = ws
    elif net == "httpupgrade":
        up = {"path": s["path"] or "/"}
        if s["host"] is not None:
            up["host"] = s["host"]
        stream["httpupgradeSettings"] = up
    elif net == "xhttp":
        xh = {"path": s["path"] or "/"}
        if s["host"] is not None:
            xh["host"] = s["host"]
        if s["mode"] in XHTTP_MODES:
            xh["mode"] = s["mode"]
        stream["xhttpSettings"] = xh
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": s["serviceName"] or "",
                                  "multiMode": s["mode"] == "multi"}
    elif s["headerType"] == "http":
        request = {"path": [s["path"] or "/"]}
        if s["host"] is not None:
            request["headers"] = {"Host": [s["host"]]}
        stream["tcpSettings"] = {"header": {"type": "http", "request": request}}

    outbound = {"tag": "aorus-user-outbound", "protocol": s["proto"],
                "settings": settings, "streamSettings": stream}
    on = mux and not s["flow"]
    outbound["mux"] = {"enabled": on, "concurrency": 8 if on else -1}
    return wrap(outbound, local_port, udp)


def hysteria2_configuration(s, local_port, udp):
    tls = {"serverName": s["serverName"] or s["address"], "alpn": s["alpn"] or ["h3"]}
    if s["pinnedCertSha256"]:
        tls["pinnedPeerCertSha256"] = s["pinnedCertSha256"]
    stream = {"network": "hysteria", "security": "tls", "tlsSettings": tls,
              "hysteriaSettings": {"version": 2, "auth": s["credential"]}}
    final = {}
    if s["obfsPassword"]:
        final["udp"] = [{"type": "salamander", "settings": {"password": s["obfsPassword"]}}]
    if s["portHopping"]:
        final["quicParams"] = {"udpHop": {"ports": s["portHopping"]}}
    if final:
        stream["finalmask"] = final
    outbound = {"tag": "aorus-user-outbound", "protocol": "hysteria",
                "settings": {"version": 2, "address": s["address"], "port": s["port"]},
                "streamSettings": stream}
    return wrap(outbound, local_port, udp)


def wrap(outbound, local_port, udp):
    return {"log": {"loglevel": "warning"},
            "inbounds": [{"tag": "aorus-user-socks", "listen": "127.0.0.1", "port": local_port,
                          "protocol": "socks",
                          "settings": {"auth": "noauth", "udp": udp, "ip": "127.0.0.1"}}],
            "outbounds": [outbound]}


def cases():
    for proto, net, sec in itertools.product(
            ["vless", "vmess", "trojan", "shadowsocks"], SUPPORTED_NETWORKS, SUPPORTED_SECURITIES):
        if sec == "reality" and net not in REALITY_NETWORKS:
            continue
        kw = dict(proto=proto, network=net, security=sec)
        if proto == "vmess":
            kw["encryption"] = "auto"
        elif proto == "trojan":
            kw["credential"] = "trojan-password"
        elif proto == "shadowsocks":
            kw["credential"] = "ss-password"
            kw["encryption"] = "aes-256-gcm"
        if sec == "reality":
            kw.update(serverName="edge.example.com", publicKey=REALITY_PBK,
                      shortId="0123456789abcdef", spiderX="/")
        elif sec == "tls":
            kw["serverName"] = "edge.example.com"
        if net in ("ws", "httpupgrade", "xhttp"):
            kw.update(path="/aorus", host="edge.example.com")
        if net == "grpc":
            kw["serviceName"] = "grpcsvc"
        yield f"{proto}/{net}/{sec}", server(**kw)

    for fp in SUPPORTED_FINGERPRINTS:
        yield f"tls/fp={fp}", server(security="tls", serverName="edge.example.com", fingerprint=fp)
        yield f"reality/fp={fp}", server(security="reality", serverName="edge.example.com",
                                         publicKey=REALITY_PBK, shortId="ab", fingerprint=fp)
    for cipher in SUPPORTED_VMESS_CIPHERS:
        yield f"vmess/cipher={cipher}", server(proto="vmess", encryption=cipher)
    for method in SUPPORTED_SS_METHODS:
        credential = "ss-password"
        if method == "2022-blake3-aes-128-gcm":
            credential = SS2022_16
        elif method.startswith("2022-"):
            credential = SS2022_32
        yield f"ss/{method}", server(proto="shadowsocks", encryption=method, credential=credential)

    yield "vless/vision", server(flow="xtls-rprx-vision", security="tls", serverName="edge.example.com")
    yield "tls/alpn", server(security="tls", serverName="edge.example.com", alpn=["h2", "http/1.1"])
    yield "tcp/header=http", server(headerType="http", path="/x", host="edge.example.com")
    yield "grpc/multi", server(network="grpc", serviceName="svc", mode="multi")
    yield "reality/no-shortId", server(security="reality", serverName="edge.example.com",
                                       publicKey=REALITY_PBK)
    for mode in sorted(XHTTP_MODES):
        yield f"xhttp/{mode}", server(network="xhttp", mode=mode, path="/x")

    yield "hy2/plain", server(proto="hysteria2", credential="pass", network="hysteria",
                              security="tls", serverName="gate.example.com", alpn=["h3"])
    yield "hy2/full", server(proto="hysteria2", credential="pass", network="hysteria",
                             security="tls", serverName="gate.example.com", alpn=["h3"],
                             obfsPassword="mask", portHopping="20000-25000",
                             pinnedCertSha256="ab" * 32)


def pinned_core_version():
    """The xray-core revision libXray pins, read through the version the workflow pins."""
    text = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"LIBXRAY_VERSION:\s*(\S+)", text)
    if not match:
        sys.exit("could not find LIBXRAY_VERSION in the workflow")
    libxray = match.group(1)
    url = f"https://raw.githubusercontent.com/XTLS/libXray/{libxray}/go.mod"
    gomod = subprocess.run(["curl", "-sS", url], capture_output=True, text=True).stdout
    core = re.search(r"github\.com/xtls/xray-core (\S+)", gomod)
    if not core:
        sys.exit(f"could not read the xray-core requirement out of {url}")
    return libxray, core.group(1)


def build_checker(workdir, core_version):
    (workdir / "go.mod").write_text(
        f"module confcheck\n\ngo 1.26.3\n\nrequire github.com/xtls/xray-core {core_version}\n",
        encoding="utf-8")
    (workdir / "main.go").write_text(CHECKER_GO, encoding="utf-8")
    env = dict(os.environ, GOFLAGS="-mod=mod")
    for argv in (["go", "mod", "tidy"], ["go", "build", "-o", "confcheck", "."]):
        result = subprocess.run(argv, cwd=workdir, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"{' '.join(argv)} failed:\n{result.stderr}")
    return workdir / "confcheck"


def main():
    if shutil.which("go") is None:
        sys.exit("this needs Go: it builds the core's own configuration loader")
    libxray, core_version = pinned_core_version()
    print(f"libXray {libxray} -> xray-core {core_version}")
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="aorus-confcheck-"))
    try:
        checker = build_checker(workdir, core_version)
        config_path = workdir / "config.json"
        failures = []
        total = 0
        for name, s in cases():
            for mux, udp in itertools.product((True, False), (True, False)):
                total += 1
                config_path.write_text(json.dumps(xray_configuration(s, udp=udp, mux=mux)),
                                       encoding="utf-8")
                result = subprocess.run([str(checker), str(config_path)],
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    message = (result.stdout or result.stderr).strip().split(">")[-1].strip()
                    failures.append((f"{name} mux={mux} udp={udp}", message))
                    break
        print(f"checked {total} configurations against the real Xray loader")
        for name, message in failures:
            print(f"REJECTED {name}\n    {message}")
        if failures:
            print(f"\n{len(failures)} rejected")
            return 1
        print("all ACCEPTED")
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

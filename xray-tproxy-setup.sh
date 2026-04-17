#!/bin/sh
ip rule del fwmark 1 lookup 100 2>/dev/null
ip rule add fwmark 1 lookup 100
ip route del local default dev lo table 100 2>/dev/null
ip route add local default dev lo table 100

nft delete table inet xray_tproxy 2>/dev/null
nft add table inet xray_tproxy
nft add chain inet xray_tproxy prerouting '{ type filter hook prerouting priority mangle; policy accept; }'
nft add rule inet xray_tproxy prerouting iifname != "br-lan" accept
nft add rule inet xray_tproxy prerouting meta mark 0x000000ff accept
nft add rule inet xray_tproxy prerouting ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } accept
nft add rule inet xray_tproxy prerouting ip daddr 255.255.255.255 accept
nft add rule inet xray_tproxy prerouting udp dport { 67, 68 } accept
nft add rule inet xray_tproxy prerouting meta l4proto tcp tproxy ip to :12345 meta mark set 1
nft add rule inet xray_tproxy prerouting meta l4proto udp tproxy ip to :12345 meta mark set 1
echo TPROXY_OK

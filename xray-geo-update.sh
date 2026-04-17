#!/bin/sh
# Обновление geo-баз xray
XRAY_DIR=/usr/local/etc/xray

wget -q -O $XRAY_DIR/geoip.dat.tmp https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && mv $XRAY_DIR/geoip.dat.tmp $XRAY_DIR/geoip.dat
wget -q -O $XRAY_DIR/geosite.dat.tmp https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat && mv $XRAY_DIR/geosite.dat.tmp $XRAY_DIR/geosite.dat
/etc/init.d/xray restart
echo "Geo databases updated: $(date)" >> /var/log/xray/geo-update.log

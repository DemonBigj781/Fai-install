curl -sS -X POST "https://fai-project.org/cgi/faime.cgi" \
  -F type=install \
  -F username="debian" \
  -F userpw="debian" \
  -F rootpw="root" \
  -F suite="bookworm" \
  -F partition="ONE" \
  -F desktop="" \
  -F cl1="BACKPORTS" \
  -F cl5="SSH_SERVER" \
  -F cl6="STANDARD" \
  -F cl7="NONFREE" \
  -F cl9="RECOMMENDS" \
  -F cl8="REBOOT" \
  -F rclocal="1" \
  -F sbm="2" \
  -F addpkgs="\
wpasupplicant wireless-tools iw ifupdown isc-dhcp-client ca-certificates curl wget rfkill \
firmware-iwlwifi firmware-atheros firmware-brcm80211 firmware-realtek" \
  -F postinst=@postinst.sh
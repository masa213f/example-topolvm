#!/bin/bash

TOPOLVM_VERSION=0.2.2

mkdir -p /opt/topolvm/{sbin,lib}
mkdir -p /var/topolvm

curl -LsSf https://github.com/cybozu-go/topolvm/releases/download/v${TOPOLVM_VERSION}/lvmd-${TOPOLVM_VERSION}.tar.gz | tar xzf - -C /opt/topolvm/sbin

cat << 'EOF' > /opt/topolvm/lib/setup-backing-store
#!/bin/bash

DATA_FILE=/var/topolvm/backing-store

if [ ! -f ${DATA_FILE} ]; then
  dd if=/dev/zero of=${DATA_FILE} bs=1M count=5120
fi

LOOP_DEV=$(losetup -j ${DATA_FILE} | cut -d: -f1)
if [ -z "${LOOP_DEV}" ]; then
  LOOP_DEV=$(losetup -f ${DATA_FILE} --show)
fi

vgcreate -y topolvm-vg ${LOOP_DEV}
EOF

cat << EOF > /etc/systemd/system/setup-lvmd-backing-store.service
[Unit]
Description=Setup lvmd backing store
Wants=lvm2-monitor.service
After=lvm2-monitor.service
Before=lvmd.service

[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /var/topolvm
ExecStart=/bin/bash -x /opt/topolvm/lib/setup-backing-store
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /etc/systemd/system/lvmd.service
[Unit]
Description=lvmd for TopoLVM
Wants=lvm2-monitor.service
After=lvm2-monitor.service

[Service]
Type=simple
Restart=on-failure
RestartForceExitStatus=SIGPIPE
ExecStartPre=/bin/mkdir -p /run/topolvm 
ExecStart=/opt/topolvm/sbin/lvmd --volume-group=topolvm-vg --listen=/run/topolvm/lvmd.sock

[Install]
WantedBy=multi-user.target
EOF

systemctl enable setup-lvmd-backing-store
systemctl start setup-lvmd-backing-store

systemctl enable lvmd
systemctl start lvmd

#!/bin/bash
# ALT Kworkstation Demo Exam 2026 - Modules 1+2 Fully Autonomous Setup Script
# Run as root on the target VM only.
# Interactive choice for machine. HQ-CLI skipped as requested.
# For interactive parts (e.g. samba-domain-provision, some manual zone edits if needed): script will show commands and pause.
# Assumes standard VM interfaces (enp0s3 etc.), root/toor, Additional.iso may be needed for some Module 2 files/images - mount manually if required.
# Use at your own risk. Test in parts if possible. Many steps from official guide.

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pause() {
  echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort...${NC}"
  read -r
}

show_header() {
  clear
  echo -e "${GREEN}=== ALT Kworkstation ДЭ 2026 | Modules 1+2 Auto-Setup ===${NC}"
  echo "Machine: $1"
  echo "================================================================"
}

setup_isp() {
  show_header "ISP"
  echo -e "${YELLOW}Starting ISP Module 1 + Module 2 (NTP, nginx reverse proxy + auth)...${NC}"
  pause

  # Module 1: Interfaces
  echo "Configuring enp0s3 (DHCP to upstream)..."
  mkdir -p /etc/net/ifaces/enp0s3
  cat > /etc/net/ifaces/enp0s3/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=dhcp
EOF

  echo "Configuring enp0s8 (to HQ-RTR 172.16.1.1/28)..."
  mkdir -p /etc/net/ifaces/enp0s8
  cat > /etc/net/ifaces/enp0s8/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s8/ipv4address << 'EOF'
172.16.1.1/28
EOF

  echo "Configuring enp0s9 (to BR-RTR 172.16.2.1/28)..."
  mkdir -p /etc/net/ifaces/enp0s9
  cat > /etc/net/ifaces/enp0s9/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s9/ipv4address << 'EOF'
172.16.2.1/28
EOF

  systemctl restart network || true
  echo -e "${GREEN}Network interfaces configured.${NC}"

  # Timezone
  echo "Setting timezone Europe/Moscow..."
  timedatectl set-timezone Europe/Moscow
  timedatectl set-ntp true

  # nftables + NAT + forwarding (Module 1)
  echo "Installing and configuring nftables + NAT..."
  apt-get update && apt-get install -y nftables
  systemctl enable --now nftables.service

  sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf || true
  sysctl -p /etc/net/sysctl.conf || true

  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat postrouting { type nat hook postrouting priority 100\; } 2>/dev/null || true
  nft add rule ip nat postrouting oifname "enp0s3" masquerade 2>/dev/null || true
  nft list ruleset > /etc/nftables/nftables.nft
  systemctl restart nftables.service

  echo -e "${GREEN}ISP Module 1 basic done.${NC}"

  # Module 2: chrony NTP server stratum 5
  echo "Configuring chrony NTP server (stratum 5)..."
  apt-get install -y chrony
  cat > /etc/chrony/chrony.conf << 'EOF'
# NTP server for exam - stratum 5
local stratum 5
allow 10.0.0.0/8
allow 172.16.0.0/12
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
  systemctl enable --now chronyd.service || systemctl enable --now chrony.service || true
  echo -e "${GREEN}chrony configured. Clients: HQ-SRV, HQ-CLI, BR-RTR, BR-SRV should use this.${NC}"

  # Module 2: nginx as reverse proxy + web auth for web.au-team.irpo
  echo "Installing nginx for reverse proxy + basic auth..."
  apt-get install -y nginx apache2-utils
  mkdir -p /etc/nginx

  # Create htpasswd for WEBc / P@ssw0rd
  htpasswd -cb /etc/nginx/.htpasswd WEBc P@ssw0rd || echo "WEBc:P@ssw0rd" | htpasswd -c /etc/nginx/.htpasswd WEBc || true

  # Simple reverse proxy config (adjust IPs if needed after full setup)
  cat > /etc/nginx/nginx.conf << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    # Reverse proxy for web.au-team.irpo -> HQ-SRV webapp (assume port 8080 after port forward)
    server {
        listen 80;
        server_name web.au-team.irpo;

        location / {
            auth_basic "Restricted Area";
            auth_basic_user_file /etc/nginx/.htpasswd;
            proxy_pass http://10.0.100.2:8080;  # HQ-SRV after port forward / actual internal
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }

    # Reverse proxy for docker.au-team.irpo -> BR-SRV testapp (port 8080)
    server {
        listen 80;
        server_name docker.au-team.irpo;

        location / {
            proxy_pass http://10.1.0.2:8080;  # BR-SRV
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
EOF

  systemctl enable --now nginx.service || true
  echo -e "${GREEN}nginx reverse proxy + auth configured (basic). Adjust proxy_pass IPs/ports after full setup if needed.${NC}"
  echo -e "${YELLOW}For full Module 2 on ISP: also ensure port forwards on HQ-RTR/BR-RTR are done.${NC}"

  echo -e "${GREEN}=== ISP setup complete (Module 1+2 key parts). Do not power off! ===${NC}"
  pause
}

setup_hq_rtr() {
  show_header "HQ-RTR"
  echo -e "${YELLOW}Starting HQ-RTR Module 1 (full) + Module 2 (port forwards, IPsec later in M3)...${NC}"
  pause

  # Hostname
  hostnamectl set-hostname hq-rtr.au-team.irpo
  exec bash || true

  # Interfaces Module 1
  echo "Configuring enp0s3 (to ISP)..."
  mkdir -p /etc/net/ifaces/enp0s3
  cat > /etc/net/ifaces/enp0s3/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4address << 'EOF'
172.16.1.2/28
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4route << 'EOF'
default via 172.16.1.1
EOF

  echo "Configuring enp0s8 (trunk for VLANs)..."
  mkdir -p /etc/net/ifaces/enp0s8
  cat > /etc/net/ifaces/enp0s8/options << 'EOF'
TYPE=eth
CONFIG_IPV4=no
BOOTPROTO=static
EOF

  # VLAN 100 (HQ-SRV)
  mkdir -p /etc/net/ifaces/enp0s8.100
  cat > /etc/net/ifaces/enp0s8.100/options << 'EOF'
TYPE=vlan
HOST=enp0s8
VID=100
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s8.100/ipv4address << 'EOF'
10.0.100.1/27
EOF

  # VLAN 200 (HQ-CLI)
  mkdir -p /etc/net/ifaces/enp0s8.200
  cat > /etc/net/ifaces/enp0s8.200/options << 'EOF'
TYPE=vlan
HOST=enp0s8
VID=200
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s8.200/ipv4address << 'EOF'
10.0.200.1/27
EOF

  # VLAN 999 (management)
  mkdir -p /etc/net/ifaces/enp0s8.999
  cat > /etc/net/ifaces/enp0s8.999/options << 'EOF'
TYPE=vlan
HOST=enp0s8
VID=999
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s8.999/ipv4address << 'EOF'
10.0.99.1/29
EOF

  systemctl restart network || true
  echo -e "${GREEN}VLAN interfaces configured.${NC}"

  # Timezone
  timedatectl set-timezone Europe/Moscow
  timedatectl set-ntp true

  # Packages + services
  echo "Installing frr, nftables, dhcp-server, sudo..."
  apt-get update && apt-get install -y frr nftables dhcp-server sudo

  # DNS temp
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  cat > /etc/resolv.conf << 'EOF'
search au-team.irpo
nameserver 10.0.100.2
EOF

  systemctl enable --now frr.service nftables.service dhcpd.service sshd.service || true

  # GRE Tunnel (Module 1 task 6)
  echo "Configuring GRE tunnel gre1..."
  mkdir -p /etc/net/ifaces/gre1
  cat > /etc/net/ifaces/gre1/options << 'EOF'
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.1.2
TUNREMOTE=172.16.2.2
TUNTTL=64
TUNOPTIONS='ttl 64'
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/gre1/ipv4address << 'EOF'
10.255.255.1/30
EOF
  systemctl restart network || true

  # OSPF on GRE only + auth (Module 1 task 7)
  echo "Configuring OSPF (link-state) on GRE interface with MD5 auth..."
  sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons || true
  systemctl restart frr || true

  # vtysh commands - non-interactive way
  vtysh -c "configure terminal" \
        -c "ip forwarding" \
        -c "interface gre1" \
        -c "ip ospf authentication message-digest" \
        -c "ip ospf message-digest-key 1 md5 P@ssw0rd" \
        -c "exit" \
        -c "router ospf" \
        -c "network 10.0.99.0/29 area 0" \
        -c "network 10.0.100.0/27 area 0" \
        -c "network 10.0.200.0/27 area 0" \
        -c "network 10.255.255.0/30 area 0" \
        -c "exit" \
        -c "write" \
        -c "exit" || true

  echo -e "${GREEN}GRE + OSPF configured (protected with password).${NC}"

  # NAT outbound (Module 1 task 8)
  echo "Configuring NAT outbound..."
  sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf || true
  sysctl -p /etc/net/sysctl.conf || true

  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat postrouting { type nat hook postrouting priority 100\; } 2>/dev/null || true
  nft add rule ip nat postrouting oifname "enp0s3" masquerade 2>/dev/null || true
  nft list ruleset > /etc/nftables/nftables.nft
  systemctl restart nftables.service || true

  # DHCP for VLAN 200 / HQ-CLI (Module 1 task 9)
  echo "Configuring DHCP server for HQ-CLI (VLAN 200)..."
  cp /etc/dhcp/dhcpd.conf.sample /etc/dhcp/dhcpd.conf || true
  sed -i 's/192.168.0.0/10.0.200.0/' /etc/dhcp/dhcpd.conf || true
  sed -i 's/255.255.255.0/255.255.255.224/' /etc/dhcp/dhcpd.conf || true
  sed -i 's/192.168.0.1/10.0.200.1/' /etc/dhcp/dhcpd.conf || true
  sed -i 's/domain.org/au-team.irpo/' /etc/dhcp/dhcpd.conf || true
  sed -i 's/192.168.1.1/10.0.100.2/' /etc/dhcp/dhcpd.conf || true   # DNS = HQ-SRV
  sed -i 's/10.0.200.128 192.168.0.254/10.0.200.2 10.0.200.30/' /etc/dhcp/dhcpd.conf || true
  # Exclude router IP already in range start
  systemctl restart dhcpd.service || true

  # net_admin user (Module 1 task 3)
  echo "Creating net_admin user..."
  useradd -m -G wheel net_admin || true
  echo "net_admin:P@ssw0rd" | chpasswd
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel || true

  # Module 2: Static port forwards (nft)
  echo "Configuring static port forwards (Module 2 task 8)..."
  # Example: 2026 -> HQ-SRV:2026 , 8080 -> HQ-SRV:8080
  # Add to nftables (append rules)
  nft add chain ip nat prerouting { type nat hook prerouting priority 0\; } 2>/dev/null || true
  nft add rule ip nat prerouting iifname "enp0s3" tcp dport 2026 dnat to 10.0.100.2:2026 || true
  nft add rule ip nat prerouting iifname "enp0s3" tcp dport 8080 dnat to 10.0.100.2:8080 || true
  nft list ruleset > /etc/nftables/nftables.nft
  systemctl restart nftables.service || true

  echo -e "${GREEN}=== HQ-RTR setup complete (Module 1 full + key Module 2). ===${NC}"
  pause
}

setup_br_rtr() {
  show_header "BR-RTR"
  echo -e "${YELLOW}Starting BR-RTR Module 1 (full) + Module 2 port forwards...${NC}"
  pause

  hostnamectl set-hostname br-rtr.au-team.irpo
  exec bash || true

  # Interfaces
  echo "Configuring enp0s3 (to ISP)..."
  mkdir -p /etc/net/ifaces/enp0s3
  cat > /etc/net/ifaces/enp0s3/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4address << 'EOF'
172.16.2.2/28
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4route << 'EOF'
default via 172.16.2.1
EOF

  echo "Configuring enp0s8 (to BR-SRV)..."
  mkdir -p /etc/net/ifaces/enp0s8
  cat > /etc/net/ifaces/enp0s8/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s8/ipv4address << 'EOF'
10.1.0.1/27
EOF

  systemctl restart network || true

  timedatectl set-timezone Europe/Moscow
  timedatectl set-ntp true

  apt-get update && apt-get install -y frr nftables sudo
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  cat > /etc/resolv.conf << 'EOF'
search au-team.irpo
nameserver 10.0.100.2
EOF

  systemctl enable --now frr.service nftables.service sshd.service || true

  # GRE Tunnel
  echo "Configuring GRE tunnel gre1..."
  mkdir -p /etc/net/ifaces/gre1
  cat > /etc/net/ifaces/gre1/options << 'EOF'
TYPE=iptun
TUNTYPE=gre
TUNLOCAL=172.16.2.2
TUNREMOTE=172.16.1.2
TUNTTL=64
TUNOPTIONS='ttl 64'
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/gre1/ipv4address << 'EOF'
10.255.255.2/30
EOF
  systemctl restart network || true

  # OSPF
  sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons || true
  systemctl restart frr || true

  vtysh -c "configure terminal" \
        -c "ip forwarding" \
        -c "interface gre1" \
        -c "ip ospf authentication message-digest" \
        -c "ip ospf message-digest-key 1 md5 P@ssw0rd" \
        -c "exit" \
        -c "router ospf" \
        -c "network 10.1.0.0/27 area 0" \
        -c "network 10.255.255.0/30 area 0" \
        -c "exit" \
        -c "write" || true

  # NAT
  sed -i 's/net.ipv4.ip_forward = 0/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf || true
  sysctl -p /etc/net/sysctl.conf || true
  nft add table ip nat 2>/dev/null || true
  nft add chain ip nat postrouting { type nat hook postrouting priority 100\; } 2>/dev/null || true
  nft add rule ip nat postrouting oifname "enp0s3" masquerade 2>/dev/null || true
  nft list ruleset > /etc/nftables/nftables.nft
  systemctl restart nftables.service || true

  # net_admin
  useradd -m -G wheel net_admin || true
  echo "net_admin:P@ssw0rd" | chpasswd
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel || true

  # Module 2 port forwards
  echo "Configuring static port forwards for BR-SRV..."
  nft add chain ip nat prerouting { type nat hook prerouting priority 0\; } 2>/dev/null || true
  nft add rule ip nat prerouting iifname "enp0s3" tcp dport 2026 dnat to 10.1.0.2:2026 || true
  nft add rule ip nat prerouting iifname "enp0s3" tcp dport 8080 dnat to 10.1.0.2:8080 || true
  nft list ruleset > /etc/nftables/nftables.nft
  systemctl restart nftables.service || true

  echo -e "${GREEN}=== BR-RTR setup complete. ===${NC}"
  pause
}

setup_hq_srv() {
  show_header "HQ-SRV"
  echo -e "${YELLOW}Starting HQ-SRV Module 1 (full network + DNS + ssh) + Module 2 (RAID, NFS, webapp apache+mariadb, fail2ban)...${NC}"
  echo -e "${RED}NOTE: For RAID you need 2 extra 1GB disks attached in VM settings. For webapp files/dump.sql from Additional.iso - mount it or copy files manually.${NC}"
  pause

  hostnamectl set-hostname hq-srv.au-team.irpo
  exec bash || true

  # Interface + VLAN 100
  mkdir -p /etc/net/ifaces/enp0s3
  cat > /etc/net/ifaces/enp0s3/options << 'EOF'
TYPE=eth
CONFIG_IPV4=no
BOOTPROTO=static
EOF

  mkdir -p /etc/net/ifaces/enp0s3.100
  cat > /etc/net/ifaces/enp0s3.100/options << 'EOF'
TYPE=vlan
HOST=enp0s3
VID=100
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s3.100/ipv4address << 'EOF'
10.0.100.2/27
EOF
  cat > /etc/net/ifaces/enp0s3.100/ipv4route << 'EOF'
default via 10.0.100.1
EOF

  systemctl restart network || true

  # sshuser (Module 1)
  useradd -u 2026 -m -G wheel sshuser || true
  echo "sshuser:P@ssw0rd" | chpasswd
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel || true
  systemctl enable --now sshd.service || true

  # SSH hardening (port 2026, banner, max tries 2, allow only sshuser)
  sed -i 's/#Port 22/Port 2026/' /etc/openssh/sshd_config || true
  sed -i 's/#MaxAuthTries 6/MaxAuthTries 2/' /etc/openssh/sshd_config || true
  echo "Authorized access only" > /etc/ssh_banner || true
  sed -i 's|#Banner none|Banner /etc/ssh_banner|' /etc/openssh/sshd_config || true
  echo "AllowUsers sshuser" >> /etc/openssh/sshd_config || true
  systemctl restart sshd.service || true

  timedatectl set-timezone Europe/Moscow
  timedatectl set-ntp true

  # DNS (bind) - automated as much as possible
  echo "Installing and configuring BIND DNS (forward + reverse zones)..."
  apt-get update && apt-get install -y bind bind-utils
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  cat > /etc/resolv.conf << 'EOF'
search au-team.irpo
nameserver 127.0.0.1
EOF

  # Basic named options (simplified, may need tweak for exam)
  cat > /etc/bind/named.conf.options << 'EOF'
options {
    directory "/var/lib/bind";
    allow-query { any; };
    recursion yes;
    forwarders { 77.88.8.7; 8.8.8.8; };
};
EOF

  # Create zone files (simplified with Table 2 records)
  mkdir -p /var/lib/bind/etc/zone
  cat > /var/lib/bind/etc/zone/au-team.db << 'EOF'
$TTL 86400
@   IN  SOA ns.au-team.irpo. admin.au-team.irpo. (
        2024062201 ; serial
        3600       ; refresh
        1800       ; retry
        604800     ; expire
        86400 )    ; minimum
    IN  NS  ns.au-team.irpo.
ns          IN  A   10.0.100.2
hq-rtr      IN  A   10.0.99.1
br-rtr      IN  A   10.1.0.1
hq-srv      IN  A   10.0.100.2
hq-cli      IN  A   10.0.200.10   ; example from DHCP range
br-srv      IN  A   10.1.0.2
docker      IN  A   172.16.1.1    ; ISP side example
web         IN  A   172.16.2.1
EOF

  cat > /var/lib/bind/etc/zone/au-team_vlan100_rev.db << 'EOF'
$TTL 86400
@   IN  SOA ns.au-team.irpo. admin.au-team.irpo. (
        2024062201 ; serial
        3600
        1800
        604800
        86400 )
    IN  NS  ns.au-team.irpo.
2.100.0.10.in-addr.arpa.  IN  PTR hq-srv.au-team.irpo.
EOF

  cat > /var/lib/bind/etc/zone/au-team_vlan200_rev.db << 'EOF'
$TTL 86400
@   IN  SOA ns.au-team.irpo. admin.au-team.irpo. (
        2024062201
        3600
        1800
        604800
        86400 )
    IN  NS  ns.au-team.irpo.
EOF

  # named.conf.local
  cat >> /etc/bind/named.conf.local << 'EOF'
zone "au-team.irpo" {
    type master;
    file "/var/lib/bind/etc/zone/au-team.db";
};

zone "100.0.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/etc/zone/au-team_vlan100_rev.db";
};

zone "200.0.10.in-addr.arpa" {
    type master;
    file "/var/lib/bind/etc/zone/au-team_vlan200_rev.db";
};
EOF

  chown -R named:named /var/lib/bind/etc/zone || true
  chmod 600 /var/lib/bind/etc/zone/*.db || true
  systemctl enable --now named.service || systemctl enable --now bind.service || true

  echo -e "${GREEN}DNS basic configured. Verify with nslookup later.${NC}"

  # Module 2: RAID md0 (needs extra disks /dev/sdb /dev/sdc usually)
  echo "Configuring RAID0 md0 (requires 2 extra disks attached)..."
  apt-get install -y mdadm
  # Assume disks are /dev/sdb and /dev/sdc - adjust if different (check lsblk)
  lsblk
  echo -e "${YELLOW}If extra disks are present, creating RAID0...${NC}"
  mdadm --create /dev/md0 --level=0 --raid-devices=2 /dev/sdb /dev/sdc || echo "RAID creation skipped or failed - check disks with lsblk and run manually if needed."
  mkfs.ext4 /dev/md0 || true
  mkdir -p /raid
  echo "/dev/md0 /raid ext4 defaults 0 0" >> /etc/fstab || true
  mount -a || true
  echo -e "${GREEN}RAID /raid mounted (if disks present).${NC}"

  # NFS (Module 2)
  echo "Configuring NFS share /raid/nfs for HQ-CLI network..."
  apt-get install -y nfs-utils
  mkdir -p /raid/nfs
  echo "/raid/nfs 10.0.200.0/27(rw,sync,no_root_squash)" >> /etc/exports || true
  exportfs -ra || true
  systemctl enable --now nfs-server.service || true

  # Webapp apache + mariadb (Module 2 task 7) - simplified, files from Additional.iso needed
  echo "Installing apache + mariadb for webapp..."
  apt-get install -y apache2 mariadb-server php php-mysqlnd
  systemctl enable --now httpd.service mysqld.service || systemctl enable --now apache2 mariadb || true

  echo -e "${YELLOW}For full webapp: mount Additional.iso, copy web/ files and dump.sql, import DB, create webc user, edit index.php with DB creds P@ssw0rd, set DocumentRoot.${NC}"
  echo "Example DB setup:"
  echo "mysql -e \"CREATE DATABASE webdb; CREATE USER 'webc'@'localhost' IDENTIFIED BY 'P@ssw0rd'; GRANT ALL ON webdb.* TO 'webc'@'localhost'; FLUSH PRIVILEGES;\""
  echo "Then import dump.sql if available."

  # fail2ban (Module 2 task 9)
  echo "Installing fail2ban for SSH protection..."
  apt-get install -y fail2ban
  cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = 2026
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 60
EOF
  systemctl enable --now fail2ban || true

  echo -e "${GREEN}=== HQ-SRV setup complete (key parts). For full webapp/RAID verify disks and ISO. ===${NC}"
  pause
}

setup_br_srv() {
  show_header "BR-SRV"
  echo -e "${YELLOW}Starting BR-SRV Module 1 (ssh) + Module 2 (Samba DC interactive, ansible, docker webapp)...${NC}"
  echo -e "${RED}Samba domain provision is interactive - script will show command and pause for you to run it.${NC}"
  pause

  hostnamectl set-hostname br-srv.au-team.irpo
  exec bash || true

  # Interface
  mkdir -p /etc/net/ifaces/enp0s3
  cat > /etc/net/ifaces/enp0s3/options << 'EOF'
TYPE=eth
CONFIG_IPV4=yes
BOOTPROTO=static
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4address << 'EOF'
10.1.0.2/27
EOF
  cat > /etc/net/ifaces/enp0s3/ipv4route << 'EOF'
default via 10.1.0.1
EOF

  systemctl restart network || true

  # sshuser
  useradd -u 2026 -m -G wheel sshuser || true
  echo "sshuser:P@ssw0rd" | chpasswd
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel || true
  systemctl enable --now sshd.service || true

  # SSH config same as HQ-SRV
  sed -i 's/#Port 22/Port 2026/' /etc/openssh/sshd_config || true
  sed -i 's/#MaxAuthTries 6/MaxAuthTries 2/' /etc/openssh/sshd_config || true
  echo "Authorized access only" > /etc/ssh_banner || true
  sed -i 's|#Banner none|Banner /etc/ssh_banner|' /etc/openssh/sshd_config || true
  echo "AllowUsers sshuser" >> /etc/openssh/sshd_config || true
  systemctl restart sshd.service || true

  timedatectl set-timezone Europe/Moscow
  timedatectl set-ntp true

  cat > /etc/resolv.conf << 'EOF'
search au-team.irpo
nameserver 10.0.100.2
EOF

  # Module 2: Samba DC - interactive provision
  echo -e "${YELLOW}=== Samba DC setup (interactive) ===${NC}"
  apt-get install -y samba samba-client samba-winbind || true
  echo "Run the following manually for domain provision:"
  echo "samba-tool domain provision --realm=AU-TEAM.IRPO --domain=AU-TEAM --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307"
  echo "Then: samba-tool user add hquser1 etc, create group hq, add users, set domain join on HQ-CLI later."
  echo "After provision: systemctl enable --now samba.service"
  pause

  # Ansible (Module 2)
  echo "Configuring ansible..."
  apt-get install -y ansible
  mkdir -p /etc/ansible
  cat > /etc/ansible/hosts << 'EOF'
[hq]
hq-srv.au-team.irpo
hq-cli.au-team.irpo
hq-rtr.au-team.irpo
br-rtr.au-team.irpo
EOF
  cat > /etc/ansible/ansible.cfg << 'EOF'
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
EOF
  echo -e "${GREEN}Ansible inventory ready. Test with ansible all -m ping from BR-SRV.${NC}"

  # Docker webapp (Module 2 task 6) - requires images from Additional.iso docker/ dir
  echo "Docker + webapp stack (testapp + db)..."
  apt-get install -y docker docker-compose || true
  systemctl enable --now docker.service || true
  echo -e "${YELLOW}For full docker: mkdir -p /root/docker, copy images or load from Additional.iso, create docker-compose.yml with testapp and db (mariadb), env for testdb/testc/P@ssw0rd, expose 8080.${NC}"
  echo "Example minimal docker-compose.yml would go here if files available."

  echo -e "${GREEN}=== BR-SRV setup complete (key parts). Run samba provision manually. ===${NC}"
  pause
}

# Main menu
while true; do
  echo -e "${GREEN}"
  echo "Select machine to configure (Modules 1+2):"
  echo "1) ISP"
  echo "2) HQ-RTR"
  echo "3) BR-RTR"
  echo "4) HQ-SRV"
  echo "5) BR-SRV"
  echo "6) Exit / Quit"
  echo -e "${NC}"
  read -p "Enter choice [1-6]: " choice

  case $choice in
    1) setup_isp ;;
    2) setup_hq_rtr ;;
    3) setup_br_rtr ;;
    4) setup_hq_srv ;;
    5) setup_br_srv ;;
    6) echo "Exiting. Remember to verify connectivity, run sysctl -p on routers after reboot, and complete any manual steps (samba, zone edits, docker images)."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
done

#!/usr/bin/env bash

export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
stty erase ^?

nginx_dir="/etc/nginx"
nginx_conf_dir="/etc/nginx/conf.d"

install_packages() {
	rpm_packages="tar zip unzip openssl openssl-devel lsof git jq socat nginx crontabs make gcc rrdtool rrdtool-perl perl-core spawn-fcgi"
	apt_packages="tar zip unzip openssl libssl-dev lsof git jq socat nginx cron make gcc rrdtool librrds-perl spawn-fcgi"
	if [[ $PM == "apt-get" ]]; then
		$PM update
		$INS wget curl gnupg2 ca-certificates dmidecode lsb-release
		update-ca-certificates
		echo "deb http://nginx.org/packages/$ID $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
		curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add -
		$PM update
		$INS $apt_packages
	elif [[ $PM == "yum" || $PM == "dnf" ]]; then
		sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
		setenforce 0
		cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
		$INS wget curl ca-certificates dmidecode epel-release
		update-ca-trust force-enable
		$INS $rpm_packages
	fi
	mkdir -p $nginx_dir
	cat > $nginx_dir/nginx.conf <<EOF
worker_processes  auto;

error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;


events {
    worker_connections  1024;
}


http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    tcp_nopush     on;

    keepalive_timeout  65;

    gzip  on;

    include $nginx_conf_dir/*.conf;
}
EOF
	systemctl enable nginx
	systemctl start nginx
	ps -ef | grep -q nginx || error=1
	[[ $error ]] && echo "Nginx安装失败" && exit 1
}

get_info() {
	source /etc/os-release || source /usr/lib/os-release || exit 1
	if [[ $ID == "centos" ]]; then
		PM="yum"
		INS="yum install -y"
	elif [[ $ID == "debian" || $ID == "ubuntu" ]]; then
		PM="apt-get"
		INS="apt-get install -y"
	else
		exit 1
	fi
	read -rp "输入服务器名称（如香港）:" name
	read -rp "输入服务器代号（如hk）:" code
	read -rp "输入通信密钥（不限长度）:" sec
}

compile_smokeping() {
	rm -rf /tmp/smokeping
	mkdir -p /tmp/smokeping
	cd /tmp/smokeping
	wget https://oss.oetiker.ch/smokeping/pub/smokeping-2.7.3.tar.gz
	tar xzvf smokeping-2.7.3.tar.gz
	cd smokeping-2.7.3
	./configure --prefix=/usr/local/smokeping
	make install || gmake install
	[[ ! -f /usr/local/smokeping/bin/smokeping ]] && echo "编译smokeping失败" && exit 1
}

configure() {
	origin="https://github.com/jiuqi9997/smokeping/raw/main"
	ip=$(curl -sL https://api64.ipify.org -4) || error=1
	[[ $error ]] && echo "获取本机ip失败" && exit 1
	wget $origin/tcpping -O /usr/bin/tcpping && chmod +x /usr/bin/tcpping
	wget $origin/nginx.conf -O $nginx_conf_dir/default.conf && nginx -s reload
	wget $origin/config -O /usr/local/smokeping/etc/config
	wget $origin/systemd -O /etc/systemd/system/smokeping.service && systemctl enable smokeping
	wget $origin/slave.sh -O /usr/local/smokeping/bin/slave.sh
	sed -i 's/SLAVE_CODE/'$code'/g' /usr/local/smokeping/etc/config /usr/local/smokeping/bin/slave.sh
	sed -i 's/SLAVE_NAME/'$name'/g' /usr/local/smokeping/etc/config
	sed -i 's/MASTER_IP/'$ip'/g' /usr/local/smokeping/bin/slave.sh
	echo "$code:$sec" > /usr/local/smokeping/etc/smokeping_secrets.dist
	echo "$sec" > /usr/local/smokeping/etc/secrets
	chmod 700 /usr/local/smokeping/etc/secrets /usr/local/smokeping/etc/smokeping_secrets.dist
	chown nginx:nginx /usr/local/smokeping/etc/smokeping_secrets.dist
	cd /usr/local/smokeping/htdocs
	mkdir -p data var cache ../cache
	mv smokeping.fcgi.dist smokeping.fcgi
	../bin/smokeping --debug || error=1
	[[ $error ]] && echo "测试运行失败！" && exit 1
}



get_info
install_packages
compile_smokeping
configure

systemctl start smokeping
sleep 3
systemctl status smokeping | grep -q 'Sent data to Server and got new config in response' || error=1
[[ $error ]] && echo "启动失败" && exit 1

rm -rf /tmp/smokeping

echo "安装完成，页面网址：http://$ip （监控数据不会立即生成）"
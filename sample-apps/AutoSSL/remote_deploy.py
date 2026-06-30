import paramiko
import os
import sys
import time
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

HOST = "103.216.117.178"
PORT = 24700
USER = "root"
PASSWORD = ""  # removed after deploy
APP_DIR = "/var/www/autossl"
LOCAL_ARCHIVE = "E:/Project/autossl.tar.gz"

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")

def ssh_exec(ssh, cmd, check=False):
    log(f"  $ {cmd}")
    stdin, stdout, stderr = ssh.exec_command(cmd, timeout=300)
    out = stdout.read().decode('utf-8', errors='replace').strip()
    err = stderr.read().decode('utf-8', errors='replace').strip()
    code = stdout.channel.recv_exit_status()
    if out:
        for line in out.split('\n'):
            print(f"    {line}")
    if err and code != 0:
        for line in err.split('\n'):
            print(f"    [ERR] {line}")
    if check and code != 0:
        raise Exception(f"Command failed (exit {code}): {cmd}")
    return out, err, code

def main():
    archive = os.path.abspath(LOCAL_ARCHIVE)
    if not os.path.exists(archive):
        log(f"ERROR: Archive not found: {archive}")
        sys.exit(1)

    log(f"Archive: {archive} ({os.path.getsize(archive)} bytes)")
    log(f"Connecting to {HOST}:{PORT}...")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=30)
    log("Connected!")

    # Upload archive
    log("Uploading archive...")
    sftp = ssh.open_sftp()
    sftp.put(archive, "/tmp/autossl.tar.gz")
    sftp.close()
    log("Upload complete!")

    # Extract (preserve data/ for stats persistence)
    log("Extracting on server...")
    ssh_exec(ssh, f"cp -r {APP_DIR}/data /tmp/autossl_data 2>/dev/null; true")
    ssh_exec(ssh, f"rm -rf {APP_DIR}")
    ssh_exec(ssh, f"mkdir -p {APP_DIR}")
    ssh_exec(ssh, f"tar -xzf /tmp/autossl.tar.gz -C {APP_DIR}")
    ssh_exec(ssh, f"cp -r /tmp/autossl_data {APP_DIR}/data 2>/dev/null; rm -rf /tmp/autossl_data; true")
    ssh_exec(ssh, f"ls -la {APP_DIR}")
    ssh_exec(ssh, "rm -f /tmp/autossl.tar.gz")

    # Install Node.js
    log("Checking Node.js...")
    _, _, code = ssh_exec(ssh, "node --version")
    if code != 0:
        log("Installing Node.js 20...")
        ssh_exec(ssh, "curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -")
        ssh_exec(ssh, "dnf install -y nodejs", check=True)
    ssh_exec(ssh, "node --version")

    # Install PM2
    log("Checking PM2...")
    _, _, code = ssh_exec(ssh, "pm2 --version")
    if code != 0:
        log("Installing PM2...")
        ssh_exec(ssh, "npm install -g pm2", check=True)

    # Install nginx
    log("Checking nginx...")
    _, _, code = ssh_exec(ssh, "nginx -v")
    if code != 0:
        log("Installing nginx...")
        ssh_exec(ssh, "dnf install -y epel-release")
        ssh_exec(ssh, "dnf install -y nginx", check=True)
        ssh_exec(ssh, "systemctl enable nginx")
        ssh_exec(ssh, "systemctl start nginx")

    # Firewall
    log("Configuring firewall...")
    ssh_exec(ssh, "firewall-cmd --permanent --add-service=http 2>/dev/null; firewall-cmd --reload 2>/dev/null; true")

    # Create .env.local BEFORE build (Next.js reads env at build time)
    log("Creating .env.local...")
    env_content = """NODE_TLS_REJECT_UNAUTHORIZED=0
ALLOWED_IPS=127.0.0.1,123.25.21.12,172.31.98.188,115.73.218.192,103.57.222.245,118.70.127.171
ALLOWED_CIDRS=

# WHM API Tokens
WHM_TOKEN_1=RHXL2N1G0DLZ118X3G50GGUGBPZ1P4WE
WHM_TOKEN_2=2EX79YMHIWEE20ZDALOOP2E9HDUSYKAU
WHM_TOKEN_3=6U7YXGQUSO1Z5ICAQ8P4XOC6YUEW5BFH
WHM_TOKEN_4=M5D0FN5XTC6HM63G5JU50121Y2VKD0W5
WHM_TOKEN_5=U7ZIFI5JLYOOG1A73B2R0T2FYNANPOL2
WHM_TOKEN_6=YR20SH46JXB6VYSD5S4FH83ED7DPTH8M
WHM_TOKEN_7=83C4MKPIYPLQ47OPH4RFVGBQ4C2AK9D1
WHM_TOKEN_9=FXD482BU602RVARBA6O0C01M40YJ761Y"""
    ssh_exec(ssh, f'cat > {APP_DIR}/.env.local << \'ENVEOF\'\n{env_content}\nENVEOF')

    # Install dependencies & build
    log("Installing npm dependencies (this may take a while)...")
    ssh_exec(ssh, f"cd {APP_DIR} && npm install --production=false")
    log("Building Next.js app...")
    ssh_exec(ssh, f"cd {APP_DIR} && npm run build", check=True)

    # Setup nginx
    log("Setting up nginx...")
    ssh_exec(ssh, f"cp {APP_DIR}/nginx.conf /etc/nginx/conf.d/autossl.conf")
    ssh_exec(ssh, "test -f /etc/nginx/conf.d/default.conf && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak; true")
    ssh_exec(ssh, "nginx -t", check=True)
    ssh_exec(ssh, "systemctl reload nginx")

    # SELinux
    log("Configuring SELinux...")
    ssh_exec(ssh, "setsebool -P httpd_can_network_connect 1 2>/dev/null; true")

    # Install certbot and get SSL certificate
    log("Setting up Let's Encrypt SSL...")
    ssh_exec(ssh, "dnf install -y certbot python3-certbot-nginx 2>/dev/null || true")
    # Try to get cert - will fail if DNS not pointed yet, that's OK
    ssh_exec(ssh, "certbot --nginx -d autossl.trungtq.io.vn --non-interactive --agree-tos --email admin@trungtq.io.vn --redirect 2>/dev/null || true")

    # Start app with PM2
    log("Starting app with PM2...")
    ssh_exec(ssh, "pm2 delete autossl 2>/dev/null; true")
    ssh_exec(ssh, f"cd {APP_DIR} && pm2 start ecosystem.config.js")
    ssh_exec(ssh, "pm2 save")
    ssh_exec(ssh, "pm2 startup 2>/dev/null; true")

    # Verify
    log("Verifying...")
    time.sleep(3)
    ssh_exec(ssh, "pm2 status")
    ssh_exec(ssh, "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000")

    ssh.close()

    print("\n" + "=" * 50)
    print("  DEPLOYMENT COMPLETE!")
    print("=" * 50)
    print(f"\n  Domain: https://autossl.trungtq.io.vn")
    print(f"  IP:     http://{HOST}")
    print(f"\n  Allowed IPs:")
    print(f"    - 123.25.21.12")
    print(f"    - 172.31.98.188")
    print(f"    - 115.73.218.192")
    print(f"    - 103.57.222.245")
    print(f"    - 118.70.127.171")
    print(f"\n  SSH:  ssh -p {PORT} root@{HOST}")
    print(f"  Logs: pm2 logs autossl")
    print()

if __name__ == "__main__":
    main()

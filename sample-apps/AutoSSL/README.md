# AutoSSL Manager - SEO Hosting

Website hỗ trợ cài đặt SSL miễn phí (Let's Encrypt / AutoSSL) trên các server SEO Hosting.

## Tính năng

- **Dashboard server**: Hiển thị tất cả server SEO Hosting với trạng thái
- **Check DNS**: Kiểm tra IP domain, phân loại IP chính / IP riêng (addon)
- **Cài SSL tự động**:
  - **IP chính**: Chỉ cần cài qua cPanel (AutoSSL)
  - **IP riêng (addon)**: Cài qua cPanel (2083) trước, rồi cài qua WHM (2087)
- **Bulk processing**: Xử lý nhiều domain cùng lúc
- **Log real-time**: Theo dõi quá trình cài đặt

## Quy trình cài SSL

### Domain trỏ về IP chính (server IP)
1. Trigger AutoSSL → Hoàn tất

### Domain addon (IP riêng)
1. Trigger AutoSSL qua cPanel (2083)
2. Fetch certificate đã tạo
3. Install SSL qua WHM (2087)

## Cài đặt

```bash
npm install
npm run dev
```

Truy cập: http://localhost:3000

## Cấu hình

1. Chọn server từ dashboard
2. Nhập WHM API Token (tạo từ WHM → Development → Manage API Tokens)
3. Nhập cPanel username
4. Nhập danh sách domain
5. Check DNS → Install SSL

## Servers

| # | Server | IP | Status |
|---|--------|-----|--------|
| 1 | nethost-4911.inet.vn | 103.75.184.21 | Hoạt động |
| 2 | nethost-4311.inet.vn | 103.75.185.18 | Tạm ngưng |
| 3 | nethost-3711.inet.vn | 103.75.184.11 | Hoạt động |
| 4 | nethost-3111.inet.vn | 103.57.221.27 | Tạm ngưng |
| 5 | nethost-2611.inet.vn | 202.92.4.57 | Tạm ngưng |
| 6 | nethost-2111.inet.vn | 202.92.4.47 | Hoạt động |
| 7 | nethost-1011.inet.vn | 202.92.5.232 | Tạm ngưng |
| 8 | nethost-0911.inet.vn | 202.92.6.11 | Tạm ngưng |
| 9 | nethost-1611.inet.vn | 103.57.220.153 | Hoạt động |

## Deploy lên VPS (Cloud Server)

### Yêu cầu
- Ubuntu 20.04+ / Debian 11+
- Node.js 18+
- Domain trỏ về IP VPS

### Cách 1: Script tự động

```bash
# Copy source lên VPS
scp -r ./* user@your-vps:/var/www/autossl/

# SSH vào VPS và chạy
ssh user@your-vps
cd /var/www/autossl
bash deploy.sh
```

### Cách 2: Thủ công

```bash
# 1. Cài Node.js, PM2, nginx
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs nginx
sudo npm install -g pm2

# 2. Copy source & build
cd /var/www/autossl
npm install
npm run build

# 3. Cấu hình .env.local
cp .env.local.example .env.local
nano .env.local  # Thêm ALLOWED_IPS và ALLOWED_CIDRS

# 4. Setup nginx
sudo cp nginx.conf /etc/nginx/sites-available/autossl
sudo nano /etc/nginx/sites-available/autossl  # Sửa domain + IP allow
sudo ln -s /etc/nginx/sites-available/autossl /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 5. SSL cho domain (Let's Encrypt)
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d autossl.yourdomain.com

# 6. Start app
pm2 start ecosystem.config.js
pm2 save && pm2 startup
```

### Giới hạn IP truy cập

**2 lớp bảo vệ:**

1. **nginx** (`nginx.conf`) — chặn ở tầng web server:
```nginx
allow 103.75.184.0/24;   # iNET range
allow YOUR_OFFICE_IP;
deny all;
```

2. **Next.js middleware** (`.env.local`) — chặn ở tầng app:
```
ALLOWED_IPS=1.2.3.4,5.6.7.8
ALLOWED_CIDRS=103.75.184.0/24,202.92.4.0/24
```

## Lưu ý bảo mật

- WHM API Token được lưu trong localStorage của trình duyệt
- IP restriction qua **nginx + Next.js middleware** (2 lớp)
- Nên dùng HTTPS (Let's Encrypt) khi deploy public
- Restart sau khi thay đổi IP: `pm2 restart autossl`

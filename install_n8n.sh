#!/bin/bash

# Kiểm tra root
if [[ $EUID -ne 0 ]]; then
  echo "Script cần chạy với quyền root!"
  exit 1
fi

# Hàm random string
random_string() {
  local length=${1:-16}
  tr -dc 'a-zA-Z0-9' </dev/urandom | head -c $length
}

# Nhập domain
read -p "Nhập domain hoặc subdomain của bạn: " DOMAIN

# Kiểm tra domain trỏ về IP server
server_ip=$(curl -s https://api.ipify.org)
domain_ip=$(dig +short $DOMAIN)

if [ "$domain_ip" != "$server_ip" ]; then
  echo "Domain $DOMAIN chưa trỏ về IP máy này ($server_ip). Vui lòng cập nhật DNS rồi chạy lại."
  exit 1
fi

N8N_DIR="/home/n8n"
BACKUP_DIR="/home/n8n_backup"

# Tạo user/pass random cho PostgreSQL
PG_USER="n8nuser_$(random_string 6)"
PG_PASSWORD="$(random_string 20)"
PG_DB="n8n"

# Cài Docker nếu chưa có
if ! command -v docker >/dev/null 2>&1; then
  echo "Đang cài Docker và Docker Compose..."
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
else
  echo "Docker đã được cài đặt."
fi

# Tạo thư mục
mkdir -p "$N8N_DIR"
mkdir -p "$BACKUP_DIR"

# Tạo docker-compose.yml
cat > "$N8N_DIR/docker-compose.yml" <<EOF
version: "3"
services:
  postgres:
    image: postgres:14
    restart: always
    environment:
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      POSTGRES_DB: ${PG_DB}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - n8n_network

  n8n:
    image: n8nio/n8n
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${PG_DB}
      - DB_POSTGRESDB_USER=${PG_USER}
      - DB_POSTGRESDB_PASSWORD=${PG_PASSWORD}
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${DOMAIN}
      - GENERIC_TIMEZONE=Asia/Ho_Chi_Minh
      - N8N_DIAGNOSTICS_ENABLED=false
    volumes:
      - $N8N_DIR:/home/node/.n8n
    depends_on:
      - postgres
    networks:
      - n8n_network
    dns:
      - 8.8.8.8
      - 1.1.1.1

  caddy:
    image: caddy:2
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $N8N_DIR/Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n
    networks:
      - n8n_network

networks:
  n8n_network:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
  postgres-data:
EOF

# Tạo file Caddyfile
cat > "$N8N_DIR/Caddyfile" <<EOF
${DOMAIN} {
    reverse_proxy n8n:5678
}
EOF

# Đặt quyền
chown -R 1000:1000 "$N8N_DIR"
chmod -R 755 "$N8N_DIR"

# Khởi động docker-compose
cd "$N8N_DIR"
docker-compose up -d

# Ghi thông tin database ra file
cat > "$N8N_DIR/db-credentials.txt" <<EOF
PostgreSQL credentials for n8n:

Database: ${PG_DB}
User: ${PG_USER}
Password: ${PG_PASSWORD}

Please keep this file safe and do not share it with others.
EOF

# Tạo script menu quản lý hongtuan_n8n ở /usr/local/bin
cat > /usr/local/bin/hongtuan_n8n <<'EOS'
#!/bin/bash

N8N_DIR="/home/n8n"
BACKUP_DIR="/home/n8n_backup"
BACKUP_CONFIG="/home/n8n_backup/backup_config.conf"
CRON_JOB_COMMENT="# n8n_auto_backup"

mkdir -p "$BACKUP_DIR"

show_menu() {
  clear
  echo "======================================"
  echo "         QUẢN LÝ N8N PLATFORM         "
  echo "======================================"
  echo "1) Cập nhật n8n"
  echo "2) Khởi động lại n8n"
  echo "3) Backup database PostgreSQL thủ công"
  echo "4) Cấu hình backup tự động"
  echo "5) Xem logs n8n"
  echo "6) Thoát"
  echo "======================================"
}

read_backup_config() {
  if [ ! -f "$BACKUP_CONFIG" ]; then
    echo "enabled=false" > "$BACKUP_CONFIG"
    echo "frequency=1" >> "$BACKUP_CONFIG"
    echo "keep=10" >> "$BACKUP_CONFIG"
  fi
  source "$BACKUP_CONFIG"
}

write_backup_config() {
  cat > "$BACKUP_CONFIG" <<EOF
enabled=$enabled
frequency=$frequency
keep=$keep
EOF
}

setup_cron_backup() {
  crontab -l 2>/dev/null | grep -v "$CRON_JOB_COMMENT" > /tmp/crontab.tmp || true

  if [ "$enabled" = "true" ]; then
    if [ "$frequency" = "1" ]; then
      echo "0 2 * * * $0 backup_manual $keep # $CRON_JOB_COMMENT" >> /tmp/crontab.tmp
    elif [ "$frequency" = "2" ]; then
      echo "0 2,14 * * * $0 backup_manual $keep # $CRON_JOB_COMMENT" >> /tmp/crontab.tmp
    fi
  fi

  crontab /tmp/crontab.tmp
  rm /tmp/crontab.tmp
}

backup_manual() {
  local keep_backups=${1:-10}
  echo "Bắt đầu backup database PostgreSQL..."

  timestamp=$(TZ="Asia/Ho_Chi_Minh" date +%F_%H-%M-%S)
  container_id=$(docker-compose -f "$N8N_DIR/docker-compose.yml" ps -q postgres)

  if [ -z "$container_id" ]; then
    echo "Không tìm thấy container postgres. Vui lòng kiểm tra lại."
    return 1
  fi

  backup_file="$BACKUP_DIR/n8n_backup_${timestamp}.sql"
  docker exec -t "$container_id" pg_dumpall -c -U $(grep ^POSTGRES_USER= $N8N_DIR/docker-compose.yml | cut -d= -f2) > "$backup_file"
  if [ $? -eq 0 ]; then
    echo "Backup thành công: $backup_file"
  else
    echo "Backup thất bại."
    return 1
  fi

  backups_count=$(ls -1 "$BACKUP_DIR"/n8n_backup_*.sql 2>/dev/null | wc -l)
  if [ "$backups_count" -gt "$keep_backups" ]; then
    ls -1tr "$BACKUP_DIR"/n8n_backup_*.sql | head -n $(($backups_count - $keep_backups)) | xargs -r rm -f
    echo "Đã xóa các bản backup cũ để giữ $keep_backups bản."
  fi

  echo "Backup hoàn thành."
}

update_n8n() {
  echo "Cập nhật n8n..."
  cd "$N8N_DIR" || { echo "Không thể chuyển thư mục đến $N8N_DIR"; return 1; }
  docker-compose pull
  docker-compose down
  docker-compose up -d
  echo "Cập nhật hoàn thành."
}

restart_n8n() {
  echo "Khởi động lại dịch vụ n8n..."
  cd "$N8N_DIR" || { echo "Không thể chuyển thư mục đến $N8N_DIR"; return 1; }
  docker-compose restart
  echo "Khởi động lại hoàn thành."
}

show_logs() {
  cd "$N8N_DIR" || { echo "Không thể chuyển thư mục đến $N8N_DIR"; return 1; }
  docker-compose logs -f n8n
}

configure_backup() {
  read_backup_config
  while true; do
    clear
    echo "====== CẤU HÌNH BACKUP TỰ ĐỘNG ======"
    echo "Trạng thái backup tự động hiện tại: $( [ "$enabled" = "true" ] && echo "BẬT" || echo "TẮT" )"
    echo "Tần suất backup hiện tại: $frequency lần/ngày"
    echo "Số bản backup lưu giữ: $keep"
    echo ""
    echo "1) Bật backup tự động"
    echo "2) Tắt backup tự động"
    echo "3) Chọn tần suất backup (hiện: $frequency)"
    echo "4) Chọn số bản backup lưu giữ (hiện: $keep)"
    echo "5) Quay lại menu chính"
    echo "====================================="
    read -p "Chọn (1-5): " bchoice

    case $bchoice in
      1)
        enabled=true
        write_backup_config
        setup_cron_backup
        echo "Backup tự động đã được BẬT."
        sleep 2
        ;;
      2)
        enabled=false
        write_backup_config
        setup_cron_backup
        echo "Backup tự động đã được TẮT."
        sleep 2
        ;;
      3)
        echo "Chọn tần suất backup:"
        echo "1) 1 lần/ngày"
        echo "2) 2 lần/ngày"
        read -p "Nhập lựa chọn (1 hoặc 2): " freq_input
        if [[ "$freq_input" == "1" || "$freq_input" == "2" ]]; then
          frequency=$freq_input
          write_backup_config
          setup_cron_backup
          echo "Tần suất backup đã được cập nhật."
        else
          echo "Lựa chọn không hợp lệ."
        fi
        sleep 2
        ;;
      4)
        echo "Chọn số bản backup lưu giữ:"
        echo "1) 10 bản"
        echo "2) 20 bản"
        read -p "Nhập lựa chọn (1 hoặc 2): " keep_input
        if [ "$keep_input" == "1" ]; then
          keep=10
        elif [ "$keep_input" == "2" ]; then
          keep=20
        else
          echo "Lựa chọn không hợp lệ."
          sleep 2
          continue
        fi
        write_backup_config
        echo "Số bản backup lưu giữ đã được cập nhật."
        sleep 2
        ;;
      5)
        break
        ;;
      *)
        echo "Lựa chọn không hợp lệ."
        sleep 2
        ;;
    esac
  done
}

if [ "$1" == "backup_manual" ]; then
  keep_arg=$2
  backup_manual "$keep_arg"
  exit 0
fi

while true; do
  read_backup_config
  show_menu
  echo "Backup tự động hiện tại: $( [ "$enabled" = "true" ] && echo "BẬT" || echo "TẮT" ), tần suất: $frequency lần/ngày, lưu $keep bản"
  read -p "Chọn (1-6): " choice

  case $choice in
    1)
      update_n8n
      read -p "Nhấn Enter để tiếp tục..."
      ;;
    2)
      restart_n8n
      read -p "Nhấn Enter để tiếp tục..."
      ;;
    3)
      backup_manual "$keep"
      read -p "Nhấn Enter để tiếp tục..."
      ;;
    4)
      configure_backup
      ;;
    5)
      show_logs
      ;;
    6)
      echo "Thoát chương trình."
      exit 0
      ;;
    *)
      echo "Lựa chọn không hợp lệ."
      sleep 1
      ;;
  esac
done
EOS

# Đặt quyền thực thi cho script quản lý
chmod +x /usr/local/bin/hongtuan_n8n

echo ""
echo "==============================================="
echo "N8n đã được cài đặt thành công với PostgreSQL!"
echo ""
echo "Truy cập: https://${DOMAIN}"
echo ""
echo "Thông tin database đã lưu tại: $N8N_DIR/db-credentials.txt"
echo ""
echo "Gõ lệnh 'hongtuan_n8n' để mở menu quản lý n8n."
echo "==============================================="
echo ""

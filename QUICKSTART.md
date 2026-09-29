# Быстрый запуск CDN-стека

> Материал предназначен для обучения и работы с собственной либо явно авторизованной инфраструктурой.

## 1. Выбор компонентов

```bash
git clone https://github.com/indie-master/Turboflare_CDN_Setup_Guide.git
cd Turboflare_CDN_Setup_Guide
cp .env.example .env
nano .env
```

В `DEPLOY_COMPONENTS` можно указать любое сочетание:

```dotenv
DEPLOY_COMPONENTS=turboflare
DEPLOY_COMPONENTS=beeline
DEPLOY_COMPONENTS=turboflare,beeline
DEPLOY_COMPONENTS=turboflare,beeline,reality
```

Командная строка `--only` временно переопределяет это значение и не удаляет
конфигурации компонентов, не участвующих в текущем запуске:

```bash
sudo bash install.sh --only turboflare
sudo bash install.sh --only beeline
sudo bash install.sh --only turboflare,beeline,reality
```

## 2. Общие значения

```dotenv
ORIGIN_IP=203.0.113.10
STREAM_MAP_DIR=/etc/nginx/stream-map.d
CONFIG_PROFILE_NAME=LAB_PROFILE
```

Локальные порты компонентов должны различаться. Значения по умолчанию:

```text
TurboFlare: Nginx 8443, Xray 40112
Beeline:    Nginx 8444, Xray 4443
Reality:    Xray 2443
```

## 3. TurboFlare

Для `turboflare` задайте как минимум:

```dotenv
DOMAIN=cdn.example.com
NGINX_INTERNAL_PORT=8443
XRAY_XHTTP_PORT=40112
XRAY_INBOUND_TAG=xHTTP-TurboFlare
XHTTP_PATH=/static/getFile/video/segment.ts
```

TurboFlare использует `packet-up` и POST по умолчанию.

## 4. Beeline

Для `beeline` задайте:

```dotenv
BEELINE_ORIGIN_DOMAIN=origin-node.example.net
BEELINE_CDN_SYSTEM_DOMAIN=abc123xyz.a.trbcdn.net
BEELINE_CDN_CUSTOM_DOMAIN=cdn-node.example.net
BEELINE_NGINX_INTERNAL_PORT=8444
BEELINE_XRAY_XHTTP_PORT=4443
BEELINE_XRAY_INBOUND_TAG=xHTTP-Beeline
BEELINE_XHTTP_PATH=/api/uploadFile/
```

Beeline использует отдельный `packet-up + GET` inbound. Подробная настройка CDN,
DNS и сертификатов: [docs/BEELINE.md](docs/BEELINE.md).

## 5. Reality

Если включён `reality`, первый запуск автоматически сгенерирует ключевую пару,
short ID и случайный path. Если контейнер ноды называется не `remnanode`, укажите:

```dotenv
XRAY_KEYGEN_CONTAINER=имя-контейнера
```

## 6. Установка

```bash
chmod +x install.sh scripts/render.sh
sudo bash install.sh
```

Если установщик сообщает об отсутствующем stream include, добавьте внутрь
существующего `map $ssl_preread_server_name $backend`:

```nginx
include /etc/nginx/stream-map.d/*.map;
```

Не создавайте второй `stream {}` или второй публичный `listen 443`. После
изменения повторите установку.

## 7. Config Profile

Добавьте объекты из общего файла в массив `inbounds` профиля Remnawave:

```text
build/shared/xray-inbounds.json
```

Провайдерские файлы находятся здесь:

```text
build/turboflare/<DOMAIN>/
build/beeline/<BEELINE_ORIGIN_DOMAIN>/
build/reality/
```

Назначьте Config Profile ноде и проверьте нужные локальные порты:

```bash
ss -lntp | grep -E ':40112|:4443|:2443'
```

## 8. Remnawave Hosts

- TurboFlare: `build/turboflare/<DOMAIN>/remnawave-host-values.md`.
- Beeline: `build/beeline/<BEELINE_ORIGIN_DOMAIN>/remnawave-host-values.md`.
- Reality: `build/reality/remnawave-host-values.md`.

Для каждого CDN используйте `remnawave-xhttp-extra.json` из того же каталога:
TurboFlare и Beeline имеют несовместимые методы uplink и не должны использовать
один Extra.

## 9. Проверка

```bash
set -a
source .env
set +a

curl -4vk --resolve "$DOMAIN:443:$ORIGIN_IP" "https://$DOMAIN/"
curl -4vk --resolve "$BEELINE_ORIGIN_DOMAIN:443:$ORIGIN_IP" \
  "https://$BEELINE_ORIGIN_DOMAIN$BEELINE_XHTTP_PATH"
```

Подробности по TurboFlare и общей архитектуре: [README.md](README.md).

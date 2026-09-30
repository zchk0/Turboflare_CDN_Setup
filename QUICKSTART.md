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
DEPLOY_COMPONENTS=beget
DEPLOY_COMPONENTS=turboflare,beeline
DEPLOY_COMPONENTS=turboflare,beeline,beget,reality
```

Командная строка `--only` временно переопределяет это значение и не удаляет
конфигурации компонентов, не участвующих в текущем запуске:

```bash
sudo bash install.sh --only turboflare
sudo bash install.sh --only beeline
sudo bash install.sh --only beget
sudo bash install.sh --only turboflare,beeline,beget,reality
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
Beget:      Nginx 8445, Xray 10085
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

Режим origin-сертификата выбирается в `.env`:

```dotenv
BEELINE_ORIGIN_CERT_MODE=selfsigned   # или letsencrypt / existing
```

Для `letsencrypt` дополнительно задайте email и подтвердите условия ACME:

```dotenv
BEELINE_ACME_EMAIL=admin@example.com
BEELINE_ACME_AGREE_TOS=true
```

## 5. Beget

Для `beget` нужны отдельный origin-домен с A-записью на VPS и технический
домен `*.begetcdn.cloud`, выданный после создания ресурса:

```dotenv
BEGET_ORIGIN_DOMAIN=node-beget.example.net
BEGET_CDN_SYSTEM_DOMAIN=abc123.begetcdn.cloud
BEGET_CDN_CUSTOM_DOMAIN=
BEGET_NGINX_INTERNAL_PORT=8445
BEGET_XRAY_XHTTP_PORT=10085
BEGET_XRAY_INBOUND_TAG=xHTTP-Beget
BEGET_XHTTP_PATH=/
BEGET_ORIGIN_CERT_MODE=letsencrypt
BEGET_ACME_EMAIL=admin@example.com
BEGET_ACME_AGREE_TOS=true
```

Origin и CDN-домен нельзя совмещать: `BEGET_ORIGIN_DOMAIN` должен иметь
`A -> ORIGIN_IP`, а в Remnawave Host используется CDN-домен. Полная настройка
origin, панели Beget и Remnawave: [docs/BEGET.md](docs/BEGET.md).

## 6. Reality

Если включён `reality`, первый запуск автоматически сгенерирует ключевую пару,
short ID и случайный path. Если контейнер ноды называется не `remnanode`, укажите:

```dotenv
XRAY_KEYGEN_CONTAINER=имя-контейнера
```

## 7. Установка

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

## 8. Config Profile

Добавьте объекты из общего файла в массив `inbounds` профиля Remnawave:

```text
build/shared/xray-inbounds.json
```

Провайдерские файлы находятся здесь:

```text
build/turboflare/<DOMAIN>/
build/beeline/<BEELINE_ORIGIN_DOMAIN>/
build/beget/<BEGET_ORIGIN_DOMAIN>/
build/reality/
```

Назначьте Config Profile ноде и проверьте нужные локальные порты:

```bash
ss -lntp | grep -E ':40112|:4443|:10085|:2443'
```

## 9. Remnawave Hosts

- TurboFlare: `build/turboflare/<DOMAIN>/remnawave-host-values.md`.
- Beeline: `build/beeline/<BEELINE_ORIGIN_DOMAIN>/remnawave-host-values.md`.
- Beget: `build/beget/<BEGET_ORIGIN_DOMAIN>/remnawave-host-values.md`.
- Reality: `build/reality/remnawave-host-values.md`.

Для каждого CDN используйте `remnawave-xhttp-extra.json` из того же каталога:
TurboFlare использует POST, а Beeline и Beget — отдельные GET-профили со
своими padding-параметрами. Используйте Extra из каталога конкретного
компонента.

## 10. Проверка

```bash
set -a
source .env
set +a

curl -4vk --resolve "$DOMAIN:443:$ORIGIN_IP" "https://$DOMAIN/"
curl -4vk --resolve "$BEELINE_ORIGIN_DOMAIN:443:$ORIGIN_IP" \
  "https://$BEELINE_ORIGIN_DOMAIN$BEELINE_XHTTP_PATH"
curl -4kso /dev/null -m 5 -w 'beget origin: %{http_code}\n' \
  --resolve "$BEGET_ORIGIN_DOMAIN:443:$ORIGIN_IP" \
  "https://$BEGET_ORIGIN_DOMAIN$BEGET_XHTTP_PATH"
```

Для Beget ожидается HTTP `400` от голого XHTTP GET. Подробности по общей
архитектуре: [README.md](README.md).

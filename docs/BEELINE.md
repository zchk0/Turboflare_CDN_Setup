# Beeline CDN + Remnawave XHTTP

Beeline разворачивается отдельным компонентом и может работать одновременно с
TurboFlare и Direct Reality на одном публичном порту `443`.

## Архитектура

```text
Client -> Beeline CDN:443 -> ORIGIN_IP:443
       -> Nginx stream (SNI = BEELINE_ORIGIN_DOMAIN)
       -> Nginx HTTPS :8444
       -> Xray XHTTP :4443
```

Публичный `443` уже обслуживает общий Nginx stream-router. Поэтому отдельный
контейнер Nginx с `network_mode: host` и `listen 443` создавать нельзя.

## Переменные

```dotenv
DEPLOY_COMPONENTS=beeline

ORIGIN_IP=203.0.113.10
BEELINE_ORIGIN_DOMAIN=origin-node.example.net
BEELINE_CDN_SYSTEM_DOMAIN=abc123xyz.a.trbcdn.net
BEELINE_CDN_CUSTOM_DOMAIN=cdn-node.example.net

BEELINE_NGINX_INTERNAL_PORT=8444
BEELINE_XRAY_LISTEN_IP=127.0.0.1
BEELINE_XRAY_XHTTP_PORT=4443
BEELINE_XRAY_INBOUND_TAG=xHTTP-Beeline
BEELINE_XHTTP_PATH=/api/uploadFile/
```

Если custom-домен не используется, оставьте `BEELINE_CDN_CUSTOM_DOMAIN` пустым.
Host будет сгенерирован для технического домена Beeline.

## DNS

```text
BEELINE_ORIGIN_DOMAIN      A      ORIGIN_IP
BEELINE_CDN_CUSTOM_DOMAIN  CNAME  BEELINE_CDN_SYSTEM_DOMAIN
```

У одного имени не должно быть одновременно записей `A` и `CNAME`.

## Origin TLS

Доступны три режима. Для первого запуска можно использовать:

```dotenv
BEELINE_ORIGIN_CERT_MODE=selfsigned
```

В этом режиме проверка сертификата источника в Beeline должна быть выключена.
Установщик создаст сертификат для `BEELINE_ORIGIN_DOMAIN`.

Для автоматического выпуска доверенного сертификата через Certbot:

```dotenv
BEELINE_ORIGIN_CERT_MODE=letsencrypt
BEELINE_ACME_EMAIL=admin@example.com
BEELINE_ACME_AGREE_TOS=true
```

Перед запуском A-запись origin-домена должна указывать на `ORIGIN_IP`, а входящий
TCP/80 должен быть доступен из интернета. Установщик поставит Certbot, подготовит
HTTP-01 webroot, выпустит сертификат, подключит его к Nginx и создаст deploy-hook
для reload после продления.

Чтобы использовать уже существующий доверенный сертификат:

```dotenv
BEELINE_ORIGIN_CERT_MODE=existing
BEELINE_ORIGIN_CERT=/etc/letsencrypt/live/origin-node.example.net/fullchain.pem
BEELINE_ORIGIN_KEY=/etc/letsencrypt/live/origin-node.example.net/privkey.pem
```

В режимах `letsencrypt` и `existing` проверку сертификата источника в Beeline
можно включить после успешной установки.

## Установка

```bash
sudo bash install.sh --only beeline
```

Установщик создаст отдельные vhost, stream-map и артефакты:

```text
build/beeline/<BEELINE_ORIGIN_DOMAIN>/nginx-site.conf
build/beeline/<BEELINE_ORIGIN_DOMAIN>/nginx-stream-map-entry.map
build/beeline/<BEELINE_ORIGIN_DOMAIN>/xray-inbound.json
build/beeline/<BEELINE_ORIGIN_DOMAIN>/remnawave-xhttp-extra.json
build/beeline/<BEELINE_ORIGIN_DOMAIN>/remnawave-host-values.md
build/beeline/<BEELINE_ORIGIN_DOMAIN>/beeline-cdn-settings.md
build/shared/xray-inbounds.json
```

## Remnawave Config Profile

Beeline использует `packet-up + GET`. В шаблонах используются корректные для
Xray-core `26.7.28` поля:

```json
{
  "seqKey": "chunk_id",
  "seqPlacement": "query",
  "sessionIDKey": "X-Upload-Token",
  "sessionIDPlacement": "header",
  "uplinkHTTPMethod": "GET"
}
```

Поля `sessionKey`, `sessionPlacement` и `cMaxLifetimeMs` из исходной PDF-инструкции
не используются: они отсутствуют в конфигурационной схеме закреплённой версии
Xray.

Добавьте `build/shared/xray-inbounds.json` в Config Profile и назначьте профиль
ноде. При совместной установке файл уже содержит inbound всех выбранных
компонентов.

## Настройки источника Beeline

```text
Адрес источника: ORIGIN_IP:443
HTTPS к источнику: включено
SNI: BEELINE_ORIGIN_DOMAIN
Hostname к источнику: BEELINE_ORIGIN_DOMAIN
Передача исходного Host: выключена
```

Для первой проверки отключите cache на `BEELINE_XHTTP_PATH`, secure token,
AWS-авторизацию, ограничения доступа, CORS-проверки, HTTP/3 и оптимизации.

## Проверка

Сначала проверьте origin:

```bash
curl -4vk --resolve "$BEELINE_ORIGIN_DOMAIN:443:$ORIGIN_IP" \
  "https://$BEELINE_ORIGIN_DOMAIN$BEELINE_XHTTP_PATH"
```

Затем технический и custom CDN-домены:

```bash
curl -vk "https://$BEELINE_CDN_SYSTEM_DOMAIN$BEELINE_XHTTP_PATH"
curl -v "https://$BEELINE_CDN_CUSTOM_DOMAIN$BEELINE_XHTTP_PATH"
```

Ответ `400` от XHTTP endpoint подтверждает прохождение маршрута до Xray, но не
заменяет проверку полноценным клиентским подключением.

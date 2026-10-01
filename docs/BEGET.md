# Beget CDN + Remnawave XHTTP

Компонент `beget` настраивает origin-сервер для схемы **XHTTP packet-up +
uplinkHTTPMethod=GET** из [исходной инструкции](https://github.com/BobJustFry/WL-integration/blob/master/install_beget.md).
Он использует установленный на хосте Nginx и существующую Remnawave Node:
установщик не создаёт контейнер ноды и не меняет панель через API.

## Архитектура

```text
Клиент :443
  -> Beget CDN (*.begetcdn.cloud или custom-домен)
  -> HTTPS origin BEGET_ORIGIN_DOMAIN:443
  -> Nginx stream (SNI)
  -> Nginx HTTPS 127.0.0.1:BEGET_NGINX_INTERNAL_PORT
  -> Xray XHTTP 127.0.0.1:BEGET_XRAY_XHTTP_PORT
```

Beget получает отдельные SNI map, HTTPS vhost и Xray inbound. Поэтому его
можно включить вместе с TurboFlare, Beeline и Direct Reality на одном внешнем
порту `443`.

## Обязательное разделение доменов

| Роль | Пример | DNS |
|---|---|---|
| Origin | `node-beget.example.net` | `A -> ORIGIN_IP` |
| Технический CDN-домен | `abc123.begetcdn.cloud` | выдаёт Beget |
| Custom CDN-домен | `cdn.example.net` | alias на CDN по правилам Beget |

`BEGET_ORIGIN_DOMAIN` и клиентский CDN-домен должны различаться. Origin не
должен быть CNAME на `*.begetcdn.cloud`, иначе CDN будет обращаться сам к себе.
В Remnawave Host указывается CDN-домен, а не origin.

Для добавления custom-домена непосредственно в панели CDN исходная инструкция
требует добавить домен в Beget и делегировать его NS на Beget. Если DNS
обслуживается в другом месте, используйте технический `*.begetcdn.cloud` либо
создайте внешний CNAME на него у своего DNS-провайдера.

## Переменные

Добавьте `beget` в список компонентов и заполните секцию Beget:

```dotenv
DEPLOY_COMPONENTS=beget

ORIGIN_IP=203.0.113.10
BEGET_ORIGIN_DOMAIN=node-beget.example.net
BEGET_CDN_SYSTEM_DOMAIN=abc123.begetcdn.cloud
BEGET_CDN_CUSTOM_DOMAIN=
BEGET_ORIGIN_PORT=443

BEGET_NGINX_INTERNAL_PORT=8445
BEGET_XRAY_LISTEN_IP=127.0.0.1
BEGET_XRAY_XHTTP_PORT=10085
BEGET_XRAY_INBOUND_TAG=xHTTP-Beget
BEGET_XHTTP_PATH=/hls/stream.m3u8

BEGET_ORIGIN_CERT_MODE=letsencrypt
BEGET_ACME_ROOT=/var/www/beget-acme
BEGET_ACME_EMAIL=admin@example.com
BEGET_ACME_AGREE_TOS=true
BEGET_STREAM_MAP_FILE=beget.map
BEGET_SQUAD_NAME=Beget-CDN
```

Перед запуском `BEGET_ORIGIN_DOMAIN` должен иметь A-запись, точно совпадающую
с `ORIGIN_IP`. HTTP-01 также требует доступный извне TCP/80.

## Origin TLS

Рекомендуемый режим — `letsencrypt`. Установщик:

1. проверяет A-запись origin;
2. временно включает HTTP vhost для ACME webroot;
3. выпускает сертификат Certbot;
4. устанавливает постоянный HTTPS vhost;
5. создаёт deploy-hook с `nginx -t` и reload.

Дополнительно поддерживаются:

```dotenv
BEGET_ORIGIN_CERT_MODE=existing
BEGET_ORIGIN_CERT=/etc/letsencrypt/live/node-beget.example.net/fullchain.pem
BEGET_ORIGIN_KEY=/etc/letsencrypt/live/node-beget.example.net/privkey.pem
```

и `selfsigned`. Последний вариант требует отключить в CDN проверку
сертификата origin и не соответствует рекомендуемой схеме исходного гайда.

## Генерация и установка

Только проверить и сгенерировать файлы:

```bash
./scripts/render.sh --only beget
```

Установить Nginx vhost, SNI map и сертификат:

```bash
sudo bash install.sh --only beget
```

Результат:

```text
build/beget/<BEGET_ORIGIN_DOMAIN>/nginx-acme-bootstrap.conf
build/beget/<BEGET_ORIGIN_DOMAIN>/nginx-site.conf
build/beget/<BEGET_ORIGIN_DOMAIN>/nginx-stream-map-entry.map
build/beget/<BEGET_ORIGIN_DOMAIN>/xray-inbound.json
build/beget/<BEGET_ORIGIN_DOMAIN>/remnawave-xhttp-extra.json
build/beget/<BEGET_ORIGIN_DOMAIN>/remnawave-host-values.md
build/beget/<BEGET_ORIGIN_DOMAIN>/beget-cdn-settings.md
```

Если установщик попросит добавить stream include, поместите эту строку внутрь
существующего `map $ssl_preread_server_name $backend`:

```nginx
include /etc/nginx/stream-map.d/*.map;
```

Не создавайте второй `stream {}` или второй публичный `listen 443`.
Снаружи нужны TCP/80 и TCP/443. Порты `8445` и `10085` должны оставаться
доступными только на loopback; порт API Remnawave Node разрешайте только IP
панели.

## Remnawave

Добавьте объект из `xray-inbound.json` в массив `inbounds` нужного Config
Profile и назначьте профиль ноде. Затем создайте Host по значениям из
`remnawave-host-values.md` и вставьте JSON из `remnawave-xhttp-extra.json`.

Критичные значения:

- inbound: `xhttp`, `mode: packet-up`, `uplinkHTTPMethod: GET`;
- Path: `/hls/stream.m3u8` без завершающего `/`, одинаковый в inbound и Host;
- `sessionIdPlacement: query`, `sessionIdKey: x_session`;
- `seqPlacement: query`, `seqKey: x_seq`;
- padding: `xPaddingPlacement: header`, `xPaddingHeader: X-Cache`, `xPaddingMethod: tokenish`;
- Address, SNI и Host клиента: `BEGET_CDN_SYSTEM_DOMAIN` или custom CDN-домен;
- порт клиента: `443`;
- `Allow insecure`: выключен.

Origin Nginx принудительно передаёт Xray заголовок
`Host: BEGET_ORIGIN_DOMAIN`, соответствующий server-side inbound.

## Настройка ресурса в Beget

Рабочий формат запросов проверен на реальном ресурсе: файловый путь, сессия и
номер пакета в query, padding в заголовке без URL. В проверках путь со слешем
в конце и полный URL в `X-Cache` возвращали CDN `403`. Поэтому `queryInHeader`
для Beget больше не используется. Это результат проверок, а не расшифровка
внутреннего `x-reason-code: 7` провайдера.

### Обновление ранее установленного Beget

`git pull` не меняет существующий `.env`. Замените в нём старое
`BEGET_XHTTP_PATH=/` на `BEGET_XHTTP_PATH=/hls/stream.m3u8`, затем выполните:

```bash
bash scripts/render.sh --only beget
```

Обновите только Beget inbound в Config Profile, сохранив пользователей и другие
inbound. В соответствующем Remnawave Host задайте новый Path и замените Extra
содержимым сгенерированного `remnawave-xhttp-extra.json`. Согласованно обновите
обе стороны: старые клиенты с `/` или `queryInHeader` несовместимы с новыми
настройками. Обновите подписку и проверьте экспорт конфигурации клиента.

Установщик не обновляет Remnawave автоматически. Для уже установленного vhost
с `location /` переустановка Nginx и перевыпуск сертификата не нужны. При новом
развёртывании используйте `bash install.sh --only beget`.

В панели Beget создайте CDN-ресурс с источником типа **доменное имя** и
значением `BEGET_ORIGIN_DOMAIN`. Это рекомендуемый вариант для SNI-router.
В исходной инструкции отмечено, что источник ресурса после создания не
редактируется, поэтому проверьте его до сохранения.

Задайте следующие параметры:

| Раздел | Значение |
|---|---|
| Кэш CDN | выключен или минимум 1 секунда |
| Кэш браузера | выключен |
| Всегда онлайн | выключен |
| Следовать редиректу origin | выключен |
| Игнорировать query params | выключен |
| Secure links и ограничения Referer/IP/User-Agent | выключены для первого теста |
| HTTP/3 | выключен |
| Gzip | выключен |
| Оптимизация больших файлов / slice | выключена |
| Методы | все либо `GET, HEAD, OPTIONS` |
| CORS/перезапись response headers | выключены |

Источник по IP не рекомендуется: HTTP-заголовок `Host` появляется только
после TLS-маршрутизации, а общий stream-router выбирает backend раньше — по
TLS SNI. Если используете IP, Beget должен отправлять и SNI, и `Host`, равные
`BEGET_ORIGIN_DOMAIN`.

Полная памятка с подставленными значениями будет в
`beget-cdn-settings.md` внутри каталога сборки.

## Проверка

Сначала origin, затем CDN:

```bash
set -a
source .env
set +a

curl -4kso /dev/null -m 5 -w 'origin: %{http_code}\n' \
  --resolve "$BEGET_ORIGIN_DOMAIN:443:$ORIGIN_IP" \
  "https://$BEGET_ORIGIN_DOMAIN$BEGET_XHTTP_PATH"

curl -kso /dev/null -m 5 -w 'cdn: %{http_code}\n' \
  "https://${BEGET_CDN_CUSTOM_DOMAIN:-$BEGET_CDN_SYSTEM_DOMAIN}$BEGET_XHTTP_PATH"

ss -lntp | grep -E ':443|:8445|:10085'
sudo certbot renew --dry-run --cert-name "$BEGET_ORIGIN_DOMAIN"
```

Для голого GET на XHTTP endpoint ожидается HTTP `400`; это подтверждает
маршрут до Xray, но не заменяет тест реального клиентского подключения.

## Диагностика

| Симптом | Что проверить |
|---|---|
| CDN `502`/`403`, origin `400` | источник ресурса, origin SNI/Host, TLS и firewall |
| Голый GET проходит, клиент получает `403` | фактический Path без завершающего `/`, session/seq в query, `xPaddingPlacement: header` на обеих сторонах; проверить экспорт клиента |
| Origin `000` | A-запись, TCP/443 и `nginx -t` |
| CDN `000` | состояние ресурса, баланс и завершение применения настроек |
| Edge `405` | GET присутствует в разрешённых методах |
| Обрыв через 60–120 секунд | HTTP/3, Always Online, slicing; затем timeout у поддержки Beget |
| `414 URI Too Large` | загружен ли Beget vhost с увеличенными header buffers |
| Certbot не выпускает сертификат | A-запись, TCP/80 и ACME webroot |

Источники: [руководство интеграции Beget](https://github.com/BobJustFry/WL-integration/blob/master/install_beget.md),
[официальная документация Beget CDN](https://beget.com/ru/kb/manual/cdn).

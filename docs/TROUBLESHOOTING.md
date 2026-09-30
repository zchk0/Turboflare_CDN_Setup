# Диагностика CDN + Remnawave XHTTP

## Базовый сбор состояния

```bash
set -a
source .env
set +a

dig +short NS "$DOMAIN"
dig +short A "$DOMAIN"
ss -lntp | grep -E ':443|:8443|:8444|:8445|:40112|:4443|:10085|:2443'
sudo nginx -t

curl -4vk --resolve "$DOMAIN:443:$ORIGIN_IP" "https://$DOMAIN/"
curl -4v "https://$DOMAIN/"

tail -n 50 "/var/log/nginx/$DOMAIN.access.log"
tail -n 50 "/var/log/nginx/$DOMAIN.error.log"

cd /opt/remnanode
docker compose logs --since=15m remnanode \
  | grep -aEi 'xHTTP-TurboFlare|xHTTP-Yandexcloud|40112|2443|error|failed'
```

## `502 Bad Gateway`

Nginx не подключается к Xray. Проверьте:

- Config Profile сохранён и назначен ноде;
- Xray запущен;
- inbound слушает `127.0.0.1:40112`;
- порт совпадает с `proxy_pass` Nginx;
- контейнер Remnawave Node использует ожидаемую сетевую архитектуру.

## `413 Request Entity Too Large`

```nginx
client_max_body_size 4m;
```

Серверный baseline допускает POST до 3 000 000 байт, хотя облегчённый клиент обычно отправляет 256–512 КБ.

## Мобильное соединение завершается после нагрузки или сна

1. Используйте `packet-up` и Extra из `templates/remnawave-xhttp-extra.json.template`.
2. Оставьте ALPN `h2`.
3. Убедитесь, что клиент использует актуальный Xray-core.
4. Обновите профиль после изменения Host.
5. Проверьте нагрузку, блокировку экрана и смену сети отдельно.

Если завершается процесс приложения, серверный timeout не устранит причину. Нужны версия приложения, встроенного ядра и клиентский журнал. См. [IOS-STABILITY.md](IOS-STABILITY.md).

## GET-вариант не работает

Сначала определите компонент: TurboFlare использует POST, а Beeline и Beget —
GET. Не переносите Extra между их Host.

Для TurboFlare верните:

- `mode: packet-up`;
- POST по умолчанию — не задавайте `uplinkHTTPMethod: GET`;
- `sessionIDPlacement: query`;
- `seqPlacement: query`;
- ключи `auth` и `chunk_id`;
- исходный Xray inbound и облегчённый Host Extra из шаблонов.

Nginx при возврате к POST/query менять не требуется.

Для Beget проверьте:

- `uplinkHTTPMethod: GET`, `xPaddingKey: _dc`, `xPaddingHeader: X-Cache`;
- Path `/` одновременно в inbound и Host;
- GET разрешён в ресурсе CDN;
- HTTP/3, кэш и оптимизация больших файлов выключены;
- используются файлы из `build/beget/$BEGET_ORIGIN_DOMAIN/`.

## Публичный домен показывает origin-сертификат

Публичная A-запись должна указывать на edge TurboFlare.

```bash
dig +short A "$DOMAIN"
```

## Direct origin работает, TurboFlare возвращает ошибку

Проверьте:

- origin IP и порт `443`;
- HTTPS к источнику;
- завершение делегирования;
- перевод трафика;
- учёт query string;
- отсутствие cache для XHTTP endpoint.

## Endpoint отдаёт статическую страницу

`XHTTP_PATH` не совпадает в одном из трёх мест:

1. `xhttpSettings.path` в Xray;
2. `location ^~` в Nginx;
3. Path в Remnawave Host.

## TLS error

- Address = `DOMAIN`;
- SNI = `DOMAIN`;
- Host = `DOMAIN`;
- Security Layer = TLS;
- Allow insecure = OFF;
- Port = 443.

```bash
openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## Direct Reality не подключается

Проверьте четыре уровня по очереди:

```bash
grep -F -- "${REALITY_SERVER_NAMES%%,*}" "/etc/nginx/stream-map.d/$REALITY_STREAM_MAP_FILE"
ss -lntp | grep ":$REALITY_PORT"
sudo nginx -t
xray tls ping "${REALITY_TARGET%:*}"
```

- внешний Address ведёт прямо на `ORIGIN_IP`, а не на TurboFlare edge;
- клиент использует порт `443` и одно из значений `REALITY_SERVER_NAMES` как SNI;
- Password/Public key и short ID совпадают со значениями `.env`;
- Reality inbound содержит `acceptProxyProtocol: true`;
- глобальный stream server содержит `ssl_preread on` и `proxy_protocol on`.

Порт `2443` не нужно открывать в firewall: соединение к нему создаёт локальный Nginx.

## Соединение создаётся без передачи данных

Если routing rules перечисляют `inboundTag`, добавьте:

```json
"inboundTag": ["xHTTP-TurboFlare", "xHTTP-Beeline", "xHTTP-Yandexcloud"]
```

Убедитесь, что выбранный `outboundTag` существует на этой ноде.

## Host отсутствует в выдаче

Проверьте Host visibility, Config Profile, выбранный inbound, Internal Squad и обновление профиля на клиенте.

## `grep: binary file matches`

```bash
docker compose logs --tail=300 remnanode \
  | grep -aEi 'error|failed|xhttp|40112'
```

## Warning `creating new one`

```text
Inbound xHTTP-TurboFlare not found in inboundsHashMap, creating new one
```

Первое такое сообщение означает регистрацию inbound. Ошибка — последующий отказ запуска Xray или отсутствие listener.

## Проверка сгенерированных файлов

```bash
jq empty "build/turboflare/$DOMAIN/xray-inbound.json"
jq empty "build/beeline/$BEELINE_ORIGIN_DOMAIN/xray-inbound.json"
jq empty "build/beget/$BEGET_ORIGIN_DOMAIN/xray-inbound.json"
jq empty "build/reality/xray-inbound.json"
jq 'length >= 1' -e "build/shared/xray-inbounds.json"
jq empty "build/turboflare/$DOMAIN/remnawave-xhttp-extra.json"
jq empty "build/beeline/$BEELINE_ORIGIN_DOMAIN/remnawave-xhttp-extra.json"
jq empty "build/beget/$BEGET_ORIGIN_DOMAIN/remnawave-xhttp-extra.json"
jq empty "build/reality/client-credentials.json"

grep -RFn -- "$XHTTP_PATH" "build/turboflare/$DOMAIN"
grep -RFn -- "$BEELINE_XHTTP_PATH" "build/beeline/$BEELINE_ORIGIN_DOMAIN"
grep -RFn -- "$BEGET_XHTTP_PATH" "build/beget/$BEGET_ORIGIN_DOMAIN"
grep -RFn -- "$REALITY_PORT" "build/reality"
```

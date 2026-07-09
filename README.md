# CDN-мост для Remnawave через XHTTP (VK Cloud CDN)

Скрипт `setup-cdn-bridge.sh` автоматизирует всю серверную часть
CDN-моста для обхода блокировок: nginx, установка ноды Remnawave
(`remnanode`) и генерацию готовых JSON-кусков для панели. То, что нельзя
сделать с сервера — веб-мастер VK Cloud CDN и UI панели Remnawave — этот
гайд описывает по шагам, с точным указанием, что куда копировать.

## Архитектура

```
клиент ──TLS(CDN-серт)──► VK Cloud CDN edge (личный домен, CNAME)
                              │  proxy_pass HTTP (plain) на источник, порт 80
                              ▼
                origin-сервер :80 (nginx, БЕЗ TLS)
                              │  proxy_pass + секретный заголовок
                              ▼
                 Xray XHTTP-инбаунд, 127.0.0.1:5447, security: none
                              │
                              ▼
                     outbound → боевой сервер / WARP
```

TLS есть только между клиентом и CDN. Между CDN и origin — голый HTTP,
это не снижает безопасность (CDN и так видит расшифрованный трафик — это
его роль), зато убирает лишний сертификат и точку отказа.

## Что нужно перед началом

| Что | Где взять |
|---|---|
| Чистый VPS, Ubuntu 22.04/24.04, root-доступ | любой хостинг, 1 CPU/1GB RAM достаточно |
| Домен для origin-сервера | поддомен, на который вы можете добавить A-запись |
| Домен для CDN-фронта | второй поддомен/домен, желательно не связанный по имени с origin (см. раздел OPSEC в конце) |
| Аккаунт VK Cloud с подключённым сервисом CDN | cloud.vk.com → раздел CDN |
| Доступ к панели Remnawave | своя установка панели |
| Exit-сервер (боевая нода) ИЛИ готовность временно выйти через WARP | опционально на старте, мост можно поднять и без него |

---

## Запуск скрипта

```bash
git clone <ваш форк/репозиторий>
cd <репозиторий>
chmod +x setup-cdn-bridge.sh
sudo bash setup-cdn-bridge.sh
```

Появится меню на 4 этапа. Их можно проходить по одному (`nginx`, `node`,
`files`, `check` как аргумент) или все сразу (`all`). Между запусками
состояние сохраняется в `/root/.cdn-bridge/state.env` — если что-то
прервалось или нужно поменять только один параметр, скрипт предложит уже
введённые значения по умолчанию.

```bash
sudo bash setup-cdn-bridge.sh nginx   # этап 1
sudo bash setup-cdn-bridge.sh node    # этап 2
sudo bash setup-cdn-bridge.sh files   # этап 3
sudo bash setup-cdn-bridge.sh check   # этап 4
```

---

## Этап 1 — `nginx`

Спросит:
- **Домен origin-сервера** — например `origin.example.com`. Должен уже
  резолвиться A-записью на IP этого VPS (добавьте запись у своего
  DNS-провайдера/регистратора до запуска, либо прямо сейчас в соседней
  вкладке).
- **Путь XHTTP-инбаунда** — по умолчанию `/api/upload/chunk`. Можно
  оставить как есть или задать свой, похожий на реальный API-путь (не
  `/vless`, не `/xhttp` — то, что явно палит назначение).
- **Локальный порт Xray** — по умолчанию `5447`, менять нужно только
  если он у вас уже занят чем-то другим.

Дальше скрипт сам:
1. Ставит `nginx`, `ufw`, `dnsutils`.
2. Генерирует случайный `ORIGIN_SECRET` (или предлагает переиспользовать
   сохранённый, если этап уже запускался раньше).
3. Открывает 22 и 80 порты в firewall.
4. Проверяет, что домен резолвится именно на IP этого сервера.
5. Пишет конфиг `/etc/nginx/sites-available/origin` — слушает 80,
   проверяет заголовок `X-Origin-Secret`, проксирует на локальный порт
   Xray.
6. Делает `nginx -t` и, если синтаксис верный, `systemctl reload nginx`.
7. Прогоняет пробный `curl`: без секрета должен быть `403`, с секретом —
   `502` (это нормально, Xray ещё не поднят — он появится на этапе 2).

**Сохраните секрет**, который скрипт напечатает — он ещё пригодится в
шаге VK Cloud CDN (ниже) и в этапе 3.

---

## Этап 2 — `node`

Спросит:
- **`NODE_PORT`** — порт, которым панель управляет нодой, по умолчанию
  `2222`.
- **`SECRET_KEY`** — можно оставить пустым и вернуться к этому шагу
  позже.

Перед вводом `SECRET_KEY` нужно зайти в панель Remnawave:

> **Панель → Nodes → Add Node**
> Укажите адрес этого VPS и порт `2222` (или тот, что задали выше).
> Панель покажет `SECRET_KEY` **один раз** — скопируйте его целиком.

Вставьте скопированное значение в приглашение скрипта. Дальше скрипт сам:
1. Ставит Docker, если его ещё нет.
2. Пишет `/opt/remnanode/docker-compose.yml` с вашим `NODE_PORT` и
   `SECRET_KEY`.
3. Поднимает контейнер `docker compose up -d`.
4. Проверяет, что контейнер в статусе `running`.

Если `SECRET_KEY` не вводили — скрипт подготовит `docker-compose.yml` с
плейсхолдером и подскажет команду для ручного запуска после того, как вы
его получите.

**Проверка:** в панели, раздел Nodes, статус этой ноды должен смениться
на **online** в течение 1-2 минут после запуска контейнера.

**Firewall для NODE_PORT:** если панель на другом сервере, ограничьте
доступ только её IP:
```bash
ufw allow from <IP_ПАНЕЛИ> to any port 2222 proto tcp
```

---

## Этап 3 — `files`

Спросит:
- **Домен CDN-фронта** (например `api.example.com`) — тот, что будете
  указывать в VK Cloud CDN как «Персональный домен» (следующий раздел).

Генерирует три файла в `/root/.cdn-bridge/`:

| Файл | Куда копировать в панели |
|---|---|
| `config-profile-inbound.json` | Config Profiles → профиль вашей ноды → в массив `inbounds` |
| `routing-outbound-direct.json` | Config Profiles → тот же профиль → в `outbounds`/`routing` (временная заглушка `DIRECT`, см. раздел про exit-сервер ниже) |
| `host-xhttp-extra.json` | Hosts → Add Host → поле **xHTTP extra params** |

### Куда именно вставлять `config-profile-inbound.json`

Откройте JSON-редактор Config Profile вашей ноды в панели. Если профиль
уже существует (например, там есть боевой инбаунд с другим протоколом) —
добавьте содержимое файла как **ещё один элемент массива `inbounds`**,
рядом с уже существующими, не заменяя их:

```json
{
  "inbounds": [
    { "существующий инбаунд, не трогать": "..." },
    { "tag": "RU-XHTTP-CDN", "...содержимое из файла...": "..." }
  ]
}
```

Если профиля ещё нет — создайте новый (**Config Profiles → Create**),
вставьте содержимое `config-profile-inbound.json` в `inbounds` и
содержимое `routing-outbound-direct.json` (поля `outbounds` и `routing`)
рядом на том же уровне JSON. После сохранения привяжите профиль к ноде,
если это не сделалось автоматически.

**После любого изменения Config Profile — обязательно нажмите
reload/restart для ноды** (кнопка в панели, обычно с иконкой
перезапуска). Без этого шага сохранённые изменения не применяются на
самой ноде — это отдельное действие в Remnawave, не автоматическое.

### Куда вставлять `host-xhttp-extra.json`

**Hosts → Add Host**, заполните поля формы:

| Поле формы | Значение |
|---|---|
| SNI / Хост | ваш CDN-домен, например `api.example.com` |
| Путь | тот же путь, что задали на этапе 1 |
| Security Layer | `TLS` |
| ALPN | `h2,http/1.1` |
| Отпечаток (fingerprint) | `chrome` |
| Инбаунд | `RU-XHTTP-CDN` |

Рядом с полем «Путь» обычно есть отдельная иконка/кнопка для JSON-поля
**xHTTP extra params** — откройте её и вставьте туда содержимое
`host-xhttp-extra.json` целиком (это отдельное окно, не то же самое, что
поле «Путь» в основной форме).

---

## Настройка ресурса в VK Cloud CDN — по шагам

Заходите в консоль VK Cloud → **CDN** → **Создать ресурс**.

### Шаг «Настройка доступа и протокола»

- **Доступ к контенту конечным пользователям** — включить (тумблер
  вправо).
- **Протокол взаимодействия с источником** — выбрать **HTTP** (не HTTPS,
  не «HTTP и HTTPS»).

### Шаг «Конфигурация источников и доменов»

- **Запрос контента** — «С одного источника».
- **Источник контента** — `http://<ваш ORIGIN_DOMAIN из этапа 1>`,
  например `http://origin.example.com`.
- **Персональный домен** — тот же CDN-домен, что вводили на этапе 3,
  например `api.example.com`. Требования: только домен, без схемы и
  пути, латиница/цифры/точки/дефисы, до 255 символов, поддомен до 63.
  **После создания ресурса это поле нельзя изменить** — при ошибке
  придётся создавать ресурс заново.
- После ввода домена появится блок с CNAME-записью вида
  `cl-XXXXXXXX.service.cdn.msk.vkcs.cloud` — скопируйте, понадобится
  для DNS (следующий раздел).
- **Изменение заголовка Host** — выбрать **«Кастомный»**, вписать туда
  ваш `ORIGIN_DOMAIN` (тот же, что в «Источнике контента», без
  `http://`). Без этого шага nginx не сможет правильно сматчить входящий
  запрос — сервер будет отвечать ошибкой независимо от остальных
  настроек.

### Шаг «Настройки шифрования»

- **SSL-сертификат** — «Let's Encrypt». VK Cloud сам выпустит и продлит
  сертификат для вашего CDN-домена.

### Если есть шаг «Заголовки к источнику» / «Custom headers»

Добавьте заголовок:
```
X-Origin-Secret: <секрет, который скрипт напечатал на этапе 1>
```

Нажмите **Создать ресурс**.

---

## DNS

Добавьте CNAME-запись для CDN-домена:

```
Тип: CNAME
Имя: api (или как назвали поддомен)
Значение: cl-XXXXXXXX.service.cdn.msk.vkcs.cloud   (из VK Cloud, шаг выше)
Proxy/облако: ВЫКЛЮЧЕНО (DNS only)
```

Если DNS у Cloudflare или похожего провайдера — обязательно **DNS only**,
не «Proxied»: иначе TLS будет терминировать не VK Cloud CDN, а прокси
вашего DNS-провайдера, и всё сломается.

Подождите 5-15 минут на распространение, проверьте:
```bash
dig +short api.example.com CNAME
```

---

## Служебный пользователь

Не используйте UUID случайного клиента для тестов и для outbound на
боевую ноду — заведите отдельного:

**Панель → Users → Create User**
- Username: `svc-cdn-bridge`
- Expire at: без ограничения / далёкая дата
- Traffic limit: unlimited
- Не привязывать к Internal Squad, который видят обычные клиенты

Для тестового клиентского конфига и для outbound берите поле
**`vlessUuid`** этого юзера, **не** `uuid` аккаунта — это разные значения
в Remnawave, и перепутать их — самая частая причина, по которой всё
выглядит настроенным правильно, но сервер отвечает
`invalid request user id`.

---

## Этап 4 — `check`

Прогоняет:
1. `curl` до origin напрямую с секретным заголовком.
2. `curl` через CDN-домен (если он уже был указан на этапе 3).
3. Печатает итоговый чеклист всех ручных шагов с уже подставленными
   вашими значениями (домены, секрет) — удобно свериться, ничего не
   упустив.

---

## Куда должен выходить трафик (exit-сервер)

Сразу после этапов 1-4 мост технически работает, но `outbound` в
`routing-outbound-direct.json` — это `DIRECT`, то есть трафик клиента
выходит прямо с origin-сервера, без второго прыжка на настоящий VPN.
Для реального обхода блокировок нужен второй сервер.

### Если у вас уже есть боевая нода

В Config Profile добавьте outbound с параметрами боевой ноды (протокол
зависит от того, что там настроено — VLESS+Reality, Shadowsocks и т.д.),
и в `routing.rules` смените `outboundTag` для `RU-XHTTP-CDN` с `DIRECT`
на тег этого нового outbound. Для аутентификации на боевой ноде
используйте `vlessUuid` того же служебного пользователя.

### Если пока нет второго сервера — бесплатный Cloudflare WARP

```bash
apt install -y wireguard resolvconf
curl -fsSL https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_amd64 -o /usr/local/bin/wgcf
chmod +x /usr/local/bin/wgcf
cd /root && wgcf register --accept-tos && wgcf generate
cp wgcf-profile.conf /etc/wireguard/warp.conf
wg-quick up warp && systemctl enable wg-quick@warp
curl --interface warp https://cloudflare.com/cdn-cgi/trace | grep warp   # ждём warp=on
```

Добавьте в `outbounds` Config Profile:
```json
{
  "tag": "WARP",
  "protocol": "freedom",
  "settings": { "domainStrategy": "UseIP" },
  "streamSettings": { "sockopt": { "interface": "warp", "tcpFastOpen": true } }
}
```
И смените `outboundTag` в routing на `WARP`.

Ограничение: общий IP-пул Cloudflare, не выделенный сервер — скорость и
репутация IP не гарантированы, но подходит для старта без затрат.

---

## Диагностика — если что-то не работает

Логи для реальной диагностики — не `docker logs remnanode` (там только
служебные события панели), а файлы, заданные в `log.error`/`log.access`
Config Profile. Добавьте (и не забудьте, что `/var/log/remnanode` уже
смонтирован томом в `docker-compose.yml`, созданном на этапе 2):

```json
"log": {
  "loglevel": "debug",
  "access": "/var/log/remnanode/access.log",
  "error": "/var/log/remnanode/error.log"
}
```

| Симптом | Причина | Фикс |
|---|---|---|
| `curl` до origin — `Connection refused` | nginx не запущен | `systemctl status nginx`, перезапустить этап `nginx` |
| Через CDN — `502` с заголовками edge CDN (не вашего nginx, без версии/ОС) | Неверный протокол/порт источника в VK Cloud | Проверить шаг «Конфигурация источников» — должен быть HTTP |
| Через CDN — `403` от вашего nginx | Секретный заголовок не долетает от клиента | Проверить `headers` в `host-xhttp-extra.json`, что он реально вставлен в панели |
| В `error.log` — `invalid request user id` | Использован `uuid` вместо `vlessUuid` | Взять `vlessUuid` из ссылки подписки служебного юзера |
| `bad status code:405` | CDN не пропускает POST | Убедиться, что `uplinkHTTPMethod: "GET"` есть и на сервере, и на клиенте |
| `failed to validate host` | Поле `host` задано в `xhttpSettings` и конфликтует с тем, что форвардит nginx | В файлах, которые генерирует скрипт, поля `host` нет намеренно — не добавляйте его |
| `stream error... INTERNAL_ERROR` после успешного начала | CDN обрывает долгий поток | Проверить `noSSEHeader: true` на обеих сторонах |
| Правки в панели визуально сохранены, но ничего не меняется | Забыт reload ноды | Нажать reload/restart для ноды в панели после каждого сохранения Config Profile |
| Приложение (Happ и т.п.) показывает «n/a» без деталей | Неинформативный статус, не диагностика | Тестировать отдельным Xray-клиентом с `loglevel: debug`, не полагаться на статус в приложении |

Пример команды для ручного теста через реальный CDN (замените
`<vlessUuid>` на значение служебного юзера):

```bash
cat > /root/client-test.json << 'EOF'
{
  "log": { "loglevel": "debug" },
  "inbounds": [{ "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
    "settings": { "auth": "noauth", "udp": true } }],
  "outbounds": [{
    "protocol": "vless",
    "settings": { "vnext": [{ "address": "api.example.com", "port": 443,
      "users": [{ "id": "<vlessUuid>", "encryption": "none" }] }] },
    "streamSettings": {
      "network": "xhttp", "security": "tls",
      "tlsSettings": { "serverName": "api.example.com", "alpn": ["h2","http/1.1"], "fingerprint": "chrome" },
      "xhttpSettings": {
        "path": "/api/upload/chunk", "mode": "packet-up",
        "extra": {
          "uplinkHTTPMethod": "GET", "noSSEHeader": true,
          "headers": { "X-Origin-Secret": "<ORIGIN_SECRET>" },
          "xPaddingKey": "hash", "xPaddingHeader": "X-Client-Version",
          "xPaddingMethod": "tokenish", "xPaddingObfsMode": true,
          "xPaddingPlacement": "queryInHeader",
          "xmux": { "cMaxReuseTimes": 1000, "maxConcurrency": "16-32", "maxConnections": 0,
                     "hKeepAlivePeriod": 20000, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000" }
        }
      }
    }
  }]
}
EOF

docker run --rm --network host -v /root/client-test.json:/etc/xray/config.json \
  --name xray-test teddysun/xray xray run -c /etc/xray/config.json &

sleep 2
curl -x socks5h://127.0.0.1:10808 https://ifconfig.me -v --max-time 15
docker stop xray-test
```

Если curl вернул IP — мост рабочий целиком.

---

## Известные ограничения

- **ToS CDN-провайдера.** Постоянный VPN-туннель — не то, для чего
  формально предназначены CDN-сервисы. Держите боевую selfsteal-ноду как
  фолбэк в подписке на случай ограничения ресурса.
- **Секретный заголовок — не полноценный ACL**, только защита от
  случайных сканов IP. Для строгой изоляции нужен allowlist по
  IP-диапазонам CDN на firewall origin, если провайдер их публикует.
- **Домены origin и CDN-фронта на одном родительском домене** — логи
  Certificate Transparency публично палят связь между ними. Для лучшей
  маскировки используйте разные домены/регистраторы.
- **XHTTP не имеет стабильной официальной спецификации** — набор рабочих
  параметров в этом гайде подобран эмпирически для связки с VK Cloud CDN
  и может отличаться для других CDN-провайдеров.

# Миграция на XHTTP — runbook

> Цель: уйти от связки `Reality:443 + gRPC:2053` к более чистой архитектуре на основе
> XHTTP. Документ написан в режиме «у меня уже всё горит, не дай облажаться».
> Каждый шаг **обратим**, рестарты xray предупреждаются, безопасные сети (selfheal +
> memguard) активны.

## Когда делать миграцию

**НЕ срочно**. Делать только если:
1. Reality на :443 начнёт регулярно флапать (observatory `proxy-reality dead` в
   `error.log` чаще раза в час), ИЛИ
2. Хочется упростить архитектуру (выкинуть нестандартный порт 2053, остаться на
   одном :443).

Если за последнюю неделю `proxy-reality dead` событий **0** и оба outbound'а
держатся — **сидим, не трогаем**.

## Текущее состояние

- **Клиент (роутер)**: 2 outbound'а в balancer'е `vpn-balancer` (strategy: random):
  - `proxy-reality` — VLESS+Reality+Vision на <<VLESS_SERVER>>:443
  - `proxy-grpc` — VLESS+gRPC+TLS на <<VLESS_SERVER>>:2053
- **Сервер (<<SERVER_DOMAIN>>)**: 3x-ui inbound'ы:
  - id=1 Reality :443
  - id=4 WS :8443 — disabled (старый L2, режется DPI)
  - id=5 gRPC :2053
  - id=6 XHTTP :2087 — **дремлет**, готов к использованию (был создан 2026-05-11)
- TG-звонки UDP идут через `proxy-grpc` (TGCALLS умеет TCP fallback) — это
  единственная нетривиальная зависимость от gRPC. Если убираем gRPC — TG-звонки
  переключатся обратно на direct UDP, ISP может резать.

## Два пути миграции

### Путь A — параллельный XHTTP-outbound (минимальное вмешательство)

**Что**: добавляем `proxy-xhttp` (или сразу) outbound на клиенте, целится в уже
существующий серверный inbound id=6 на :2087. Через сутки наблюдения — выбираем,
сносить ли gRPC или оставить оба.

**Плюсы**: серверная часть готова, ничего на сервере менять не надо.
**Минусы**: всё ещё используем нестандартный порт (2087); DPI на этом порту может
сработать так же как на 8443/2053.

### Путь B — XHTTP за Reality fallbacks (правильная архитектура)

**Что**: на сервере добавляем `realitySettings.fallbacks` к Reality-inbound'у :443
→ внутренний XHTTP-inbound на 127.0.0.1:8001. На клиенте `proxy-xhttp` целится в
<<VLESS_SERVER>>:**443** (тот же порт), отличается от Reality только ALPN/SNI.
gRPC :2053 сносим. Inbound id=6 на :2087 удаляем за ненадобностью.

**Плюсы**: всё на одном порту 443, DPI видит только обычный HTTPS, нестандартные
порты исчезают. Это финальная цель.
**Минусы**: больше серверных изменений, риск зацепить рабочий Reality при
модификации его inbound'а.

Рекомендация: **сначала путь A** для отладки самой связи XHTTP, потом **путь B**
для финальной чистки. Можно остановиться на A и жить с ним, если устал.

---

## Перед началом: pre-flight checklist

Запусти и убедись что:

```sh
ssh root@192.168.2.1 "
  echo '--- selfheal + memguard в cron? ---'
  crontab -l | grep -E 'selfheal|memguard'
  echo '--- /root/xray-config.safe.json есть? ---'
  ls -l /root/xray-config.safe.json
  echo '--- RAM запас? (должно быть available > 50 МБ) ---'
  free | head -3
  echo '--- GOMEMLIMIT активен? ---'
  PID=\$(cat /var/run/xray.pid); tr '\\0' '\\n' < /proc/\$PID/environ | grep GOMEMLIMIT
  echo '--- история флапов за сутки (должно быть 0) ---'
  grep -cE 'proxy-(reality|grpc) is dead' /var/log/xray/error.log
"
```

Если что-то из этого выглядит не так — **не мигрируй**, сначала чини.

Если RAM меньше 50 МБ available — подожди час, не нагружай ноутом, или
рестартни xray вручную (memguard такое не сделает пока выше порога).

Если `/root/xray-config.safe.json` устарел (xray-init.d сейчас знает что
selfheal сравнивает с ним): обнови `cp /usr/local/etc/xray/config.json
/root/xray-config.safe.json`. Это **критично** — selfheal будет
откатывать на него.

---

## ПУТЬ A — параллельный outbound

### A1. Изолированный тест клиентского XHTTP

**Не трогаем прод.** Запускаем второй xray на отдельном порту:

```sh
scp -O public/xray-test-xhttp-isolated.sh root@192.168.2.1:/tmp/
ssh root@192.168.2.1 "chmod +x /tmp/xray-test-xhttp-isolated.sh &&
  /tmp/xray-test-xhttp-isolated.sh \
    <<VLESS_UUID>> \
    <<VLESS_SERVER>> 2087 <<SERVER_DOMAIN>> /xhttp <<SERVER_DOMAIN>>"
```

Скрипт:
1. Сделает `/tmp/xhttp-test.json` с минимальным конфигом.
2. Запустит тестовый xray вторым процессом на SOCKS5 127.0.0.1:10888.
3. Через `curl --socks5-hostname` к `httpbin.org/ip` проверит маршрут.
4. Покажет результат, остановит тестовый xray.

**Что должно вернуть**: `{"origin": "<<VLESS_SERVER>>"}`.

Если вернуло — XHTTP-клиент рабочий, идём дальше.
Если нет — копаем (лог `/tmp/xhttp-test.log`), не идём дальше. Прод не задет.

### A2. Добавить proxy-xhttp в прод-конфиг ВНЕ balancer'а

Цель: добавить outbound, но **не дать observatory его пинговать** (чтобы повторно
не сжечь VPN если что-то не так с инициализацией). Используем тег **без**
префикса `proxy-` — observatory его проигнорит. Маршрутизация — через явное
правило на тестовый домен.

На клиенте:

```jsonc
// в outbounds[], рядом с proxy-grpc, добавить:
{
  "tag": "xhttp-probe",           // НЕ proxy-* — observatory не возьмёт
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "<<VLESS_SERVER>>",
      "port": 2087,
      "users": [{ "id": "<<VLESS_UUID>>", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "serverName": "<<SERVER_DOMAIN>>",
      "fingerprint": "chrome",
      "alpn": ["h2"]
    },
    "xhttpSettings": { "path": "/xhttp", "mode": "auto", "host": "<<SERVER_DOMAIN>>" },
    "sockopt": { "mark": 255 }
  }
}

// в routing.rules[], ПЕРЕД балансерным правилом, добавить:
{
  "type": "field",
  "outboundTag": "xhttp-probe",
  "domain": ["domain:httpbin.org"]   // или другой тестовый домен
}
```

Применить через `xray-apply-config.sh` (rollback автоматически через 5 минут):

```sh
# собрать новый конфиг локально (на ноуте) с добавленным xhttp-probe
# затем:
scp -O new-config.json root@192.168.2.1:/tmp/
ssh root@192.168.2.1 "/usr/local/bin/xray-apply-config.sh /tmp/new-config.json xhttp-probe 10"
```

**После рестарта (~10 сек без инета):**
- Открой `httpbin.org/ip` в браузере — должен показать `<<VLESS_SERVER>>`.
- Прод-трафик (всё остальное) идёт как раньше через balancer reality+grpc.
- Если ОК → отмени rollback: `ssh root@192.168.2.1 "touch /tmp/xray-rollback-cancel"`
- Если плохо → ничего не делай, через 10 мин само откатится.

### A3. Сутки наблюдения

```sh
ssh root@192.168.2.1 "tail -f /var/log/xray/error.log"
```

Смотри:
- ходят ли запросы на тестовый домен через `xhttp-probe`
- не сыпет ли error.log про этот outbound
- стабильно ли RAM
- balancer reality+grpc флапает?

### A4. Промоут XHTTP в balancer

Если за сутки `xhttp-probe` отработал без проблем:
1. Переименовать тег `xhttp-probe` → `proxy-xhttp` (теперь observatory его
   подхватит, balancer включит в пул).
2. Удалить временное правило для `httpbin.org`.
3. Применить через `xray-apply-config.sh`.
4. Сохранить как safe: `cp /usr/local/etc/xray/config.json
   /root/xray-config.safe.json` после подтверждения.

Теперь все 3 outbound'а в balancer'е: reality + grpc + xhttp.

### A5. (Опционально) Снести gRPC

Если xhttp работает железно и хочется минус один outbound:
1. Убрать `proxy-grpc` из outbounds + правило TG-UDP перенаправить на
   `proxy-xhttp` (XHTTP в отличие от gRPC умеет UDP нормально через xray).
2. Применить.
3. На сервере отключить inbound id=5 (gRPC :2053) через 3x-ui панель.

---

## ПУТЬ B — XHTTP за Reality fallbacks

### B1. Pre-check на сервере

```sh
ssh root@<<SERVER_DOMAIN>> "
  cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-pre-fallback-\$(date +%F-%H%M)
  ls -la /root/cert/<<SERVER_DOMAIN>>/  # должны быть fullchain.pem + privkey.pem
  ss -tlnp | grep -E ':443|:8001|:2053'  # 8001 должен быть свободен
"
```

### B2. Создать внутренний XHTTP inbound на 127.0.0.1:8001

Через 3x-ui API (см. шаблон в EXTRA_CARE.md → «Шаг S2»). Главное:
- `listen=127.0.0.1` (внутренний, не публичный)
- `port=8001`
- TLS settings с тем же cert что у Reality (для согласованности)
- Path `/xhttp`, mode `auto`
- Тот же UUID

### B3. Модифицировать Reality inbound (id=1) — добавить fallbacks

⚠️ **Самый рискованный шаг.** Если облажаться — Reality на :443 ляжет.

Через 3x-ui API: получить текущий inbound id=1, добавить в `realitySettings`:

```jsonc
"fallbacks": [
  { "alpn": "h2",       "dest": "127.0.0.1:8001" },
  { "alpn": "http/1.1", "dest": "127.0.0.1:8001" }
]
```

И обновить через `panel/api/inbounds/update/1`.

**Перед коммитом** — снять снапшот, готовый одной командой откатить:

```sh
ssh root@<<SERVER_DOMAIN>> "cp /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak-pre-realityfallbacks-\$(date +%F-%H%M)"
```

Если что — `cp .bak /etc/x-ui/x-ui.db && systemctl restart x-ui`.

### B4. Клиент: добавить proxy-xhttp на :443

Outbound целится в `<<VLESS_SERVER>>:443` (тот же порт что Reality), отличается ТОЛЬКО
ALPN/SNI: серверный Reality fingerprint не подойдёт → клиент попадёт в fallback
по ALPN h2 → внутренний XHTTP.

Через `xray-apply-config.sh` с авто-rollback.

### B5. Сутки наблюдения, потом снос gRPC + удаление id=6 :2087

Аналогично A4-A5.

---

## Rollback из любого состояния

```sh
# 1. На роутере: откатить config.json на safe и рестартнуть xray
ssh root@192.168.2.1 "cp /root/xray-config.safe.json /usr/local/etc/xray/config.json && /etc/init.d/xray restart"

# 2. На сервере (если меняли x-ui.db): откатить
ssh root@<<SERVER_DOMAIN>> "
  ls -1t /etc/x-ui/x-ui.db.bak-* | head -1 | xargs -I{} cp {} /etc/x-ui/x-ui.db
  /etc/init.d/x-ui restart
"

# 3. Если совсем плохо — ребутни роутер, init.d-хук selfheal через 50с
#    сам сравнит конфиг с .safe и при необходимости откатит.
```

---

## Что НЕ делать (грабли из прошлых попыток)

1. **НЕ добавлять непротестированный outbound в `selector` balancer'а.**
   Кривой outbound может зависнуть в observatory probe и положить весь VPN
   до таймаута (~минуту). Сначала через изолированный тест (A1) или через
   тег-вне-balancer'а (A2).

2. **НЕ класть rollback-скрипты в /tmp.** При ребуте `/tmp` чистится,
   скрипт пропадёт, crontab останется висеть мёртвым. `xray-apply-config.sh`
   правильно кладёт в `/root/`.

3. **НЕ забывать обновлять `/root/xray-config.safe.json` после
   подтверждённой миграции.** Иначе selfheal будет откатывать ТЕБЯ обратно
   с новой версии на старую при первом же сбое.

4. **НЕ делать оба пути одновременно.** Сначала A полностью или B полностью.

5. **Перед любым рестартом xray** — учитывай ~10 сек пауза без инета у
   клиентов. `xray-apply-config.sh` это сам делает с авто-rollback.

---

## Локальные fallback'и для параноика

Помни что у тебя есть **на ноуте** независимо от роутера:
- AmneziaWG-клиент (прямое UDP-подключение, обходит роутер целиком)
- Прямые VLESS-клиенты к <<SERVER_DOMAIN>>
- Можно добавить NaiveProxy / Hysteria2 если совсем страшно

Если миграция пойдёт совсем плохо и роутер уйдёт offline на дольше чем хочется —
переключи ноут на эти fallback'и руками, чтобы не сидеть совсем без инета пока
чинишь.

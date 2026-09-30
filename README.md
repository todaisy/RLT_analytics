# RLT Analytics

Лёгкий стек из двух контейнеров: Prometheus и Grafana. Python-приложение,
экспортёры, БД и Alertmanager для аналитики не нужны. Dockerfile — исходная
заготовка проекта, Compose его не использует.

## Запуск

Требуются Docker и Docker Compose, а также запущенные support_service и AlphaRAG.

```sh
cp .env.example .env   # только если .env ещё нет
# Укажите свой GRAFANA_ADMIN_PASSWORD в .env
docker compose up -d
```

- Grafana: http://localhost:3000 — логин `admin`, пароль из `.env`.
- Дашборд: http://localhost:3000/d/rlt-overview
- Prometheus: http://localhost:9090
- Состояние источников: http://localhost:9090/targets

При первоначальной настройке проекта создан локальный `.env` со случайным
паролем; он исключён из Git. Пароль применяется при первом создании Grafana:
изменение `.env` не меняет пароль пользователя в существующем томе.
Порты интерфейсов привязаны к localhost, меняются в `.env`.

## Источники

| Job | URL из контейнера Prometheus | Реализация |
| --- | --- | --- |
| support_service | http://host.docker.internal:8067/metrics | support_service/src/interfaces/api/routers/metrics.py |
| alpharag | http://host.docker.internal:8000/metrics | AlphaRAG.hack/Back/modules/chat/metrics.py |

Оба роутера уже подключены без префикса. Используются опубликованные порты
существующих сервисов; подключение к общей Docker-сети не требуется.
Docker Desktop поддерживает host.docker.internal, для Docker Engine Linux
добавлен host-gateway. При запуске приложений непосредственно на Linux-хосте
они должны слушать интерфейс, доступный контейнерам, например 0.0.0.0.
Для другой машины/портов измените targets в prometheus.yml.
Prometheus не подставляет переменные из .env в этот файл.
После изменения: `docker compose restart prometheus`.

Scrape выполняется каждые 30 секунд с таймаутом 10 секунд. Support при каждом
опросе агрегирует данные PostgreSQL; при росте базы можно увеличить интервал
и timeInterval в grafana/provisioning/datasources/prometheus.yaml.
Хранение — до 15 дней или 2 GB блоков TSDB, что наступит раньше. WAL и текущие
данные требуют дополнительного места. Лимиты контейнеров: Prometheus 512 MB,
Grafana 256 MB, каждому до 0.5 CPU. Данные сохраняются в именованных томах.

## Метрики и дашборд

- Доступность обоих источников (`up`).
- Количество закрытых диалогов, средняя и P95 длительность по линии.
- Среднее время первого ответа по линии и текущей оценке, за всё время.
  Это gauge: нельзя использовать rate/increase, поскольку смена оценки
  переносит диалог между группами. `none` означает отсутствие оценки.
- Средняя оценка и количество оценок за выбранный период. Изменённая оценка
  считается новым наблюдением, это не число уникальных оценённых диалогов.
- AlphaRAG: HTTP запросы/с по маршрутам и статусам, доля 5xx, количество
  запросов за период, успешно поставленные в Redis WebSocket-команды/с.
  PING, scrape и health probes исключены исходным экспортёром.

Фильтр линии влияет только на support. rate использует адаптивное окно
$__rate_interval, increase — выбранный период $__range. increase является
оценкой и может быть дробным. Без наблюдений средние показывают No data;
нулевой трафик не подменяет недоступность источника. Для rate нужны минимум
два scrape. История до запуска Prometheus не восстанавливается, кроме
накопленных gauge-снимков. Счётчики AlphaRAG находятся в памяти одного worker
и сбрасываются при перезапуске; rate/increase учитывают наблюдаемые сбросы.
При нескольких workers текущий экспортёр AlphaRAG требует доработки.

Datasource и дашборд provisioned автоматически. Редактируйте JSON в
`grafana/dashboards/`, изменения подхватываются автоматически. Чтобы создать
свою редактируемую версию, сохраните копию дашборда под новым именем.

## Проверка и обслуживание

```sh
docker compose config --quiet
docker compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
docker compose ps
docker compose logs --tail=100 prometheus grafana
curl -f http://localhost:8067/metrics
curl -f http://localhost:8000/metrics
docker compose down
```

`down` сохраняет историю и настройки. `down -v` удаляет оба тома вместе
с историей Prometheus и данными Grafana.

Документация: [конфигурация Prometheus](https://prometheus.io/docs/prometheus/latest/configuration/configuration/),
[provisioning Grafana](https://grafana.com/docs/grafana/latest/administration/provisioning/).

## Реакции, линии и темы вопросов

- `alpharag_bot_reactions{reaction="like|dislike|none"}` — текущие реакции на
  сохранённые ответы бота из PostgreSQL. Это gauge: смена/снятие реакции или
  удаление сообщения меняет значение. Для него не используются rate/increase.
- `support_requests{line="L1|L2|L3"}` — количество сохранённых обращений к
  операторам по назначенной линии, включая открытые и исторические диалоги.
  Все три серии присутствуют даже при нулевых значениях. Это количество
  диалогов, а не HTTP-запросов или отдельных сообщений. Gauge отражает
  текущее содержимое БД. Для новых диалогов используется зафиксированная
  линия из аналитики, для старых — линия назначенного оператора.
- `alpharag_questions_total{topic="..."}` — количество классифицированных
  запросов боту с момента включения метрики. MAESTRO передаёт тему через
  метаданные END_GENERATION; AlphaRAG сохраняет отдельную запись в
  bot_question_analytics в транзакции с ответом. Повторная доставка того же
  запроса не увеличивает счётчик. Неуспешные генерации без конечной
  классификации не включаются. Старые вопросы задним числом не размечаются.

Классификатор ON_TOPIC/OFF_TOPIC отделяет вопросы вне тематики. Конкретная
тема берётся из существующих категорий GraphRAG/активного workflow, без
второго обращения к LLM. other означает прочие вопросы по теме, off_topic —
вне тематики, blocked — модерация, operator_request — запрос оператора.
В Grafana для категорий настроены русские названия. Каталог фиксирован в
AlphaRAG Back/modules/chat/question_topics.json; при добавлении новых узлов
GraphRAG обновите каталог и подписи панелей. Все темы экспортируются с нуля,
чтобы Prometheus видел первый прирост после включения сбора.

Источников scrape по-прежнему два. Темы идут через Kafka в AlphaRAG, отдельный
экспортёр MAESTRO и дополнительные контейнеры аналитики не нужны.

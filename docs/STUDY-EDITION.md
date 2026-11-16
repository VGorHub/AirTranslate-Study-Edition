# AirTranslate Study Edition

## Этап 1. Исходная версия

Study Edition добавит к нативному AirTranslate браузерную транскрипцию для Yomitan, историю занятий и Markdown для Obsidian. На этапе подготовки доступна базовая версия AirTranslate 1.17.0 (сборка 1170). Зафиксированный upstream — [`c177992`](https://github.com/himomohi/AirTranslate/commit/c1779923cba6261db56be95d2d25a733a55e766c), тег `v1.17.0`.

Проверка от 16 ноября 2026 года на MacBook Pro M3 Pro, 18 ГБ, macOS 27.2 (`26B123`). Активны Command Line Tools со Swift 6.4.2 и SDK macOS 27.2. Полный Xcode не обнаружен, `xcodebuild -version` требует его установки.

| Проверка на исходном коде | Результат |
| --- | --- |
| `git fsck --full`, сверка веток и тегов | Целостность подтверждена. Полный клон, 161 коммит в `upstream/master`, 32 тега и обе ветки upstream. |
| `swift build --target AirTranslateCore` | Модуль собран с Command Line Tools. |
| `TranscriptTextProcessorTests` и `DubbingSpeechProgressTests` | 20 тестов прошли в отдельном временном Swift-пакете из оригинальных исходников и двух suite. `swift test --disable-xctest --no-parallel` использовал Swift Testing из Command Line Tools. |
| `./script/verify_packaging_permissions.sh` | Проверка Info.plist, entitlements и подписи прошла. |
| `python3 -m unittest discover -s script/tests -v` | 14 тестов прошли. |
| `swift build -c release`, `swift test --no-parallel` | Заблокированы на компиляции `AirTranslateApp.swift` и других SwiftUI-файлов. В установленном тулчейне отсутствует плагин `SwiftUIMacros` для `@State`. Запуск собранного из исходников приложения и полный Swift-набор ожидают Xcode. |

Системная проверка `LanguageAvailability().status(from: en-US, to: ru-RU)` вернула `installed` на этом Mac. Сам интерфейс AirTranslate берёт языки из `LanguageOption.supported`, где `ru-RU` пока отсутствует.

## Как воспроизвести базовую проверку

Для запуска приложения нужна macOS 26 или новее. Для сборки из исходников upstream требует полный Xcode 27 с SDK macOS 27 и Swift 6.4 или новее. Xcode 27 запускается на Apple Silicon с macOS Tahoe 26.6 или новее. Python 3 нужен для тестов инструмента диагностики. У базового Swift-пакета нет внешних зависимостей. [Требования Apple к Xcode](https://developer.apple.com/xcode/system-requirements/) · [Документация AirTranslate](DEVELOPMENT.md)

```bash
git clone git@github.com:VGorHub/AirTranslate-Study-Edition.git
cd AirTranslate-Study-Edition
git remote add upstream https://github.com/himomohi/AirTranslate.git

# Укажи фактический путь к установленному Xcode в текущем терминале.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
swift --version

./script/verify_packaging_permissions.sh
python3 -m unittest discover -s script/tests -v
swift test --no-parallel
swift build -c release
./script/build_and_run.sh --verify
```

Последняя команда упаковывает отладочную сборку в `dist/AirTranslate.app`, подписывает её и проверяет путь запущенного процесса. Для ручной проверки выбери Apple Mode, System Audio и английский источник. Нажми Start, воспроизведи короткое английское аудио, проверь распознавание, Pause/Resume, Stop и плавающие субтитры. Если проверяешь TXT, включи штатное сохранение и открой запись в библиотеке. Для захвата через ScreenCaptureKit macOS запрашивает разрешения на запись экрана и системного звука. Разрешение микрофона требуется при выборе соответствующего входа, разрешение распознавания речи — для Apple Speech. [Установка и разрешения macOS](GETTING-STARTED.md)

## Точки интеграции

| Слой | Что есть в upstream | Куда подключается Study Edition |
| --- | --- | --- |
| Запуск | [`AirTranslateApp.swift`](../Sources/AirTranslate/App/AirTranslateApp.swift) создаёт один `TranslationSessionStore` для основного окна, настроек, меню и субтитров. | Здесь связать жизненный цикл локального HTTP-сервера с приложением. Ошибку открытия порта отображать отдельно от состояния записи. |
| Захват и сессия | [`SystemAudioCapture.swift`](../Sources/AirTranslate/Services/SystemAudioCapture.swift) использует ScreenCaptureKit. [`MicrophoneAudioCapture.swift`](../Sources/AirTranslate/Services/MicrophoneAudioCapture.swift) обслуживает второй вход. В [`TranslationSessionStore.swift`](../Sources/AirTranslate/Services/TranslationSessionStore.swift) `AudioSamplePipelineRegistry` передаёт PCM движкам, а `PipelineLifecycle` отсеивает устаревшие поколения. | Открывать сессию после успешного перехода `start()` в running. Отражать pause/resume и reconnect. Завершать после штатного ожидания финальных событий и перед сбросом состояния в `finishPipeline`. Учесть системную остановку, выход из приложения и неуспешный старт. |
| ASR | Apple `appendCaption` принимает [метаданные с ID, ревизией и диапазоном аудио](../Sources/AirTranslate/Models/AppleSpeechRecognitionMetadata.swift). `receiveNariTranscript` и `receiveGrokTranscript` используют ID провайдера, Meta — `startMetaTurn`/`completeMetaTurn`, Azure — `receiveAzureMAIPartial`/`receiveAzureMAI`. | Отправлять Study-события после проверок поколения и порядка, сохраняя подтверждение движка. Для событий без тайминга аудио использовать отметку относительно начала сессии и указывать, что время приблизительное. |
| Realtime-режимы | [OpenAI](../Sources/AirTranslate/Services/OpenAIRealtimeTranscriber.swift) разбирает terminal-события с ID. Mailbox в Store передаёт текст без ID. [Gemini](../Sources/AirTranslate/Services/GeminiLiveTranslationService.swift) передаёт `finished` для исходника. [Qwen](../Sources/AirTranslate/Services/QwenRealtimeTranslationService.swift) разбирает отдельные ID источника и перевода. `receiveQwenText` получает текст и `isFinal`. | Передать ID и подтверждение через существующие обработчики там, где эти данные доступны. При отдельных потоках источника и перевода без надёжного общего ID сохранять подтверждённый перевод с временной привязкой. Сопоставление по позиции может связывать разные реплики. |
| Текстовый перевод | `updateTranslation` проверяет актуальность запроса, исходника и Apple-ревизии. [`CaptionLine.swift`](../Sources/AirTranslate/Models/CaptionLine.swift) хранит UI-ревизию и текст для показа. У Qwen и realtime-перевода строка может накапливать всю сессию, а её `isFinal` описывает состояние UI. | Передавать принятый перевод для соответствующей исходной ревизии. Учесть ветку, где подтверждённый текст совпадает с предыдущим progress. Использовать поток событий, чтобы избежать повторной обработки всего массива `lines`. |
| Языки | [`LanguageOption.swift`](../Sources/AirTranslate/Models/LanguageOption.swift), [`SidebarView.swift`](../Sources/AirTranslate/Views/SidebarView.swift) и [`ModelAvailabilityChecker.swift`](../Sources/AirTranslate/Services/ModelAvailabilityChecker.swift) обслуживают список, выбор и доступность языков. | Добавить русский как целевой язык с проверкой пары средствами существующего движка. Проверить восстановление выбора в `TranslationSessionStore` и ограничения облачных моделей. Для пути без ключей использовать Apple Speech и Apple Translation. |
| Файлы | Store сохраняет TXT в `~/Library/Application Support/AirTranslate/Transcripts` при включённой настройке. Уже есть атомарная запись, checkpoint с интервалом 30 секунд и сохранение при завершении. [`TranscriptLibraryView.swift`](../Sources/AirTranslate/Views/TranscriptLibraryView.swift) открывает эту библиотеку. | Разместить структурированное хранилище занятий рядом с TXT. Настройка TXT управляет только существующей библиотекой. |

## План следующих этапов

1. **Этап 2. Backend и данные.** Начать с чистой проверки под полным Xcode. Добавить типы событий в `Sources/AirTranslateCore/` и небольшой адаптер к `TranslationSessionStore`. В `Sources/AirTranslate/Study/` разместить SQLite-хранилище и HTTP-сервис. Использовать версионируемую схему, транзакции и один сериализованный путь записи. Сохранять метаданные занятия, стабильные ID, порядок, источник времени и подтверждённую ревизию сегмента. Partial держать в памяти. После аварийного завершения показывать прерванное занятие с уже сохранёнными данными. Проверить повторы, исправления, финальные события при Stop, сбой записи и восстановление из БД. [SQLite WAL](https://www.sqlite.org/wal.html)

   Для HTTP проверить Hummingbird 2 как встраиваемый SwiftPM-сервер с потоковым телом ответа. Он добавляет зависимости к самодостаточному пакету. Проверить сборку, завершение SSE и bind к `127.0.0.1`. Использовать один origin `http://127.0.0.1:8765` с настраиваемым портом. Для защиты от сторонних страниц проверять `Host`, оставить CORS выключенным, для управляющих методов требовать точный `Origin` и токен в заголовке. Задать REST для состояния, списка занятий и чтения сегментов по курсору. В SSE передавать partial, final, translation и status. Согласовать снимок и подключение SSE по порядковому номеру. При отставании клиента ограничивать буфер и восстанавливать его из снимка. [Hummingbird](https://github.com/hummingbird-project/hummingbird)
2. **Этап 3. Веб-интерфейс.** Добавить `Web/` с React, TypeScript, shadcn/ui на Radix, Tailwind CSS и Lucide. Vite упаковывает статические файлы, которые отдаёт Swift-сервер. Подключить артефакты к `script/build_and_run.sh` и `Release/build_open_source_release.sh`. Сделать поиск, переключатель перевода, тему, автопрокрутку и историю. Для Yomitan использовать обычные текстовые HTML-узлы и отдельный partial. Узел подтверждённого исходника сохраняется при поступлении следующих сегментов и поздних переводов. Измерить длинную историю в Chrome. При необходимости добавить постраничную загрузку или виртуализацию с сохранением видимого выделения и словарного контекста. [shadcn/ui для Vite](https://ui.shadcn.com/docs/installation/vite) · [Yomitan](https://yomitan.wiki/)
3. **Этап 4. Markdown.** Читать подтверждённые сегменты из SQLite в стабильном порядке. Добавить форматтер в `Sources/AirTranslateCore/` и ручной экспорт из SwiftUI с `NSSavePanel` для выбора папки и имени. Включить название, дату, длительность, ID, языки, ASR-движок, таймкоды, оригинал и доступный перевод. Проверить экранирование YAML, многострочный текст, Unicode и запись файла.
4. **Этап 5. Стабилизация.** Проверить системный звук и ключевые режимы каждого провайдера, перезапуск, нагрузку трёхчасовой сессии и историю после reload. В Chrome с Yomitan проверить выделение, наведение и карточку через AnkiConnect. Открыть экспорт в Obsidian и повторить сборку из чистого клона.
5. **Этап 6. AI Brief.** Добавить отдельный конспект и отдельный Markdown. Официальная установка AI Elements предполагает Next.js и AI SDK. Для статического React-интерфейса со Swift API подходит `assistant-ui` с custom runtime, если появится сценарий диалога. Для разовой генерации файла достаточно обычных компонентов shadcn/ui. [AI Elements](https://elements.ai-sdk.dev/docs/setup) · [assistant-ui](https://www.assistant-ui.com/docs/runtimes/custom/overview)

### Совместимость веб-стека

По метаданным npm на 16 ноября 2026 года совместимая отправная точка для этапа 3 — React 19.3.1, Vite 8.3.8, `@vitejs/plugin-react` 6.3.0, `@tailwindcss/vite` 4.3.5, shadcn CLI 4.23.0, `radix-ui` 1.8.1 и `lucide-react` 1.73.0. Плагины поддерживают Vite 8, Radix и Lucide объявляют совместимость с React 19. На Mac есть Node.js 24.22.1 и Chrome 157. Для shadcn выбирать Radix явно. На этапе 3 повторить проверку версий, зафиксировать lockfile и использовать `npm ci`. Node.js нужен для сборки веб-ресурсов. Пользователь запускает один .app. [Vite](https://vite.dev/guide/) · [shadcn CLI](https://ui.shadcn.com/docs/cli) · [Tailwind CSS](https://tailwindcss.com/docs/compatibility)

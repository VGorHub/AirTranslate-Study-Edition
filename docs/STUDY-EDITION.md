# AirTranslate Study Edition

## Этап 1. Исходная версия

Study Edition добавляет к нативному AirTranslate историю занятий и локальный API. Браузерная транскрипция для Yomitan и Markdown для Obsidian запланированы на этапы 3 и 4. Зафиксированный upstream — [`c177992`](https://github.com/himomohi/AirTranslate/commit/c1779923cba6261db56be95d2d25a733a55e766c), тег `v1.17.0` (сборка 1170).

Проверка от 16 ноября 2026 года на MacBook Pro M3 Pro, 18 ГБ, macOS 27.2 (`26B123`). Активны Command Line Tools со Swift 6.4.2 и SDK macOS 27.2. Полный Xcode не обнаружен, `xcodebuild -version` требует его установки.

| Проверка на исходном коде | Результат |
| --- | --- |
| `git fsck --full`, сверка веток и тегов | Целостность подтверждена. Полный клон, 161 коммит в `upstream/master`, 32 тега и обе ветки upstream. |
| `swift build --target AirTranslateCore` | Модуль собран с Command Line Tools. |
| `TranscriptTextProcessorTests` и `DubbingSpeechProgressTests` | 20 тестов прошли в отдельном временном Swift-пакете из оригинальных исходников и двух suite. `swift test --disable-xctest --no-parallel` использовал Swift Testing из Command Line Tools. |
| `./script/verify_packaging_permissions.sh` | Проверка Info.plist, entitlements и подписи прошла. |
| `python3 -m unittest discover -s script/tests -v` | 14 тестов прошли. |
| `swift build -c release`, `swift test --no-parallel` | Заблокированы на компиляции `AirTranslateApp.swift` и других SwiftUI-файлов. В установленном тулчейне отсутствует плагин `SwiftUIMacros` для `@State`. Запуск собранного из исходников приложения и полный Swift-набор ожидают Xcode. |

Системная проверка `LanguageAvailability().status(from: en-US, to: ru-RU)` вернула `installed`. В исходном AirTranslate `v1.17.0` список языков ещё не содержал `ru-RU`.

## Этап 2. Русский перевод и локальные данные

На Xcode 27.2 до изменений прошли 636 upstream-тестов. Перевод тестовой фразы из `en-US` в `ru-RU` через системный Apple Translation проверен локально. Для живого перевода в приложении выберите **Apple Mode**, **From → English**, **To → Russian**. При запросе загрузите языковые пакеты через AirTranslate.

Для распознавания русской речи выберите **Apple Mode**, **From → Russian** и нужный язык перевода. Если `SpeechTranscriber` не поддерживает `ru-RU` на этом Mac, AirTranslate использует локальный `DictationTranscriber` и загружает его речевой пакет через обычный диалог приложения. Для одной транскрипции можно выбрать **Transcribe Only**.

В Release-сборке проверен **Mac Audio → Russian → English** на синтетической речи. Подтверждённая русская фраза с английским переводом появилась в локальной истории во время захвата. Резервный модуль используется при ручном выборе русского источника только для Apple Speech.

При захвате Study Edition пишет подтверждённые сегменты в SQLite внутри Application Support. Встроенный Hummingbird обслуживает REST и SSE на `127.0.0.1:8765`. Команды ручной проверки, формат событий и управление портом описаны в [документации API](STUDY-API.md).

На Xcode 27.2 прошли 642 Swift-теста, 14 Python-тестов и проверка упаковки. Release-сборка запустилась. В живой проверке с синтетическим аудио Mac распознал английскую фразу, перевёл её на русский и отдал подтверждённый сегмент через REST и SSE. После перезапуска с временной SQLite-базой идентификаторы, текст, переводы и таймкоды совпали. Сервер отклонил запросы с посторонним Host, посторонним Origin и без управляющего токена. На этом Mac проверка прошла на порту `18765`, потому что `8765` уже использовался.

## Этап 3. Стенограмма в браузере

Для сборки `.app` установите Node.js 24 или новее с npm и выполните `./script/build_and_run.sh --verify`. Оба сценария упаковки собирают `Web/` через `npm ci` и Vite, затем копируют страницу, шрифты и остальные ресурсы в `.app` до подписи. Встроенный Swift-сервер обслуживает страницу и API. После упаковки достаточно запустить AirTranslate.

1. Нажмите кнопку с глобусом в AirTranslate или введите `http://127.0.0.1:8765/` в Chrome. При особой настройке используйте свой порт, например `18765`.
2. Выберите **Apple Mode**, **Mac Audio**, **English → Russian**. Начните захват и воспроизведите английское аудио. После временного распознавания фраза появится среди подтверждённых, следом может прийти перевод.
3. Прокрутите текст вверх или выключите **Автопрокрутку**, чтобы перечитать фразу. Наведите на английское слово, используя настроенную клавишу сканирования Yomitan. Кнопка **К последней фразе** возобновляет прокрутку.
4. Перезагрузите Chrome во время захвата. Откройте завершённое занятие в истории, найдите слово, скройте перевод и проверьте кнопки копирования. **Копировать всё** берёт все подтверждённые фразы выбранного занятия и учитывает переключатель перевода.

Разработчик может подключить Vite к отдельно запущенному AirTranslate для правок веб-кода. В обычной сборке этот процесс не нужен.

```bash
npm --prefix Web ci
npm --prefix Web test
AIRTRANSLATE_STUDY_PORT=18765 npm --prefix Web run dev
```

`Web/src/study/` восстанавливает постраничный снимок занятия и применяет SSE поверх его курсора. Подтверждённые фразы имеют стабильные DOM-узлы. Временные фразы отображаются в отдельном блоке. Для длинного текста CSS откладывает отрисовку невидимых строк, сохраняя HTML доступным для выделения и словаря. Веб-интерфейс использует только чтение REST и SSE. Страница и ресурсы отдаются с выделенных маршрутов Hummingbird, через те же проверки Host и Origin, что и API.

В Chrome проверены история, темы, поиск, копирование, перевод и перезагрузка. Синтетическая трёхчасовая сессия с 2 400 фразами открылась примерно за 0,21 секунды в одном локальном замере от выбора занятия до появления последней строки в DOM. В отдельном тесте Chrome получил исправление partial, подтверждение и поздний перевод по SSE. Исходный DOM-узел сохранился, ручная прокрутка остановила следование, а перезагрузка восстановила историю из снимка. В Release-сборке проверен запуск захвата кнопкой **Start** в AirTranslate. Chrome показал английскую фразу и русский перевод при захвате системного звука, а перезагрузка страницы восстановила ту же активную сессию. Для окна словаря Yomitan нужна ручная проверка.

## Как воспроизвести базовую проверку

Для запуска приложения нужна macOS 26 или новее. Для сборки из исходников upstream требует полный Xcode 27 с SDK macOS 27 и Swift 6.4 или новее. Xcode 27 запускается на Apple Silicon с macOS Tahoe 26.6 или новее. Python 3 нужен для тестов инструмента диагностики. SwiftPM при первой сборке загружает Hummingbird и версии из `Package.resolved`. [Требования Apple к Xcode](https://developer.apple.com/xcode/system-requirements/) · [Документация AirTranslate](DEVELOPMENT.md)

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

1. **Этап 4. Markdown.** Читать подтверждённые сегменты из SQLite в стабильном порядке. Добавить форматтер и ручной экспорт из SwiftUI с `NSSavePanel` для выбора папки и имени. Включить название, дату, длительность, ID, языки, ASR-движок, таймкоды, оригинал и доступный перевод. Проверить экранирование YAML, многострочный текст, Unicode и запись файла.
2. **Этап 5. Стабилизация.** Проверить системный звук и ключевые режимы каждого провайдера, перезапуск, нагрузку трёхчасовой сессии и историю после reload. В Chrome с Yomitan проверить выделение, наведение и карточку через AnkiConnect. Открыть экспорт в Obsidian и повторить сборку из чистого клона.
3. **Этап 6. AI Brief.** Добавить отдельный конспект и отдельный Markdown. Официальная установка AI Elements предполагает Next.js и AI SDK. Для статического React-интерфейса со Swift API подходит `assistant-ui` с custom runtime, если появится сценарий диалога. Для разовой генерации файла достаточно обычных компонентов shadcn/ui. [AI Elements](https://elements.ai-sdk.dev/docs/setup) · [assistant-ui](https://www.assistant-ui.com/docs/runtimes/custom/overview)

### Совместимость веб-стека

В `Web/package-lock.json` зафиксированы React 19.3.1, Vite 8.3.8, `@vitejs/plugin-react` 6.3.0, Tailwind CSS 4.3.5, `radix-ui` 1.8.1 и `lucide-react` 1.73.0. Компоненты shadcn/ui взяты из реестра Radix Nova. [Vite](https://vite.dev/guide/) · [shadcn/ui для Vite](https://ui.shadcn.com/docs/installation/vite) · [Yomitan](https://yomitan.wiki/)

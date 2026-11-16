import { memo, useDeferredValue, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { ArrowDownToLine, AudioLines, ChevronDown, Copy, History, LoaderCircle, Moon, Search, Sun, Wifi, WifiOff, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Switch } from "@/components/ui/switch"
import { useStudy } from "./study/useStudy"
import { clock, segmentText } from "./study/transcript"
import type { Segment, Session, Summary } from "./study/transcript"

const dateFormat = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long", year: "numeric" })
const timeFormat = new Intl.DateTimeFormat("ru-RU", { hour: "2-digit", minute: "2-digit" })
const languageFormat = new Intl.DisplayNames("ru", { type: "language", languageDisplay: "dialect" })
const stateLabels = {
  recording: "Идёт запись", paused: "Пауза", reconnecting: "Движок переподключается",
  finishing: "Завершение записи", completed: "Завершено", interrupted: "Запись прервана",
}

function languageName(tag: string) {
  try {
    return languageFormat.of(new Intl.Locale(tag).language) ?? tag
  } catch {
    return tag
  }
}

function languages(session: Session) {
  const source = session.sourceLanguage ? languageName(session.sourceLanguage) : "Автоопределение"
  return session.targetLanguage ? `${source} → ${languageName(session.targetLanguage)}` : source
}

function sessionInURL() {
  const id = new URL(location.href).searchParams.get("session")
  return id && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(id) ? id.toUpperCase() : null
}

function preference(key: string) {
  try { return localStorage.getItem(`study.${key}`) } catch { return null }
}

function savePreference(key: string, value: string) {
  try { localStorage.setItem(`study.${key}`, value) } catch { /* Preferences still work in this tab. */ }
}

const SessionLink = memo(function SessionLink({ item, selected, onSelect }: {
  item: Summary
  selected: boolean
  onSelect: (id: string) => void
}) {
  const { session } = item
  return (
    <a className="session-link" aria-current={selected ? "page" : undefined} href={`?session=${session.id}`}
      onClick={event => {
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
        event.preventDefault()
        onSelect(session.id)
      }}>
      <span className="session-date">{dateFormat.format(new Date(session.startedAt))}</span>
      <span className="session-detail"><time dateTime={session.startedAt}>{timeFormat.format(new Date(session.startedAt))}</time>{languages(session)}</span>
    </a>
  )
})

const SegmentRow = memo(function SegmentRow({ segment, showTranslation, onCopy }: {
  segment: Segment
  showTranslation: boolean
  onCopy: (value: string) => void
}) {
  const { isFinal, timing, startMilliseconds, text, language, channel, translation, translationLanguage } = segment
  return (
    <li className={isFinal ? "segment confirmed" : "segment partial"} data-segment-id={segment.id}>
      <time className="timestamp" title={timing === "audio" ? "Время в аудио" : "Приблизительное время"}>
        {timing === "receipt" && <span aria-label="Примерно">≈</span>}{clock(startMilliseconds)}
      </time>
      <div className="segment-text">
        {channel === "translation" && <span className="independent-label">Перевод</span>}
        <p className={channel === "source" ? "source" : "translation"} lang={language}>{text}</p>
        {showTranslation && translation && <p className="translation" lang={translationLanguage}>{translation}</p>}
      </div>
      {isFinal && <Button variant="ghost" size="icon-sm" className="copy-line" title="Копировать фразу"
        aria-label={`Копировать фразу ${clock(startMilliseconds)}`} onClick={() => onCopy(segmentText(segment, showTranslation))}>
        <Copy aria-hidden />
      </Button>}
    </li>
  )
})

function order(a: Segment, b: Segment) { return a.position - b.position }

export function StudyApp() {
  const [pinned, setPinned] = useState(sessionInURL)
  const study = useStudy(pinned)
  const [historyOpen, setHistoryOpen] = useState(false)
  const [query, setQuery] = useState("")
  const search = useDeferredValue(query.trim().toLocaleLowerCase())
  const [translation, setTranslation] = useState(() => preference("translation") !== "off")
  const [theme, setTheme] = useState(() => preference("theme"))
  const [systemDark, setSystemDark] = useState(() => matchMedia("(prefers-color-scheme: dark)").matches)
  const [follow, setFollow] = useState(() => preference("follow") !== "off")
  const [notice, setNotice] = useState("")
  const noticeTimer = useRef<number | undefined>(undefined)
  const feed = useRef<HTMLDivElement>(null)
  const previousSession = useRef<string | undefined>(undefined)
  const lastFollowPosition = useRef(0)
  const { active, connection, selected, transcript, summary } = study
  const live = !!active && selected === active.session.id
  const dark = theme ? theme === "dark" : systemDark
  const confirmed = useMemo(() => [...(transcript?.confirmed.values() ?? [])].sort(order), [transcript?.confirmed])
  const visible = useMemo(() => confirmed.filter(segment => (translation || segment.channel === "source") &&
    (!search || segmentText(segment, translation).toLocaleLowerCase().includes(search))), [confirmed, search, translation])
  const partials = useMemo(() => search ? [] : [...(transcript?.partials.values() ?? [])]
    .filter(segment => translation || segment.channel === "source").sort(order), [search, transcript?.partials, translation])

  useEffect(() => {
    const themeQuery = matchMedia("(prefers-color-scheme: dark)")
    const update = () => setSystemDark(themeQuery.matches)
    themeQuery.addEventListener("change", update)
    return () => themeQuery.removeEventListener("change", update)
  }, [])

  useLayoutEffect(() => {
    document.documentElement.classList.toggle("dark", dark)
  }, [dark])

  useEffect(() => {
    const update = () => setPinned(sessionInURL())
    window.addEventListener("popstate", update)
    return () => {
      window.removeEventListener("popstate", update)
      window.clearTimeout(noticeTimer.current)
    }
  }, [])

  function select(id: string | null) {
    const url = new URL(location.href)
    if (id) url.searchParams.set("session", id)
    else url.searchParams.delete("session")
    if (url.href !== location.href) history.pushState(null, "", url)
    setPinned(id)
    setQuery("")
    setHistoryOpen(false)
  }

  function changeFollow(value: boolean) {
    setFollow(value)
    savePreference("follow", value ? "on" : "off")
  }

  useLayoutEffect(() => {
    const viewport = feed.current
    if (!viewport) return
    if (previousSession.current !== selected) {
      viewport.scrollTop = 0
      previousSession.current = selected
    }
    const selection = getSelection()
    if (live && follow && !search && (!selection?.anchorNode || selection.isCollapsed || !viewport.contains(selection.anchorNode))) {
      viewport.scrollTop = viewport.scrollHeight
      lastFollowPosition.current = viewport.scrollTop
    }
  }, [visible, partials, live, follow, search, selected])

  const copy = useMemo(() => async (value: string) => {
    try {
      await navigator.clipboard.writeText(value)
      setNotice("Скопировано")
    } catch { setNotice("Не удалось скопировать. Выделите текст и нажмите ⌘C.") }
    window.clearTimeout(noticeTimer.current)
    noticeTimer.current = window.setTimeout(() => setNotice(""), 3000)
  }, [])
  const confirmedRows = useMemo(() => visible.map(segment => (
    <SegmentRow key={segment.id} segment={segment} showTranslation={translation} onCopy={copy} />
  )), [visible, translation, copy])

  const storedText = confirmed.filter(segment => translation || segment.channel === "source")
  const state = summary?.session.state
  const title = live ? "Живая стенограмма" : summary ? dateFormat.format(new Date(summary.session.startedAt)) : "Стенограмма"
  const connectionText = connection === "online" ? "AirTranslate подключён" : connection === "connecting" ? "Подключение" : "Связь с AirTranslate потеряна"
  const ConnectionIcon = connection === "online" ? Wifi : connection === "connecting" ? LoaderCircle : WifiOff

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand"><span className="brand-mark"><AudioLines aria-hidden size={18} /></span><span>AirTranslate <span className="brand-edition">Study</span></span></div>
        <div className="top-actions">
          <span className="connection" role="status" title={connectionText}>
            <span className="connection-dot" data-online={connection === "online"} />
            <ConnectionIcon aria-hidden size={16} />
            <span>{connectionText}</span>
          </span>
          <Button variant="ghost" size="icon" title={dark ? "Светлая тема" : "Тёмная тема"} aria-label={dark ? "Включить светлую тему" : "Включить тёмную тему"}
            onClick={() => { const next = dark ? "light" : "dark"; setTheme(next); savePreference("theme", next) }}>
            {dark ? <Sun aria-hidden /> : <Moon aria-hidden />}
          </Button>
          <Button variant="ghost" size="icon" className="history-toggle" aria-expanded={historyOpen} aria-controls="session-history"
            title="История занятий" aria-label="История занятий" onClick={() => setHistoryOpen(!historyOpen)}><History aria-hidden /></Button>
        </div>
      </header>
      <div className="workspace">
        <aside className="history" id="session-history" data-expanded={historyOpen} aria-label="История занятий">
          <h2>Занятия</h2>
          {active && <Button variant="secondary" className="live-link" onClick={() => select(null)}>
            <AudioLines aria-hidden /> К живой записи
          </Button>}
          <nav aria-label="Сохранённые занятия">
            {study.sessions.map(item => <SessionLink key={item.session.id} item={item} selected={selected === item.session.id} onSelect={select} />)}
          </nav>
          {!study.sessions.length && !study.history.failed && <p className="history-note">{study.history.pending ? "Загружаем занятия…" : "Сохранённые занятия появятся здесь."}</p>}
          {study.history.failed && <Button variant="ghost" onClick={() => void study.loadHistory(study.history.next)}>Повторить загрузку</Button>}
          {study.history.next !== undefined && !study.history.failed && <Button variant="ghost" disabled={study.history.pending}
            onClick={() => void study.loadHistory(study.history.next)}>Ещё занятия <ChevronDown aria-hidden /></Button>}
        </aside>
        <main className="reader">
          <div className="reader-header">
            <div className="reader-width">
              <div className="heading-row">
                <h1>{title}</h1>
                {state && <span className="session-state" data-state={state}>{stateLabels[state]}</span>}
              </div>
              {summary && <p className="session-meta">
                <span>{languages(summary.session)}</span><span>{summary.session.model || summary.session.engine}</span>
                {live ? <span>{timeFormat.format(new Date(summary.session.startedAt))}</span> : <span>{clock(summary.durationMilliseconds)}</span>}
              </p>}
              <div className="tools" aria-label="Управление стенограммой">
                <div className="search-box"><Search aria-hidden size={16} />
                  <Input type="text" value={query} onChange={event => setQuery(event.target.value)} placeholder="Найти в стенограмме" aria-label="Найти в стенограмме" />
                  {query && <Button aria-label="Очистить поиск" variant="ghost" size="icon-xs" onClick={() => setQuery("")}><X aria-hidden /></Button>}
                </div>
                <label className="switch-label"><Switch checked={translation} onCheckedChange={value => {
                  setTranslation(value); savePreference("translation", value ? "on" : "off")
                }} /> Перевод</label>
                {live && <label className="switch-label"><Switch checked={follow} onCheckedChange={changeFollow} /> Автопрокрутка</label>}
                <Button variant="outline" className="copy-all" disabled={!storedText.length}
                  onClick={() => void copy(storedText.map(segment => segmentText(segment, translation)).join("\n\n"))}><Copy aria-hidden /> Копировать всё</Button>
              </div>
            </div>
          </div>
          <div className="feed" ref={feed} tabIndex={0} aria-label="Текст стенограммы"
            onWheel={event => { if (live && follow && event.deltaY < 0) changeFollow(false) }}
            onScroll={event => {
              const viewport = event.currentTarget
              if (live && follow && !search && viewport.scrollTop < lastFollowPosition.current - 48 &&
                  viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop > 48) changeFollow(false)
            }}
            onKeyDown={event => { if (live && follow && ["ArrowUp", "PageUp", "Home"].includes(event.key)) changeFollow(false) }}
            onPointerUp={() => {
              const selection = getSelection()
              if (live && follow && selection?.anchorNode && !selection.isCollapsed && feed.current?.contains(selection.anchorNode)) changeFollow(false)
            }}>
            <div className="reader-width feed-inner">
              {!study.storage && <p className="problem" role="status">Локальное хранилище временно недоступно. AirTranslate повторяет попытку сохранения.</p>}
              {study.failure && <div className="problem" role="status"><p>{study.failure === "missing" ? "Занятие не найдено." : "Не удалось загрузить стенограмму."}</p>
                <Button variant="outline" onClick={study.failure === "missing" ? () => select(null) : study.reloadTranscript}>
                  {study.failure === "missing" ? "Открыть последнее занятие" : "Повторить"}
                </Button></div>}
              {search && <p className="result-count" role="status">{visible.length ? `Найдено фраз: ${visible.length}` : "Совпадений нет"}</p>}
              {!search && !visible.length && !partials.length && !study.failure && (
                <div className="empty">
                  <h2>{study.loading || connection === "connecting" ? "Загружаем стенограмму…" : live ? "Ожидаем речь" : selected ? "В стенограмме пока нет фраз" : "Ждём начала занятия"}</h2>
                  {!selected && connection !== "connecting" && <p>Откройте AirTranslate на Mac и начните захват звука. Распознанные фразы появятся здесь.</p>}
                </div>
              )}
              <ol className="segments" aria-label="Подтверждённые фразы">
                {confirmedRows}
              </ol>
              {partials.length > 0 && <section className="partial-feed" aria-label="Распознаётся">
                <h2>Распознаётся</h2>
                <ol className="segments">{partials.map(segment => <SegmentRow key={segment.id} segment={segment} showTranslation={translation} onCopy={copy} />)}</ol>
              </section>}
            </div>
          </div>
          {live && !follow && !search && <div className="return-live"><Button size="lg" onClick={() => changeFollow(true)}><ArrowDownToLine aria-hidden /> К последней фразе</Button></div>}
        </main>
      </div>
      <div className={notice ? "toast" : "sr-only"} role="status">{notice}</div>
    </div>
  )
}

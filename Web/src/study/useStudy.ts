import { useEffect, useRef, useState } from "react"
import { applyFrame, fromPages, isActive, isAfter, summarize } from "./transcript.ts"
import type { Frame, SegmentPage, SessionPage, Status, Summary, Transcript } from "./transcript.ts"

const api = "/api/v1"
const kinds: Frame["kind"][] = ["status", "partial", "final", "translation", "retract", "resync"]

type Connection = "connecting" | "online" | "retrying"

class RequestError extends Error {
  constructor(readonly status: number) {
    super(`HTTP ${status}`)
  }
}

async function read<T>(path: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(`${api}${path}`, { signal, cache: "no-store" })
  if (!response.ok) throw new RequestError(response.status)
  return response.json()
}

function mergeSessions(previous: Summary[], incoming: Summary[]) {
  const sessions = new Map(previous.map(summary => [summary.session.id, summary]))
  for (const summary of incoming) {
    const before = sessions.get(summary.session.id)
    if (!before || Date.parse(summary.session.updatedAt) >= Date.parse(before.session.updatedAt)) {
      sessions.set(summary.session.id, summary)
    }
  }
  return [...sessions.values()].sort((a, b) => Date.parse(b.session.startedAt) - Date.parse(a.session.startedAt))
}

export function useStudy(pinnedSession: string | null) {
  const [connection, setConnection] = useState<Connection>("connecting")
  const [active, setActive] = useState<Summary>()
  const [storage, setStorage] = useState(true)
  const [sessions, setSessions] = useState<Summary[]>([])
  const [history, setHistory] = useState<{ next?: number; pending: boolean; failed: boolean }>({ pending: true, failed: false })
  const [transcript, setTranscript] = useState<Transcript>()
  const [loading, setLoading] = useState(false)
  const [failure, setFailure] = useState<"missing" | "unavailable">()
  const [reload, setReload] = useState(0)
  const selected = pinnedSession ?? active?.session.id ?? sessions[0]?.session.id
  const receive = useRef<(frame: Frame) => void>(() => {})
  const historyRequest = useRef<AbortController | undefined>(undefined)

  async function loadHistory(offset = 0) {
    historyRequest.current?.abort()
    const request = new AbortController()
    historyRequest.current = request
    setHistory(previous => ({ ...previous, pending: true, failed: false }))
    try {
      const page = await read<SessionPage>(`/sessions?offset=${offset}&limit=50`, request.signal)
      if (request.signal.aborted) return
      setSessions(previous => mergeSessions(previous, page.sessions))
      setHistory({ next: page.nextOffset, pending: false, failed: false })
    } catch {
      if (!request.signal.aborted) setHistory(previous => ({ ...previous, pending: false, failed: true }))
    }
  }

  useEffect(() => {
    const request = new AbortController()
    let source: EventSource | undefined
    let reconnect: number | undefined
    let storageAvailable = true

    function sessionStatus(session: Summary) {
      setActive(previous => {
        if (isActive(session.session)) return session
        return previous?.session.id === session.session.id ? undefined : previous
      })
      setSessions(previous => mergeSessions(previous, [session]))
    }

    async function connect() {
      try {
        const status = await read<Status>("/status", request.signal)
        if (request.signal.aborted) return
        storageAvailable = status.storageAvailable
        setStorage(status.storageAvailable)
        setActive(status.activeSession)
        if (status.activeSession) sessionStatus(status.activeSession)
        void loadHistory()
        source = new EventSource(`${api}/events?after=${encodeURIComponent(status.cursor)}`)
        source.onopen = () => setConnection("online")
        source.onerror = () => {
          setConnection("retrying")
          if (source?.readyState === EventSource.CLOSED) retry()
        }
        for (const kind of kinds) {
          source.addEventListener(kind, (event: MessageEvent<string>) => {
            const frame: Frame = { ...JSON.parse(event.data), kind }
            const recovered = !storageAvailable && frame.storageAvailable
            storageAvailable = frame.storageAvailable
            setStorage(frame.storageAvailable)
            if (kind === "resync") {
              setActive(frame.session ? summarize(frame.session) : undefined)
              if (frame.session) sessionStatus(summarize(frame.session))
              void loadHistory()
              setReload(value => value + 1)
              return
            }
            if (kind === "status" && frame.session) sessionStatus(summarize(frame.session))
            receive.current(frame)
            if (recovered) {
              void loadHistory()
              setReload(value => value + 1)
            }
          })
        }
        setReload(value => value + 1)
      } catch {
        if (!request.signal.aborted) retry()
      }
    }

    function retry() {
      source?.close()
      setConnection("retrying")
      reconnect = window.setTimeout(connect, 2000)
    }

    void connect()
    return () => {
      request.abort()
      historyRequest.current?.abort()
      window.clearTimeout(reconnect)
      source?.close()
    }
  }, [])

  useEffect(() => {
    if (!selected) return
    const request = new AbortController()
    const buffered: Frame[] = []
    let restoring = true
    const accumulate = (before: Transcript | undefined, frame: Frame) => {
      if (before?.summary.session.id === selected) return applyFrame(before, frame)
      if (!frame.session) return before
      return applyFrame({ summary: summarize(frame.session), confirmed: new Map(), partials: new Map() }, frame)
    }
    receive.current = frame => {
      if (frame.sessionID !== selected) return
      if (restoring) buffered.push(frame)
      else setTranscript(previous => accumulate(previous, frame))
    }
    setLoading(true)
    setFailure(undefined)

    async function restore() {
      try {
        const pages: SegmentPage[] = []
        let position: number | undefined = 0
        do {
          const page: SegmentPage = await read(`/sessions/${selected}/segments?after=${position}&limit=500`, request.signal)
          pages.push(page)
          position = page.nextPosition
        } while (position !== undefined)
        if (request.signal.aborted) return
        const late = buffered.filter(frame => isAfter(frame.cursor, pages[0].cursor))
        setTranscript(previous => late.reduce(applyFrame, fromPages(pages, previous)))
        restoring = false
        buffered.length = 0
      } catch (error) {
        if (request.signal.aborted) return
        setFailure(error instanceof RequestError && error.status === 404 ? "missing" : "unavailable")
        restoring = false
        const pending = buffered.slice()
        setTranscript(previous => pending.reduce(accumulate, previous))
        buffered.length = 0
      } finally {
        if (!request.signal.aborted) setLoading(false)
      }
    }

    void restore()
    return () => {
      request.abort()
      receive.current = () => {}
    }
  }, [selected, reload])

  return {
    active, connection, storage, sessions, history, selected, loading, failure,
    transcript: transcript?.summary.session.id === selected ? transcript : undefined,
    summary: transcript?.summary.session.id === selected ? transcript?.summary : sessions.find(row => row.session.id === selected),
    loadHistory,
    reloadTranscript: () => setReload(value => value + 1),
  }
}

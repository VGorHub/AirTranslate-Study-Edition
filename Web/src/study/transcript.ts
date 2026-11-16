export type SessionState = "recording" | "paused" | "reconnecting" | "finishing" | "completed" | "interrupted"

export interface Session {
  id: string
  startedAt: string
  sourceLanguage?: string
  targetLanguage?: string
  engine: string
  model: string
  state: SessionState
  updatedAt: string
}

export interface Summary {
  session: Session
  durationMilliseconds: number
  endedAt?: string
}

export interface Segment {
  id: string
  sessionID: string
  position: number
  channel: "source" | "translation"
  startMilliseconds: number
  endMilliseconds?: number
  timing: "audio" | "receipt"
  language?: string
  revision: number
  isFinal: boolean
  text: string
  translation?: string
  translationLanguage?: string
}

export interface Status {
  cursor: string
  storageAvailable: boolean
  activeSession?: Summary
}

export interface SessionPage {
  sessions: Summary[]
  nextOffset?: number
}

export interface SegmentPage {
  session: Summary
  segments: Segment[]
  partials: Segment[]
  nextPosition?: number
  cursor: string
}

export interface Frame {
  kind: "status" | "partial" | "final" | "translation" | "retract" | "resync"
  cursor: string
  storageAvailable: boolean
  session?: Session
  sessionID?: string
  segment?: Segment
  segmentID?: string
}

export interface Transcript {
  summary: Summary
  confirmed: ReadonlyMap<string, Segment>
  partials: ReadonlyMap<string, Segment>
}

export function isActive(session: Session) {
  return session.state !== "completed" && session.state !== "interrupted"
}

export function summarize(session: Session): Summary {
  return {
    session,
    durationMilliseconds: Math.max(0, Date.parse(session.updatedAt) - Date.parse(session.startedAt)),
    endedAt: isActive(session) ? undefined : session.updatedAt,
  }
}

export function isAfter(candidate: string, baseline: string) {
  const [epoch, sequence] = candidate.split(":")
  const [baselineEpoch, baselineSequence] = baseline.split(":")
  return epoch === baselineEpoch && BigInt(sequence) > BigInt(baselineSequence)
}

function omit(segments: ReadonlyMap<string, Segment>, id: string) {
  if (!segments.has(id)) return segments
  const next = new Map(segments)
  next.delete(id)
  return next
}

function merge(previous: Segment | undefined, incoming: Segment) {
  if (!previous) return incoming
  if (previous.revision > incoming.revision) return previous
  if (previous.revision === incoming.revision) {
    if (previous.translation && !incoming.translation) return previous
    if (previous.text === incoming.text && previous.translation === incoming.translation &&
        previous.translationLanguage === incoming.translationLanguage &&
        previous.startMilliseconds === incoming.startMilliseconds && previous.endMilliseconds === incoming.endMilliseconds &&
        previous.language === incoming.language && previous.timing === incoming.timing) return previous
  }
  return incoming
}

export function fromPages(pages: SegmentPage[], previous?: Transcript): Transcript {
  const first = pages[0]
  const last = pages[pages.length - 1]
  const confirmed = new Map<string, Segment>()
  for (const page of pages) {
    for (const segment of page.segments) confirmed.set(segment.id, merge(previous?.confirmed.get(segment.id), segment))
  }
  const partials = new Map(first.partials.filter(segment => !confirmed.has(segment.id)).map(segment => [segment.id, segment]))
  return { summary: last.session, confirmed, partials: isActive(last.session.session) ? partials : new Map() }
}

export function applyFrame(transcript: Transcript, frame: Frame): Transcript {
  if (frame.sessionID !== transcript.summary.session.id) return transcript
  const { confirmed, partials, summary } = transcript
  const segment = frame.segment
  if (frame.kind === "status" && frame.session) {
    const updated = frame.session
    if (Date.parse(updated.updatedAt) < Date.parse(summary.session.updatedAt)) return transcript
    return { ...transcript, summary: summarize(updated), partials: isActive(updated) ? partials : new Map() }
  }
  if (frame.kind === "retract" && frame.segmentID) {
    const next = omit(partials, frame.segmentID)
    return next === partials ? transcript : { ...transcript, partials: next }
  }
  if (!segment) return transcript
  if (frame.kind === "partial") {
    if (!isActive(summary.session) || confirmed.has(segment.id)) return transcript
    const previous = partials.get(segment.id)
    const next = merge(previous, segment)
    if (previous === next) return transcript
    return { ...transcript, partials: new Map(partials).set(segment.id, next) }
  }
  if (frame.kind !== "final" && frame.kind !== "translation") return transcript
  const previous = confirmed.get(segment.id)
  const next = merge(previous, segment)
  if (previous === next) return transcript
  return { ...transcript, confirmed: new Map(confirmed).set(segment.id, next), partials: omit(partials, segment.id) }
}

export function segmentText(segment: Segment, showTranslation: boolean) {
  return showTranslation && segment.translation ? `${segment.text}\n${segment.translation}` : segment.text
}

export function clock(milliseconds: number) {
  const seconds = Math.floor(milliseconds / 1000)
  const minutes = Math.floor(seconds / 60)
  const pair = (value: number) => String(value).padStart(2, "0")
  const hour = minutes >= 60 ? `${Math.floor(minutes / 60)}:` : ""
  return `${hour}${pair(minutes % 60)}:${pair(seconds % 60)}`
}

import assert from "node:assert/strict"
import { test } from "node:test"
import { applyFrame, fromPages, isAfter, summarize } from "../src/study/transcript.ts"
import type { Frame, Segment, Session } from "../src/study/transcript.ts"

const session: Session = {
  id: "lesson", startedAt: "2026-11-16T18:00:00Z", updatedAt: "2026-11-16T18:05:00Z",
  engine: "Apple", model: "Apple Mode", state: "recording",
}
const segment: Segment = {
  id: "first", sessionID: session.id, position: 1, channel: "source", startMilliseconds: 0,
  timing: "audio", language: "en-US", revision: 1, isFinal: false, text: "Today we are",
}
function frame(kind: Frame["kind"], fields: Partial<Frame> = {}): Frame {
  return { kind, cursor: "epoch:3", storageAvailable: true, sessionID: session.id, ...fields }
}
function snapshot(segments: Segment[] = [], partials: Segment[] = []) {
  return fromPages([{ session: summarize(session), segments, partials, cursor: "epoch:1" }])
}

test("corrections and finalization share the phrase ID", () => {
  const partial = applyFrame(snapshot(), frame("partial", { segment }))
  const corrected = { ...segment, revision: 2, text: "Today we will" }
  const current = applyFrame(partial, frame("partial", { segment: corrected }))
  assert.deepEqual([...current.partials.values()], [corrected])
  const final = { ...corrected, revision: 3, isFinal: true, text: "Today we will study." }
  const finished = applyFrame(current, frame("final", { segment: final }))
  assert.equal(finished.partials.size, 0)
  assert.deepEqual([...finished.confirmed.values()], [final])
  assert.strictEqual(applyFrame(finished, frame("partial", { segment: corrected })), finished)
})

test("snapshot replay preserves existing confirmed rows and their translations", () => {
  const finalized = { ...segment, isFinal: true, translation: "Сегодня мы будем учиться." }
  const loaded = snapshot([finalized])
  const duplicate = { ...finalized }
  const second = { ...finalized, id: "second", position: 2 }
  const merged = fromPages([{ session: summarize(session), segments: [duplicate, second], partials: [], cursor: "epoch:2" }], loaded)
  assert.strictEqual(merged.confirmed.get(segment.id), finalized)
  const replay = applyFrame(merged, frame("final", { segment: { ...finalized, translation: undefined } }))
  assert.strictEqual(replay, merged)
  assert.equal(replay.confirmed.size, 2)
})

test("retraction and stop remove only temporary text", () => {
  const finalized = { ...segment, isFinal: true }
  const second = { ...segment, id: "second", position: 2 }
  const loaded = snapshot([finalized], [second])
  assert.equal(applyFrame(loaded, frame("retract", { segmentID: second.id })).partials.size, 0)
  const ended = applyFrame(loaded, frame("status", { session: { ...session, state: "completed" } }))
  assert.equal(ended.partials.size, 0)
  assert.strictEqual(ended.confirmed, loaded.confirmed)
})

test("only newer events from the snapshot epoch are replayed", () => {
  assert.equal(isAfter("epoch:10", "epoch:9"), true)
  assert.equal(isAfter("epoch:9", "epoch:9"), false)
  assert.equal(isAfter("other:10", "epoch:9"), false)
})

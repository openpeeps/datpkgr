# datpkgr - install-time thread pool on pkg/threading/channels
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr
#
# Bounded worker pool used only by the install path (version discovery,
# file install, multi-root updates). Workers are plain `{.gcsafe.}` procs
# exchanging only value data through channels — they never touch `cfg`,
# the stores, or host callbacks. All progress events are replayed on the
# caller's thread AFTER the join (post-await drain), so host display code
# always runs single-threaded.

import pkg/threading/channels
import std/isolation
from std/osproc import countProcessors

import ./config

type
  ProgressKind* = enum
    pkFetchStart
    pkCloneStart
    pkInstallStart

  ProgressEvent* = object
    kind*: ProgressKind
    name*: string
    label*: string
    url*: string

proc poolSizeFor*(nJobs: int): int =
  ## Worker count: `min(cpuCount, jobs)`, at least 1 when work exists.
  ## Git-heavy jobs are additionally throttled by the git semaphore.
  if nJobs <= 1:
    return nJobs
  var cpus = 1
  try:
    cpus = max(1, countProcessors())
  except:
    cpus = 1
  max(1, min(nJobs, cpus))

proc replayProgress*(cfg: DatpkgrConfig, events: seq[ProgressEvent]) =
  ## Replays worker progress on the caller's thread (main-thread only).
  ## Workers only ever `trySend` these; invocation of host callbacks
  ## happens exclusively here, never off-thread.
  for ev in events:
    case ev.kind
    of pkFetchStart:
      if cfg.callbacks.onFetchStart != nil:
        cfg.callbacks.onFetchStart(ev.name)
    of pkCloneStart:
      if cfg.callbacks.onCloneStart != nil:
        cfg.callbacks.onCloneStart(ev.name, ev.url)
    of pkInstallStart:
      if cfg.callbacks.onInstallStart != nil:
        cfg.callbacks.onInstallStart(ev.label)

proc runPool*[J, R](jobs: seq[J],
    worker: proc(job: J, progress: Chan[ProgressEvent]): R {.gcsafe.}):
    tuple[results: seq[R], progress: seq[ProgressEvent]] =
  ## Runs `worker` over `jobs` on a bounded std-thread pool and joins.
  ## Results come back in input order; progress events come back in channel
  ## (FIFO send) order for the caller to replay via `replayProgress`.
  ## Workers must be total (never raise): every fallible operation maps to
  ## a failure value of `R`, since a dead worker would stall the drain.
  result.results = @[]
  result.progress = @[]
  if jobs.len == 0:
    return
  type
    PJ = tuple[idx: int, job: J]
    PR = tuple[idx: int, res: R]
  let nWorkers = poolSizeFor(jobs.len)
  var jobCh = newChan[PJ](jobs.len + nWorkers + 1)
  var resCh = newChan[PR](jobs.len + 1)
  var progCh = newChan[ProgressEvent](jobs.len * 2 + nWorkers + 1)
  type Args = tuple[jobCh: Chan[PJ], resCh: Chan[PR],
                    progCh: Chan[ProgressEvent],
                    worker: proc(job: J,
                      progress: Chan[ProgressEvent]): R {.gcsafe.}]
  proc loop(args: Args) {.thread.} =
    while true:
      let pj = args.jobCh.recv()
      if pj.idx < 0:
        break
      let r = args.worker(pj.job, args.progCh)
      args.resCh.send(isolate((idx: pj.idx, res: r)))
  for i, j in jobs:
    jobCh.send(isolate((idx: i, job: j)))
  var threads = newSeq[Thread[Args]](nWorkers)
  let args: Args = (jobCh, resCh, progCh, worker)
  for t in threads.mitems:
    createThread(t, loop, args)
  # Stop pills: one per worker, queued behind all real jobs.
  for _ in 0 ..< nWorkers:
    jobCh.send(isolate((idx: -1, job: jobs[0])))
  for t in threads.mitems:
    joinThread(t)
  result.results = newSeq[R](jobs.len)
  for _ in 0 ..< jobs.len:
    let pr = resCh.recv()
    result.results[pr.idx] = pr.res
  var ev: ProgressEvent
  while progCh.tryRecv(ev):
    result.progress.add(ev)
    ev = ProgressEvent()

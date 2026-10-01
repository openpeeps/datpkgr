# datpkgr - install-time thread pool on pkg/threading/channels
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datpkgr
#
# Bounded worker pool used only by the install path (version discovery,
# file install, multi-root updates). Workers are plain `{.gcsafe.}` procs.

import pkg/threading/channels
import std/isolation
from std/osproc import countProcessors

type
  ProgressKind* = enum
    pkFetchStart
    pkCloneStart
    pkInstallStart

  ProgressEvent* = object
    ## Progress marker, worker → main. Plain data only (see contract above):
    ## the caller resolves display strings from its own jobs via `idx`.
    kind*: ProgressKind
    idx*: int

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

proc runPoolStreaming*[J, R](jobs: seq[J],
    worker: proc(job: J, progress: Chan[ProgressEvent]): R {.gcsafe.},
    onResult: proc(idx: int, res: R)):
    tuple[results: seq[R], progress: seq[ProgressEvent]] =
  ## Like `runPool`, but `onResult` fires on the calling thread as each result
  ## arrives rather than in one burst once every worker has been joined, so a
  ## long run reports progress instead of going quiet. Everything else is
  ## identical — in particular `onResult` is still single-threaded and may
  ## touch the display, results still come back in input order, and progress
  ## events are still drained on this thread.
  ## Callbacks fire in *completion* order, so index anything display-related
  ## through the `idx` against your own `jobs`.
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
  # Drain while the workers are still running: every job produces exactly one
  # result, so receiving `jobs.len` of them means each worker has already sent
  # and only has to pick up its stop pill. Joining first would sit here until
  # the slowest job finished and `onResult` would fire in one burst at the end.
  result.results = newSeq[R](jobs.len)
  var ev: ProgressEvent
  for _ in 0 ..< jobs.len:
    let pr = resCh.recv()
    result.results[pr.idx] = pr.res
    onResult(pr.idx, pr.res)
    while progCh.tryRecv(ev):
      result.progress.add(ev)
      ev = ProgressEvent()
  for t in threads.mitems:
    joinThread(t)

proc runPool*[J, R](jobs: seq[J],
    worker: proc(job: J, progress: Chan[ProgressEvent]): R {.gcsafe.}):
    tuple[results: seq[R], progress: seq[ProgressEvent]] =
  ## Runs `worker` over `jobs` on a bounded std-thread pool and joins.
  ## Results come back in input order; progress events come back in channel
  ## (FIFO send) order for the caller to replay on its own thread, resolving
  ## display strings from its own `jobs` via `ProgressEvent.idx`.
  ## Workers must be total (never raise): every fallible operation maps to
  ## a failure value of `R`, since a dead worker would stall the drain.
  ## `R` must be plain data (ints/bools) — see the threading contract above.
  runPoolStreaming(jobs, worker, proc (idx: int, res: R) = discard)

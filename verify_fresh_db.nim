# TEMP-VERIFY (delete after green): fresh-DB crash repro for the Windows
# SIGSEGV. Drives datpkgr `installPackage` over a fresh root with real fetch
# waves + version-cache writes + install pool — the exact crash window from
# `clue install` on an empty ~/.clue. Needs no clue binary and no registry
# packages beyond git access. Usage: verify_fresh_db <fresh-root>
import std/[os, strutils, json]
import pkg/semver
import datpkgr/config
import datpkgr/types
import datpkgr/operations

proc logCb(level: LogLevel, msg: string) {.gcsafe.} =
  stderr.writeLine("[" & $level & "] " & msg)
  try: flushFile(stderr) except: discard

proc miniParse(content, path: string): Manifest =
  ## Tiny nimble parser: name from filename, version scalar scan,
  ## requires "..." lines with `name [op ver]` and optional #ref.
  result = Manifest(path: path, extra: newJObject())
  result.name = path.splitFile.name
  for line in content.splitLines():
    let t = line.strip()
    if t.startsWith("version"):
      let q1 = t.find('"')
      let q2 = t.rfind('"')
      if q1 >= 0 and q2 > q1:
        result.version = t[q1+1 ..< q2]
    elif t.startsWith("requires"):
      let q1 = t.find('"')
      let q2 = t.rfind('"')
      if q1 < 0 or q2 <= q1: continue
      for part in t[q1+1 ..< q2].split(','):
        var spec = part.strip()
        if spec.len == 0: continue
        if spec.endsWith("]"):
          let lb = spec.rfind('[')
          if lb >= 0:
            spec = spec[0 ..< lb].strip()
        let ws = spec.splitWhitespace()
        if ws.len == 0: continue
        var namePart = ws[0]
        var refStr = ""
        let hp = namePart.find('#')
        if hp >= 0:
          refStr = namePart[hp+1 .. ^1]
          namePart = namePart[0 ..< hp]
        if namePart.len == 0 or namePart == "nim": continue
        if namePart.contains("://"):
          continue # skip URL deps in repro
        var c = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
        if ws.len >= 3:
          try:
            c = parseConstraint(ws[1] & ws[2])
          except CatchableError:
            discard
        result.dependencies.add(PkgDependency(name: namePart,
          constraint: c, branch: refStr, features: @[]))

proc miniFinder(dir: string): string =
  if dirExists(dir):
    for f in walkFiles(dir / "*.nimble"):
      if f.extractFilename != "nim.nimble":
        return f
  ""

if paramCount() < 1:
  stderr.writeLine("usage: verify_fresh_db <fresh-root>")
  quit(2)
let root = paramStr(1)
echo "verify root: ", root
var cfg = newDatpkgrConfig("verify", rootPath = root,
  callbacks = Callbacks(log: logCb), allowSubmodules = true)
cfg.defaultRegistryUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
cfg.defaultSourceName = "nim-lang"
cfg.toolchainName = "nim"
cfg.manifestParser = miniParse
cfg.manifestFileName = proc(pkg: string): string = pkg & ".nimble"
cfg.manifestFinder = miniFinder

# The exact crash window: kapsis wave pair + version-cache writes.
let deps = @[
  ("kapsis", ">= 0.4.8"), ("semver", ">= 1.2.3"),
  ("checksums", ">= 0.2.2"), ("bigints", ">= 1.1.0"),
  ("blackpaper", ">= 0.1.0"),
]
var allOk = true
for (name, cs) in deps:
  let c =
    try: parseConstraint(cs)
    except CatchableError:
      VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
  let ok = cfg.installPackage(name, verbose = true, constraint = c,
    suppressSummary = true)
  echo "install(" & name & ") returned: ", ok
  allOk = allOk and ok
echo "ALL DONE: ", allOk
if not allOk:
  quit(1)

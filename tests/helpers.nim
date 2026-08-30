import std/[os, strutils, tempfiles, json]
import datpkgr/config
import datpkgr/types

proc tempCfg*(app = "datpkgr_test"): DatpkgrConfig =
  let dir = createTempDir("datpkgr_", "")
  result = newDatpkgrConfig(app, dir)
  # reduce noise: silence log by default
  result.callbacks.log = proc(lvl: LogLevel, msg: string) {.gcsafe.} = discard

proc cleanupCfg*(cfg: DatpkgrConfig) =
  if cfg != nil and cfg.rootPath.len > 0 and dirExists(cfg.rootPath):
    try: removeDir(cfg.rootPath)
    except: discard

proc withTempCfg*(body: proc(cfg: DatpkgrConfig)) =
  let cfg = tempCfg()
  defer: cleanupCfg(cfg)
  body(cfg)

proc fakeParser*(content: string, path: string): Manifest =
  ## Minimal Manifest parser for tests: name = filename without ext, version from `version = "..."` line
  var m = Manifest(path: path, name: path.extractFilename.changeFileExt(""), extra: newJObject())
  for line in content.splitLines():
    let t = line.strip()
    if t.startsWith("version"):
      let eq = t.find('=')
      if eq >= 0:
        var v = t[eq+1..^1].strip().strip(chars={'"', '\''})
        m.version = v
  # keep dependencies empty, extra holds skip/src etc if needed
  m

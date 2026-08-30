import std/[sequtils, tables, unittest]
import pkg/semver
import datpkgr/resolver

type
  SimDep = object
    name: string
    constraint: string
    features: seq[string]

  SimPkg = object
    name: string
    version: string
    deps: seq[SimDep]
    features: Table[string, seq[SimDep]]

func simDep*(name, constraint: string, features: seq[string] = @[]): SimDep =
  SimDep(name: name, constraint: constraint, features: features)

func simPkg*(name, version: string, deps: seq[SimDep] = @[],
    features: Table[string, seq[SimDep]] = initTable[string, seq[SimDep]]()): SimPkg =
  SimPkg(name: name, version: version, deps: deps, features: features)

proc toDep(d: SimDep): Dependency =
  Dependency(name: d.name, constraint: parseConstraint(d.constraint), features: d.features)

proc makeSim*(pkgs: openArray[SimPkg]): (PackageRegistry, DepProvider) =
  var registry: PackageRegistry
  var depsOf = initTable[(string, string), seq[Dependency]]()
  var featOf = initTable[(string, string), Table[string, seq[Dependency]]]()
  for p in pkgs:
    registry.addPackage(UnresolvedPackage(name: p.name,
      version: parseVersion(p.version), dependencies: @[]))
    var deps: seq[Dependency]
    for d in p.deps:
      deps.add(toDep(d))
    depsOf[(p.name, p.version)] = deps
    if p.features.len > 0:
      var fmap: Table[string, seq[Dependency]]
      for fname, fdeps in p.features:
        var arr: seq[Dependency]
        for d in fdeps:
          arr.add(toDep(d))
        fmap[fname] = arr
      featOf[(p.name, p.version)] = fmap
  proc provider(name: string, version: Version, features: seq[string]): seq[Dependency] =
    result = depsOf.getOrDefault((name, $version), @[])
    for f in features:
      for d in featOf.getOrDefault((name, $version)).getOrDefault(f, @[]):
        result.add(d)
  (registry, provider)

proc root*(name: string, constraint = "*"): Dependency =
  Dependency(name: name, constraint: parseConstraint(constraint))

proc versionOf(res: Resolution, name: string): string =
  for rp in res.packages:
    if rp.name == name:
      return $rp.version
  ""

proc resolvedNames(res: Resolution): seq[string] =
  for rp in res.packages:
    result.add(rp.name)

proc chain(names: openArray[string]): seq[SimPkg] =
  for i in 0 ..< names.len:
    if i == names.high:
      result.add(simPkg(names[i], "1.0.0"))
    else:
      result.add(simPkg(names[i], "1.0.0", @[simDep(names[i + 1], "1.0.0")]))

suite "DFS complex graphs — deep chains":
  test "16-level linear chain resolves completely":
    var (registry, provider) = makeSim(chain(["A", "B", "C", "D", "E", "F", "G", "H",
      "I", "J", "K", "L", "M", "N", "O", "P"]))
    let res = registry.resolveDetailed(@[root("A")], provider)
    for name in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
                 "K", "L", "M", "N", "O", "P"]:
      check versionOf(res, name) == "1.0.0"
    check res.packages.len == 16

  test "leaf conflict in a deep chain is a soft violation (nearest wins)":
    var pkgs = chain(["A", "B", "C", "D", "E"])
    pkgs[0].deps.add(simDep("Z", ">= 1.0.0"))
    pkgs[^1].deps.add(simDep("Z", "< 0.5.0"))
    pkgs.add(simPkg("Z", "0.4.0"))
    pkgs.add(simPkg("Z", "1.0.0"))
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("A")], provider)
    check versionOf(res, "Z") == "1.0.0"
    check res.softViolations.len >= 1

suite "DFS complex graphs — diamonds and shared subgraphs":
  test "simple diamond resolves the shared dep once":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("C", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "1.0.0"
    check res.packages.len == 4
    check res.packages.filterIt(it.name == "C").len == 1

  test "diamond with intersecting constraints at the same depth":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", ">= 1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "< 2.0.0")]),
      simPkg("C", "1.0.0"), simPkg("C", "1.5.0"), simPkg("C", "2.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "1.5.0"

suite "DFS complex graphs — backtracking":
  test "newest root version drags in an unsatisfiable subtree -> older root":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "3.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("A", "2.0.0", @[simDep("X", ">= 2.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("X", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "A") == "1.0.0"
    check versionOf(res, "X") == "1.0.0"

  test "exhausting every candidate raises VersionConflictError":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "2.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("X", "1.0.0"),
    ])
    expect VersionConflictError:
      discard registry.resolveDetailed(@[root("R")], provider)

  test "probe budget exceeded raises BacktrackLimitError":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "5.0.0", @[simDep("P", ">= 5.0.0")]),
      simPkg("A", "4.0.0", @[simDep("P", ">= 4.0.0")]),
      simPkg("A", "3.0.0", @[simDep("P", ">= 3.0.0")]),
      simPkg("P", "1.0.0"),
    ])
    expect BacktrackLimitError:
      discard registry.resolveDetailed(@[root("R")], provider, maxProbes = 2)

suite "DFS complex graphs — cycles":
  test "direct mutual cycle raises CircularDependencyError":
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("A")], provider)

suite "DFS complex graphs — git refs and pending":
  test "unknown package deep in the graph reports pending names":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("MysteryPkg", "*")]),
    ])
    try:
      discard registry.resolveDetailed(@[root("R")], provider)
      check false
    except PackageNotFoundError as e:
      check "MysteryPkg" in e.pending

suite "DFS complex graphs — features at depth":
  test "feature at depth 2 pulls feature-only deps":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("App", "1.0.0")]),
      simPkg("App", "1.0.0", @[simDep("Lib", "1.0.0", @["full"])]),
      simPkg("Lib", "1.0.0", @[simDep("Core", "1.0.0")],
        {"full": @[simDep("Fancy", "1.0.0")]}.toTable),
      simPkg("Core", "1.0.0"),
      simPkg("Fancy", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "Fancy") == "1.0.0"

# hxc

**A Haxe 4.3 compiler, written in Haxe.**

hxc parses, types, runs macros and generates code for real Haxe projects. It is a drop-in
replacement for Haxe 4.3.7: the same command line, the same `.hxml` files and the same error
messages, and for the targets it supports, the same output. It is self-hosting: hxc compiles its own
source into a working compiler.

Because hxc is written in Haxe, anyone who writes Haxe can read, debug and extend the compiler in the
editor they already use. Targets, filters and tooling are ordinary Haxe modules.

hxc is the compiler underneath **[hx+](https://hxplus.org)**, a strict superset of Haxe 4.3.

```bash
hxc build.hxml          # wherever you would have typed `haxe build.hxml`
```

## Status

hxc tracks Haxe **4.3.7**. Where a target is supported, the goal is identical output, not similar
output.

| Area | State |
| --- | --- |
| Parser, typer, abstracts, `@:multiType`, static extensions, the Haxe 4 type system | Supported |
| Macros: init, build and expression macros, `haxe.macro` APIs, `sys` in the macro world | Supported, in hxc's own eval interpreter |
| `--js` | Supported |
| `--cpp`, `--cppia` | Supported, using hxcpp to build |
| `--interp`, `--run` | Supported |
| `--xml`, `--json` type descriptions | Supported |
| Compilation server | `--wait stdio` and `--server-connect`; listening on a TCP port is not yet supported |
| Editor support | Hover, completion, signature help, go to definition, document symbols, diagnostics |
| `--jvm` | Supported, with Java libraries through `--java-lib` (needs hxjava) |
| `--cs` | Type-checks against .NET assemblies given with `--net-lib`/`--net-std` (needs hxcs, like Haxe); no output is written yet, unless `-D dotnet` is set |
| `--cs <dir> -D dotnet` | Writes `<name>.dll` (plus `<name>.runtimeconfig.json` with `-main`) for .NET 10 or later, straight to IL with no C# step (needs hxcs, like `--cs` above). Early: classes (with reflection), interfaces, structs, generics, statics, strings, arrays, `Dynamic`, anonymous objects, `Null<T>`, enums, closures, `dynamic` methods, `Int64`, `Std`/`Type`/`Reflect`, generic instantiations and the casts between them, the Serializer, exceptions and calls into `--net-lib` assemblies (overloads, generic methods, `Nullable<T>`, indexers, properties, delegates) work; see [.NET output](#net-output) |
| `--lua`, `--python`, `--php`, `--hl`, `--neko`, `--swf` | Accepted on the command line; no output is written yet |

Prebuilt binaries are available for Windows x64, Linux x64 and macOS on Apple silicon.

## Install

### Download

Download `hxc-windows-x64.exe`, `hxc-linux-x64` or `hxc-macos-arm64` from the
[latest release](https://github.com/dimensionscape/hxc/releases/latest).

### From haxelib

```bash
haxelib install hxc
haxelib run hxc build.hxml
```

The first run downloads the release binary for your platform. hxc compiles against the standard
library of the Haxe you have installed.

To build hxc from the library's own source instead, for a platform without a release binary or to
use your own build, install the requirements under [Building from source](#building-from-source) and
run:

```bash
haxelib run hxc rebuild
```

`haxelib run hxc` then uses that build.

### The standard library

hxc uses the Haxe 4.3 standard library rather than shipping its own. If it is not found next to the
binary, point `HAXE_STD_PATH` at it:

```bash
export HAXE_STD_PATH=/path/to/haxe/std        # Windows: set HAXE_STD_PATH=C:\HaxeToolkit\haxe\std
```

## Usage

hxc accepts the same command line as `haxe`:

```bash
hxc -p src -m Main --js bin/main.js           # JavaScript
hxc -p src -m Main --cpp bin/cpp              # C++, built with hxcpp
hxc -p src -m Main --cppia bin/main.cppia     # cppia
hxc -p src -m Main --jvm bin/main.jar          # JVM bytecode
hxc -p src -m Main --cs bin/net -D dotnet    # .NET 10 assembly, bin/net/net.dll (early)
hxc -p src --run Main arg1 arg2               # run in the interpreter
hxc -p src -m Main --xml types.xml --no-output
hxc build.hxml
```

`hxc --help` prints the full option list. `hxc --version` reports `4.3.7`, the language version hxc
implements, so build tools that check the compiler version keep working.

### Compilation server

```bash
hxc --wait stdio
```

Requests arrive on stdin as length-prefixed blocks of arguments, and modules stay cached between
requests, so a warm rebuild of a small project returns in milliseconds. `--server-connect
host:port` connects out to a client that is listening instead.

### .NET output

`--cs <dir> -D dotnet` writes `<dir>/<name>.dll` straight as IL, with no C# step. Like `--cs`, it needs
hxcs (`haxelib install hxcs`): hxcs supplies the reference assemblies and the standard library's
runtime sources. With `-main` it also writes `<name>.runtimeconfig.json` for `net10.0`, so
`dotnet <name>.dll` runs the program on .NET 10; `-D dotnet-version=<N>` builds it for a later .NET
instead (a whole number, 10 or more, e.g. `-D dotnet-version=11` for `net11.0`). `-D dll-name=<name>`
sets the name; the default is the output directory's last segment.

The assembly's references resolve against hxcs's `netlib` directory for `-D net-ver` (default 20), or
the directories given with `--net-std`. By default that means a reference to `mscorlib` 2.0.0.0,
which .NET 10 and later forward to their own libraries.

Code can use the assemblies given with `--net-lib`, as gencs's output does. A .NET type that a
`--net-lib` assembly uses but no supplied assembly defines, such as its base class or a framework type
in its signatures, is read from beside that assembly, then from the .NET reference pack:
`<dotnet root>/packs/Microsoft.NETCore.App.Ref/<newest N.0.x>/ref/netN.0` for the `-D dotnet-version` N
(default 10), where the dotnet root is `DOTNET_ROOT`, else the directory of `dotnet` on the `PATH`. So
the .NET SDK must be installed, not only the runtime; a pack that is needed and missing is a compile
error that names it. Those assemblies are used to write the output only: as in Haxe, Haxe code sees
only the assemblies passed, and a type defined only in one of them is "Type not found".

- **Calls** bind the .NET overload gencs's C# would bind, generic .NET methods included, or are a
  compile error. A hand-written extern (`@:native`) binds the overload C#'s compiler picks for its
  declared types and for its arguments' own types, which must agree, with omitted optional and `params`
  arguments filled as C# fills them. Its fields and properties are looked up from the receiver's type,
  as C# looks them up, so a derived class's `new` member hides the base's. Where two overloads apply,
  or hxc cannot tell whether one does, the call is a compile error rather than a guess, even where C#
  would pick the more specific one. So is a call where C# picks the overload by an argument's value:
  an integer constant, which C# also converts to a narrower integer type it fits and, if 0, to an enum
  (`B(5)` with `B(byte)` and `B(object)`), or `null`, which C# converts to every reference type
  (`N(null)` with `N(Thing)` and `N(object)`, or a left-out optional argument, which gencs passes as
  `null`). Declare the parameter's exact type, or use `@:overload`.
- **Value types:** `System.Nullable<T>` works, through `HasValue`, `Value`, `== null` and string
  concatenation. `null` passed or assigned where a .NET struct is expected is that struct's
  `default(T)`, as under gencs, so a `Nullable<DateTime>` built from a `null` `DateTime` has a value,
  `0001-01-01`. `x == null` is `!x.HasValue` on a `Nullable` and `x.Equals(default(T))` on another
  struct.
- **Indexers:** `a[i]` on a .NET type with an indexer calls it, compound assignment included.
- **Properties:** a Haxe class implementing a .NET interface's properties (`var x(get, set)`) gives
  them CLR properties, so C# code reading them through the interface gets the Haxe getters' values.
  A `@:property` var is a CLR property too, so System.Text.Json and .NET reflection see it.
- **Delegates:** a Haxe function, lambda or method converts to a .NET delegate as gencs converts it,
  and a delegate's `+` and `-` combine and remove. A handler made again from the same method removes
  the first. `Thread.create` works. A conversion whose types do not match the delegate's `Invoke`
  (an `Int -> Bool` function as a `Func_2<Dynamic, Bool>`) is a compile error, as gencs's C# fails to
  compile there (CS0030) or its cast throws at run time.

Classes, interfaces, structs, generics, statics, operators, strings, arrays and native .NET
exceptions work, including `try`/`catch`/`throw` of `cs.system.Exception` subclasses. Classes have
the shape Haxe's own `--cs` generator gives them: they extend `haxe.lang.HxObject`, and fields and
methods can be reached by reflection (`Reflect.field`, `Reflect.setField`, `Reflect.callMethod`,
`Reflect.hasField` and the `Dynamic` field operations behind them). `Dynamic` works for field access,
calls, arithmetic, comparison, equality, string concatenation and conversion to and from the basic
types; reading an element of a `Dynamic` works, assigning one is not supported yet. Anonymous
objects (`{x: 1}`, printed and read through `Dynamic`) and `Null<T>`, including `Null<Int>`,
`Null<Float>` and `Null<Bool>` and defaulted arguments, work too.

Haxe enums become gencs's classes (`<pack>.<Enum>` and one `<pack>.<Enum>_<Ctor>` per constructor),
and `switch` on them works, also through an abstract over the enum or on a `Dynamic`. `switch` also
works on an `Int`, `Float`, `Bool` or `String`, on a `Class` or `Enum` value against types, and on a
`Dynamic` against constant patterns, which compare with `Runtime.eq` in case order as gencs's do.
Local functions and lambdas become gencs's closure classes (`<Class>_<field>_<line>__Fun`), method
closures are `haxe.lang.Closure`, and function values are called through `haxe.lang.Function`.
`dynamic` methods, `Int64` and `UInt64` arithmetic, `cs.Flags`, `Std`, `Type` and `Reflect` (enums
and classes alike), `haxe.Exception` with its stacks, and `haxe.Serializer`/`haxe.Unserializer`
work. Interface variables and `dynamic` methods of an interface are reached through
`haxe.lang.Runtime`, as gencs reaches them, and an interface method implemented with another return
type gets gencs's explicit implementation. The `@gencs` cases in the tests check that these behave
as gencs's output does, and `@serial` cases that serialized data round-trips between the two.

Generic classes are instantiated as gencs makes them. A type argument that is not a basic type (`Int`,
`Float`, `Bool`, `String`, `Int64` and the like) is erased to `object`, so `Box<Point>` is
``Box`1<object>``, and each generic Haxe class and interface gets gencs's companion interface
(`<pack>.<Class>`, with no arity), which `Std.isOfType` tests and `X<Dynamic>` is typed as: a typed
value passed where an `X<Dynamic>` is expected is the same object. A cast between two instantiations
(`Array<Dynamic>` to `Array<Int>`, `Map<String, Dynamic>` to `Map<String, Int>`) goes through gencs's
`X_cast` and `__hx_cast`, so maps and `List` are copied as gencs copies them, bugs included. `Type`,
`Reflect` and the Serializer see generic classes and their instantiations as gencs's do, so serialized
data with generic classes round-trips between the two. Two hxcs bugs are fixed on purpose. A cast to
a parent instantiation (a class to an `IMap<String, Int>` it implements, `FallbackPromise<T>` to
`Thenable<T>`) gives the right instantiation, where gencs's returns the object itself and the next cast
throws. And Haxe issue 8314 is fixed: casting an `Array<Dynamic>` to an `Array` of a basic type
(`Array<Int>`, `Array<Float>`, …) forwards the original to the typed array instead of copying it, so a
write through either one reaches both; a lossy cast (`1.5` into an `Array<Int>`) still copies.
`docs/superpowers/specs/2026-10-21-dotnet10-il-generator-design.md` lists these and the other recorded
divergences from gencs.

A class's or a generic method's type parameter that holds `Null<Int>`, `Null<Float>` or `Null<Bool>`
(an `Array<Null<Int>>`, a `Box<Null<Int>>`, `Lambda.exists` over an `Array<Null<Int>>`) reaches
`Dynamic`, reflection, string concatenation and the Serializer as gencs's boxed value or `null`. A
generic method's type parameters are bound as gencs binds them, by Haxe's unification of each
argument and the return (first) with the declared types. Where a declared `Null<T>` itself is an
argument or the return (`Lambda.find`'s `Null<T>` return, a `Null<T>` or optional argument, a
callback's return), T is bound to the basic type, so a null `Null<Int>` passed there becomes 0 as
it does under gencs. A `Null<T>` among a callback's arguments (`f:Null<T>->Bool`) keeps T a
`Null<Int>`, and so does one inside a type argument (`Array<Null<T>>`, `Option<Null<T>>`) met by a
`Null<Null<Int>>`. A local generic function's arguments bind the other way round, as gencs's closure
classes do.

Constructs not supported yet are compile errors in user code (`dotnet: ... not supported yet`). The
list is not complete; among others it has compound assignments to `Dynamic` array elements
(`d[i] += v`, `d[i]++`; a plain `d[i] = v` works), `return`, `break` and `continue` inside
expressions, casts between instantiations of a generic class that has no companion interface (a
generic `@:struct`) and `Std.isOfType` or enum constructor arguments with one,
inline C# (`untyped __cs__`, `cs.Syntax.code`, `@:classCode`, `@:functionCode`), `new IntPtr(n)` and
methods called on an `IntPtr` property's value, a static `@:property` var with get or set accessors,
a .NET method, an overloaded method, a struct's method or a method reached through a `Dynamic`
receiver as a delegate, and a .NET base class's non-virtual method or property implementing an
interface method or property for a Haxe subclass (C# adds a forwarding stub there; a public virtual
one works). Some interop is not written yet, with no error: attributes (`@:meta`, `@:strict`), events
defined in Haxe (an `@:event` var's `add_` and `remove_` methods are compiled, but no event), and
nullability metadata, so .NET reflection sees no attribute and no event. The next steps for the .NET
generator bring these.
`Array` has no `object this[int]` indexer yet (hxcs adds it with `@:classCode`), so C# code cannot index
an `Array` and `get_Item`/`set_Item` are missing from `Type.getInstanceFields(Array)`.
Embedded resources (`-resource` or `Context.addResource`) are not supported yet: with `-D dotnet` they
are a compile error, since `haxe.Resource` would find nothing.
Standard-library code that needs a construct not supported yet compiles to a stub: `cs.Pointer.add`
(the `+` operator on pointers) is the one left, and `haxe.ds.EnumValueMap` is left out of the build.

hxc ships its own copy of the hxcs runtime classes that generated code depends on
(`haxe.lang.HxObject`, `haxe.lang.DynamicObject`, `haxe.lang.FieldLookup`, `haxe.lang.Runtime`,
`haxe.lang.Null` and related). Messages name their source as `<hxc-dotnet-runtime>/`. They are used
in place of hxcs's versions, so a class path entry cannot override them.

The rest of the standard library comes from hxcs's runtime sources and is partly stubbed; a stubbed
method throws `System.NotSupportedException` when called. `-D dotnet-stub-report` prints what was
skipped, stubbed or ignored, one sorted line each; for a program that prints, maps an array and
throws and catches a `haxe.Exception` it prints nothing. A catch-all such as `catch (e:Dynamic)` or
`catch (e:cs.system.Exception)` catches a stub's exception too, so it can hide a stub.

The tests need the .NET 10 SDK and hxcs installed globally. They build `tests/fixtures/hxccheck`, compile each case twice to
check the output is deterministic, verify it with ILVerify, and run it:

```bash
tests/dotnet/run.sh --compiler path/to/hxc [--std path/to/haxe/std] [--case name] [--haxe path/to/haxe] [-j jobs] [--no-gencs-cache]
```

Cases run 8 at a time (`-j` or `HXC_TEST_JOBS` changes that; `-j 1` runs them one by one, in order), and their
reports print in case order. Cases tagged `@stress-…` or `@run-timeout`, whose results depend on timing, run alone after
the rest.

Cases tagged `@gencs` are also compiled with Haxe 4.3.7's own `--cs` generator (`-D no-compilation`), the C# is built
for net10.0, and its output must match the hxc build's. That needs Haxe 4.3.7 (`haxe`, or `--haxe`) with hxcs on the
haxelib path, and a case directory path without spaces, since hxcs fails on them (`HXC_TEST_TMP` sets the directory).
Cases tagged `@serial` are `@gencs` cases that also round-trip `haxe.Serializer` data between the two builds: the
program writes `name<TAB>serialized` lines with `gen <file>` and reads them back with `rt <in> <file>`, and hxc's build
reading gencs's data, gencs's build reading hxc's data and hxc's build reading its own data must all print what gencs's
build prints when it reads its own. `serial-corpus` covers the Serializer's encodings and hxcs's quirks this way.
gencs's results (and, for `@serial` cases, its build and data) are cached in `tests/dotnet/tmp/gencs-cache` (under
`HXC_TEST_TMP`), keyed by the case, `gencs.csproj.in`, the script's gencs steps, Haxe, its std, the global hxcs, the .NET
SDK and the time zone, so only changed cases go through gencs again; `--no-gencs-cache` skips the cache.
Each run of a test program stops after 120 seconds (`HXC_RUN_TIMEOUT` changes the limit, and a case's
`@run-timeout=<seconds>` tag changes it for that case), which fails its case.

## Building from source

Requirements:

- [Haxe](https://haxe.org) 4.3, which includes Neko
- hxcpp from [openfl/libhxcpp](https://github.com/openfl/libhxcpp), branch `main`
- [Aedifex](https://github.com/DimensionscapeOrg/aedifex) 1.0.0-rc.3 or later
- A 64-bit C++ toolchain: MSVC on Windows, GCC or Clang on Linux, the Xcode command-line tools on macOS

```bash
haxelib git hxcpp https://github.com/openfl/libhxcpp.git main
cd "$(haxelib libpath hxcpp)/tools/hxcpp" && haxe compile.hxml && cd -
haxelib install aedifex 1.0.0-rc.3
git clone --recursive https://github.com/dimensionscape/hxc.git
cd hxc
haxelib run aedifex build cpp .
```

The second line builds hxcpp's command-line tool, which a git checkout of hxcpp does not include.

The compiler lands in `bin/cpp/<platform>/<arch>/release/bin/`. hxc builds with the `haxe` on your
`PATH`; to build hxc with hxc, set `AEDIFEX_HAXE` to an hxc binary.

hxc needs the hxcpp fork: the hxcpp release on haxelib predates files hxc's build uses, and later
hxcpp releases have a garbage collector regression that large hxc compiles run into.

## hxia

hxia is a sandboxed runtime for loading Haxe modules into a shipped application, for modding,
plugins and live content. A module is compiled once to a cppia artifact and can then be loaded by
both the native and the web build of the same program.

The sandbox starts at compile time. A module is compiled against a profile, and anything outside
it is rejected before the artifact exists:

```bash
hxc -p mods -m Greeter --cppia greeter.cppia --hxia core
```

```
mods/Sneaky.hx:1: characters 59-69 : hxia: 'sys.io.File.getContent' requires capability 'fs.read'
under profile 'core' (grant it with --require fs.read)
```

At run time the host decides what a module can see and how much it may spend:

```haxe
var host = hxia.Host.build()
	.profile(Core)
	.exposeStd()
	.expose(GameApi)
	.build();

var runtime = new hxia.Runtime(host, {fuelPerCall: 100000, maxCallDepth: 256});
var mod = runtime.loadFile("mods/greeter.cppia");
mod.boot();

var greeter = mod.make("Greeter", []);
trace(mod.call(greeter, "greet", ["world"]));
```

Every module loads into its own namespace, so two modules can define the same class without
colliding, and a reload is simply a fresh load. Capabilities are scoped (`FsRead(prefix)`,
`NetClient(hostPattern)` and so on), artifacts can be pinned by hash, and calls are metered for
fuel, call depth and allocation.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/hxc/ast`, `parser` | Syntax tree, lexer, parser, preprocessor, reification |
| `src/hxc/core`, `typing` | Type model, unification and the typer |
| `src/hxc/context` | Compilation context, module loading, server cache, display |
| `src/hxc/eval` | The macro interpreter and its native bindings (libuv, mbedTLS, PCRE2) |
| `src/hxc/filters`, `optimization` | Post-typing filters, DCE, inlining, the analyzer |
| `src/hxc/generators`, `codegen` | JavaScript, C++ and cppia generators; XML and JSON output |
| `src/hxc/compiler` | Command line, messages, display output |
| `src/hxia` | The hxia runtime, linker, host API and `hxia` command-line tool |
| `thirdparty/libuv` | libuv, as a git submodule |

## Reporting bugs

A difference from Haxe 4.3.7 on a supported target is a bug. Please open an issue with the `.hxml`
or command line, the source, and the output of both compilers.

## License

hxc is licensed under the [Mozilla Public License 2.0](LICENSE). libuv, under `thirdparty/libuv`,
keeps its own license.

Haxe is a project of the Haxe Foundation. hxc is an independent project and is not affiliated with it.

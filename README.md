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
| `--cs <dir> -D dotnet` | Writes `<name>.dll` (plus `<name>.runtimeconfig.json` with `-main`) for .NET 10 or later, straight to IL with no C# step (needs hxcs, like `--cs` above). Early: classes (with reflection), interfaces, structs, generics, statics, strings, arrays, `Dynamic`, anonymous objects, `Null<T>`, enums, closures, `dynamic` methods, `Int64`, `Std`/`Type`/`Reflect`, the Serializer and exceptions work; see [.NET output](#net-output) |
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

The Serializer still differs from gencs where a generic class is involved, because hxc does not yet
erase type arguments as gencs does: `Type.resolveClass` cannot find a generic class by name, so
`Array` as a value (`Ay5:Array`) and instances of a generic class such as `Box<T>` cannot be read
back, and a value whose instantiation is not the one the Serializer's code names (a
`Map<String, Int>` to write, or an `Array<Null<Int>>` field to read into) fails to convert. A
class's or a generic method's type parameter that holds `Null<Int>`, `Null<Float>` or `Null<Bool>`
(an `Array<Null<Int>>`, a `Box<Null<Int>>`, `Lambda.exists` over an `Array<Null<Int>>`) reaches
`Dynamic`, reflection, string concatenation and the Serializer as gencs's boxed value or `null`. A
generic method's type parameter met first inside a declared `Null<T>` (a `Null<T>` return such as
`Lambda.find`'s, which binds before the arguments, or an earlier `Null<T>` or optional argument) is
bound to the basic type instead, as gencs binds it, so a null `Null<Int>` passed there becomes 0 as
it does under gencs; with an `Array<Null<Int>>` argument that needs a cast between instantiations,
which is not supported yet.

Constructs not supported yet are compile errors in user code (`dotnet: ... not supported yet`). The
list is not complete; among others it has assignments to `Dynamic` array elements, `return`, `break`
and `continue` inside expressions, casts between instantiations of a generic class (such as
`Array<Dynamic>` to `Array<Int>`), `Std.isOfType` with a generic class, inline C# (`untyped __cs__`,
`@:classCode`, `@:functionCode`), enum constructor arguments whose type is a generic class
instantiated with the enum's own type parameter (`L(a:Array<T>)`; `C(a:T)` works), and .NET interop
beyond calling referenced assemblies (properties of .NET interfaces, generic .NET methods,
`Nullable<T>`). `haxe.ds.EnumValueMap`, and so a `Map` with enum keys, throws
`System.NotSupportedException` when it compares two keys of a constructor with arguments, since its
`compareArg` needs `Std.isOfType(v, Array)`. The next steps for the .NET generator are the
generic-instantiation casts and the `Array` forwarding fix (Haxe issue 8314), then .NET interop.
Until then, standard-library code that needs them compiles to stubs.

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
tests/dotnet/run.sh --compiler path/to/hxc [--std path/to/haxe/std] [--case name] [--haxe path/to/haxe]
```

Cases tagged `@gencs` are also compiled with Haxe 4.3.7's own `--cs` generator (`-D no-compilation`), the C# is built
for net10.0, and its output must match the hxc build's. That needs Haxe 4.3.7 (`haxe`, or `--haxe`) with hxcs on the
haxelib path, and a case directory path without spaces, since hxcs fails on them (`HXC_TEST_TMP` sets the directory).
Cases tagged `@serial` are `@gencs` cases that also round-trip `haxe.Serializer` data between the two builds: the
program writes `name<TAB>serialized` lines with `gen <file>` and reads them back with `rt <in> <file>`, and hxc's build
reading gencs's data, gencs's build reading hxc's data and hxc's build reading its own data must all print what gencs's
build prints when it reads its own. `serial-corpus` covers the Serializer's encodings and hxcs's quirks this way.
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

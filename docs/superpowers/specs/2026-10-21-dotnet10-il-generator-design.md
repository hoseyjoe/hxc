# .NET 10 IL generator: design

Date: 2026-10-21
Status: ready for review by the person driving this

## Intent

hxc accepts `--cs` today and writes nothing. This adds a backend that compiles Haxe straight to a
.NET 10 assembly (IL + metadata in a PE file) with a Portable PDB beside it. It replaces Haxe 4.3.7's
gencs + hxcs pipeline, which writes C# source that `dotnet build` then compiles.

The first and driving user is **the server app** (`<server-app>`). Its server
business logic is Haxe (`cs.HaxeRecordServer`, about 567 generated C# files, ~486k lines today) and
is consumed by an ASP.NET Core 10 host (`cs/Server`) through the `cs/HaxeServer` project.

### Why

The server app's current pipeline only works because of workarounds for gencs/hxcs limits. A recon of the
project (read-only) found:

- **Text patches after every build**, in `haxe/src-yml/Builder.hx` (lines ~238-252):
  - deleting `haxe/lang/BoxedPointer.cs` and `cs/Pointer.cs` (unsafe leftovers that aren't used);
  - rewriting an invalid generic cast in `thx/Options.cs`:
    `return ((global::Array<T>) (new global::Array<object>(new object[]{})) );`;
  - injecting `#nullable enable` into every `ai.tools` namespace file so Semantic Kernel describes
    `string` parameters as non-null in the AI tool JSON schemas (see the comment above
    `Search_Filter` in `haxe/src-ai/ai/tools/ReportSearch.hx`).
- **A runtime override**: `haxe/src/cs/internal/FieldLookup.hx` replaces hxcs's global field table,
  which was not thread-safe under concurrent reads and writes (server app issue #6551).
- **Inline C#** (`untyped __cs__`, ~25 uses but only 4 patterns): rethrow keeping the stack trace
  (~20), a multi-dimensional indexer `cells[row, col]` on EPPlus (2), a decimal literal
  `(decimal){0}` (1), a `#pragma warning disable` through `@:classCode` (1).

The person driving this asked whether IL would be faster and easier to debug. The conclusions they
accepted:

- Runtime speed comes from how Haxe concepts are represented (generics, `Dynamic`, enums,
  closures), not from C# vs IL. RyuJIT optimizes either way.
- Builds get faster: hxc writes the DLL itself, so there's no `dotnet build` of generated sources.
- Debugging gets better for users, as long as a Portable PDB maps IL to `.hx` lines.
- No hand-editing of generated C# happens today (the server app's CLAUDE.md forbids it), so losing
  editable C# output costs nothing.

**Decided: IL + Portable PDB. No C# source output.**

## Success

The acceptance test belongs to the person driving this, in their words: *migrate a test database to
new generated code without issue.*

The server app stores records in MySQL as Haxe-serialized strings. On load, the server upgrades old records
and re-saves them in the current shape. Success means:

1. A server app built with the new generator opens an existing test database, runs its normal
   upgrade path, and every record loads, migrates and saves with nothing lost or silently changed.
2. **Two-way compatibility (hard requirement):** data written by the new server must be readable by
   today's gencs-built server, and the reverse. Rollback and side-by-side running must work without
   converting data.

The suggested proof is a differential run: the same migration on two copies of the test DB, one per
build, then diff the results. Any difference is a bug in the new generator until shown otherwise.

**Acceptance environment:** a test database copy, MySQL, and the ability to run both the server app builds
will be available to the builder *eventually*, not from the start. Until then the plan needs a
stand-in that milestone 3 can test against: a corpus of serialized values covering every type and
encoding the Compatibility section lists, round-tripped through both runtimes in both directions.
Once the real environment arrives, records pulled from the test database join the corpus, and
milestone 6 runs the real migration.

**One source tree** (preferred): after the switch, the server app's source should still build with Haxe
4.3.7 gencs, so rollback and the differential run use the same code. Anything dotnet-only in the server app
goes behind `#if dotnet`. The inline-C# subset below exists partly so the server app's existing `__cs__` uses
need no change at all. "Today's gencs-built server" for the two-way test means the same server app
commit built with Haxe 4.3.7.

## Goals

- `HaxeServer.dll` + `HaxeServer.pdb` produced directly by hxc and referenced by `cs/Server` in place
  of the `HaxeServer.csproj` compile.
- Runtime behavior that matches hxcs wherever data or the C# side can observe it (see
  Compatibility).
- Native .NET interop at least as good as gencs: `--net-lib`/`--net-std` assemblies, `@:nativeGen`,
  `@:strict(...)` attributes, `@:property`, `@:native`, delegates, events, overloads, real generics.
- Debugging in the user's `.hx` files: breakpoints, stepping, locals by their Haxe names, and `.hx`
  file:line in exception stack traces when the PDB is deployed.
- Every one of the server app's Builder.hx patches becomes unnecessary.
- The FieldLookup thread-safety fix carries over (or the new runtime is thread-safe by design).

## Non-goals

- Byte-identical output with Haxe 4.3.7's gencs (C# source). This target is new; hxc's "identical
  output" promise does not apply to it.
- C# source output, in any mode.
- .NET Framework or Mono. Only .NET 10 (`net10.0`) is targeted.
- Edit and Continue / Hot Reload.
- NativeAOT-specific work (emitted IL should not rule it out, but nobody tests for it).
- Changes to the server app's JS client or Electron builds.
- A performance target. There is no compile-time or runtime budget versus today's pipeline, so no
  benchmark gates any milestone. Fixing an obvious, large regression found along the way is still
  in scope.

## Anti-goals

- Any change in serialized data, class/enum names written into data, or reflection results that
  breaks the two-way compatibility above, even if the new behavior is "more correct".
- A generator that needs post-build text patching to produce a working assembly.
- Silent miscompiles: invalid IL must be caught at build/test time, not by a customer.

## Constraints

- **hxc is written in Haxe and runs as a native binary** (hxcpp). The PE, metadata, IL and PDB writers
  and the assembly reader must be Haxe code inside hxc. `System.Reflection.Metadata` is not available.
- **Follow the JVM backend's shape** (`src/hxc/codegen/jvm/`, ~7k lines). It solves the matching
  problems: constant pool ≈ metadata tables/heaps, signatures ≈ blob signatures, `.class` writer ≈
  PE writer, `--java-lib` reader (`src/hxc/codegen/java/`) ≈ `--net-lib` reader. .NET has no
  StackMapTable; IL needs `maxstack`, consistent stack depth at merge points, and an empty stack when
  entering a `try`.
- **Deterministic output**: same inputs give byte-identical DLL and PDB (hxc has a determinism test
  family under `tests/cases/determinism`). Use a content-derived MVID and PDB id.
- **Match the surrounding code**: hxc's naming, comment density and idiom.
- **Reference assemblies**: the server app compiles against `haxe/res/netcore-dlls/` (5 project DLLs plus
  `net-40/` with 63 framework and package DLLs: `System.Runtime.dll`, `mscorlib.dll`, NHibernate,
  Semantic Kernel, Microsoft.Extensions.AI, EPPlus.Core, …). The reader must handle type forwarding
  between them (`mscorlib`/`netstandard` → `System.Runtime` → `System.Private.CoreLib`).
- **Reference drift is now a runtime risk.** That folder has drifted from what `cs/Server` ships:
  Semantic Kernel 1.72 vs 1.81 deployed, NHibernate 5.2 vs 5.7, and a .NET 5-era `System.Runtime.dll`.
  gencs output was recompiled by `dotnet build` against the real packages, which absorbed the drift.
  IL member references are fixed when hxc writes them, so a member that changed between versions
  becomes a `MissingMethodException` at runtime. *(My call:)* hxc compiles against whatever
  `--net-lib`/`--net-std` name, the same as today. The acceptance setup adds an ILVerify run of
  `HaxeServer.dll` with the **deployed** assemblies as references, which reports any member
  reference that doesn't resolve. The server app refreshes `res/netcore-dlls/` from its build outputs, which
  its own CLAUDE.md already asks for whenever the C# projects change.

## Compatibility (what must match hxcs)

Two parties can observe the output: stored data (and the JS client, which talks Haxe serialization
to the server), and the hand-written C# in `cs/Server`, `cs/SharedServer`, etc. Whatever either one
can see must behave like Haxe 4.3.7 gencs + hxcs:

- `haxe.Serializer` / `haxe.Unserializer` output and input, byte for byte. This includes class and
  enum names as `Type.getClassName` / `Type.getEnumName` report them, enum constructor names and
  indices, field order where it affects output, and how `Int`, `Float`, `null`, `Date`, `Bytes`,
  `haxe.ds.*Map`, `List` and anonymous structures encode.
- Reflection: `Reflect.field`/`setField`/`fields`, `Type.resolveClass`, `Type.getInstanceFields`,
  `Type.createEmptyInstance`, dynamic field access on class instances and anonymous objects.
- Number and date semantics: 32-bit `Int` overflow, `Float`→`Int` conversion, `Std.parseInt` /
  `parseFloat`, `Date` time zone behavior, string formatting of floats.
- **CLR names the C# side uses**: namespaces, type names, member names, generic arity and the
  runtime entry points it calls today, e.g. `haxe.lang.Runtime.setField(obj, "name", 0, value)` in
  `cs/Server/Controllers/RecordController.cs`, and `Serializer.run` / `Unserializer.run` plus Haxe
  classes such as `ReportingTools` and `CultureManager` in `cs/SharedServer/ServerManager.cs`. A
  repo-wide grep of `cs/` for Haxe-generated names gives the full list; that list is the interop
  surface to keep.
- Core type mapping, as gencs does it (confirm against Haxe 4.3.7's gencs and `std/cs`): `Int`→`int`,
  `Float`→`double`, `Bool`→`bool`, `String`→`string`, `Dynamic`→`object`, `Array<T>` a real generic
  class, `Null<T>` of a value type as `haxe.lang.Null<T>`, enums as classes deriving from the hxcs
  enum base.

Where hxcs behavior is a bug that data depends on, reproduce it. Write each such case down as a known
divergence from "correct" behavior. The one hxcs bug this generator fixes on purpose is Haxe issue
8314 (next section), and the fix is shaped so serialized data doesn't change.

## Casts between generic instantiations (Haxe issue 8314)

**What hxcs does.** gencs gives a Haxe generic class real CLR type arguments (`Array<Float>` is
``Array`1<float64>``, `Array<Dynamic>` is ``Array`1<object>``), so a value's static type and its
object's instantiation can disagree. `haxe.Json.parse` and `haxe.Unserializer` build every array as
`Array<Dynamic>`. When such a value flows into a slot of another instantiation, gencs's
`RealTypeParams` filter calls `__hx_cast`. That returns `this` when the type arguments match;
otherwise it builds a new object and copies every field into it, converting native arrays element
by element with `Runtime.genericCast`. So every read of an anonymous-structure field typed
`Array<Float>` that holds an unserialized array returns a fresh copy, and writes through it are lost
([HaxeFoundation/haxe#8314](https://github.com/HaxeFoundation/haxe/issues/8314), closed in favor of
[#4872](https://github.com/HaxeFoundation/haxe/issues/4872), which the Haxe team said won't be fixed
for C#). Going the other way (an `Array<Int>` passed as `Array<Dynamic>`) copies too, and so does
every generic Haxe class, not only `Array`.

The server app works around it. `haxe/src-shared/models/ClassNameMacro.hx` generates a `scrubArrays` for each
data typedef that reads every top-level array field and writes it back; `DataSource_Json`,
`DataSourceDBCache` and `RecordServer`'s undo/redo call it. Nested arrays, values from
`Unserializer.run`, and arrays passed to `Array<Dynamic>` parameters aren't covered.

**Decided: the generator fixes it for `Array`.** The design is the one Nicolas Cannasse described in
#4872, which HashLink implements (`hl.types.ArrayDyn`): an `Array<Dynamic>` is untyped until its
first cast to a typed instantiation locks it, and from then on every reference shares one storage.

- **Only ``Array`1<object>`` forwards.** hxc's runtime copy of `Array.hx` gets one field: the typed
  array this one stands for. A typed instantiation (``Array`1<int32>``, ``Array`1<string>``, …) never
  forwards.
- **Reinterpret once.** Casting a non-forwarding ``Array`1<object>`` to `Array<X>` converts its
  elements into a new `Array<X>`, installs that as the forward target with a compare-and-swap, and
  returns it. A thread that loses the race returns the winner's array. The old storage stays in
  place, so a reader that raced the swap sees the same values. Later casts of the object to
  `Array<X>` return that same `Array<X>`: `t.val == t.val` holds, and a write through either
  reference shows through the other.
- **A view the other way.** Casting a typed `Array<X>` to `Array<Dynamic>` returns a new
  ``Array`1<object>`` that forwards to it, so a function taking `Array<Dynamic>` changes the
  caller's array.
- **Only lossless conversions.** An element converts when its value survives: an `Int`, or a
  `Float` holding an `Int` value, into `Array<Int>`; any number into `Array<Float>`; a `Bool` into
  `Array<Bool>`; `null` or an instance of `X` into a reference type `X`, and `null` into `Null<T>`;
  an inner array into `Array<Array<…>>` by the same rules, all or nothing over the whole value. If
  any element doesn't, the cast does what `__hx_cast` does: it copies, or throws where
  `genericCast` throws. A stored `1.5` in an `Array<Int>` field, or a `null` in an `Array<Float>`, is
  never rewritten just because code read it, so serialized data stays what hxcs writes.
  (`Type.typeof` reports an `Int`-valued `Float` as `TInt`, so `Serializer` writes `1` and `1.0`
  the same way.)
- **A wrong-typed write converts.** A write through a forwarder or a view lands in the typed
  storage, so it converts as `genericCast` does (`1.5` becomes `1` in an `Array<Int>`) or throws
  where that throws. Under hxcs the same write would have gone into an untyped copy. Only code that
  writes a value of the wrong type through `Dynamic` sees the difference.
- **Everything that reaches storage resolves the forward first**: every `Array` member, including
  `length` and the members hxcs inlines into callers (`map`, `filter`, `__unsafe_get`, …), and the
  dynamic paths in `cs.internal.Runtime`. *(My call:)* `length` becomes a property whose getter
  checks the forward. It keeps its name, so C# in `cs/` that reads it still compiles.
- **Equality sees one array.** `Runtime.eq`, `==` with an `Array<Dynamic>`, `Dynamic` or
  type-parameter operand, and `Equals`/`GetHashCode` overrides on `Array` compare forward targets.
  That keeps `indexOf`/`remove`/`contains` (which use `System.Array.IndexOf`) and `ObjectMap` keys
  consistent.
- **Unchanged from hxcs:** a cast between two typed instantiations (`cast` from `Array<Int>` to
  `Array<Float>`) still copies, and so does a second reinterpretation to a different type. Maps,
  `List` and other generic classes keep `__hx_cast`'s copy. A search of the server app found no map read from
  serialized data whose value type isn't `Any` (already `object`, so nothing converts), and no
  generic class of its own besides `CSTools.IEnumerableIterator`. If one turns up, extend the
  forward to the `haxe.ds` maps.
- **The C# side keeps working.** `Array` stays a real generic class (`cs/SharedServer/Importer.cs`
  builds `new Array<string>()`), and `Unserializer.run` still returns an ``Array`1<object>``
  (`cs/SharedServer/ServerManager.cs` casts it to one).

The differential suite records every case of this as a deliberate divergence from hxcs. The server app's
`scrubArrays` behaves the same under both generators, so it can stay. Writes no longer depend on
it, but it also turns a `null` array into `[]`, so removing it is the server app's call. Milestone 2 rejects
these casts (a compile error in user code). Milestone 3 implements them, with cases for #8314's
example, the `haxe.Json` example from its comments, #4872's `a == b` test, the view direction, the
lossless fallback (data with `1.5` in an `Array<Int>` field re-serializes to the same string), a
wrong-typed write through `Dynamic`, nested arrays, and two threads casting one array at once.

## How it gets made (decided)

- **Output**: one PE32 IL-only, AnyCPU assembly per compile, plus a separate Portable PDB. Library
  output when there's no `-main`, a console app (with a `*.runtimeconfig.json`) when there is.
- **Command line**: `--cs <dir>` together with `-D dotnet` selects this generator, the same way
  `--java <dir> -D jvm` selects the JVM backend. The platform stays `cs`, so `#if cs`, the `cs.*`
  std package and every existing `cs.system.*` / `cs.NativeArray` / `@:nativeGen` use in the server app keep
  working. *(The define's name is my call.)* `--cs` without `-D dotnet` keeps today's behavior.
- **Assembly name**: from the output directory's last segment unless `-D dll-name=<name>` sets it,
  so the server app gets `HaxeServer.dll`. *(My call.)*
- **Runtime**: written in Haxe and compiled by the same generator into the output assembly, as hxcs
  does with `std/cs/internal/*.hx` (~1,800 lines in Haxe 4.3.7, ~100 of them inline C#). hxc ships its
  own copy of that runtime with the inline C# replaced by intrinsics, plus its own `cs/_std/Array.hx`
  for the forwarding in *Casts between generic instantiations*, and folds in the server app's FieldLookup
  fix. *(My call:)* overriding runtime internals through the classpath is not supported.
  The server app wraps its `cs/internal/FieldLookup.hx` override in `#if !dotnet`, keeping it for the gencs
  build, so hxc's runtime is free to change its internal API.
- **Inline C# (`__cs__`, `cs.Syntax.code`, `@:functionCode`, `@:classCode`)** *(my call)*: hxc parses
  a small subset of C# **expressions** and compiles them like Haxe code, resolving names against
  the Haxe scope and the referenced assemblies. Anything outside the subset is a compile error that
  names the replacement. Like gencs, hxc only checks inline code that survives DCE. The subset:
  - `{N}` placeholders, `this`, local and member identifiers, `global::`-qualified and dotted type
    names;
  - member access, method calls, indexers with any number of arguments (`cells[row, col]`);
  - casts to named types (`(decimal){0}`, `(System.Char)ch`), literals;
  - a bare `throw;` statement, which emits IL `rethrow` and keeps the stack trace.

  This covers the server app's 4 patterns unchanged, plus the 5 `__cs__` uses in the `haxe-strings` haxelib
  (`StringBuilder.hx` lines 134/201/278/350, `Strings.hx` line 1366), so no third-party library has to
  be forked. Because the server app agreed to small source changes, these first-class forms are offered too,
  and the server app can move to them over time:
  - **rethrow**: `throw e` inside a `catch`, where `e` is the caught value, emits `rethrow`.
  - **decimal**: a `cs.system.Decimal` from a constant emits a decimal constant.
  - **multi-argument indexers**: callable through array access on the extern.
  - **`#pragma`** in `@:classCode` is ignored, since C# compiler warnings don't exist at the IL
    level. Other `@:classCode`/`@:functionCode` content is an error.
- **Nullability metadata**: for types the AI tool schemas see, emit `NullableAttribute` /
  `NullableContextAttribute` from Haxe types: `String` → non-null, `Null<String>` → nullable. Semantic
  Kernel reads these through `NullabilityInfoContext`. The schemas the server app produces today must come out
  identical; `ai.tools` gets non-null `string`, other namespaces unchanged.
- **Attributes**: `@:strict(...)` and `@:meta(...)` become CustomAttribute rows with properly encoded
  blobs, typed against the referenced assemblies.
- **Resources**: Haxe `-resource` files become manifest resources, named so `haxe.Resource` works.
  A `-D dotnet-embed=<file>@<name>` define (repeatable) embeds a raw file under an exact manifest
  name, so `TutorialTools.hx` keeps finding `coach.bin` / `tutorials.bin` through
  `GetManifestResourceNames()`. *(My call.)*
- **What `HaxeServer.csproj` does besides compiling** *(my call)*: its package references (PDFsharp,
  PuppeteerSharp, PemUtils, System.Text.Json, …) and project references (Database,
  Database_Single, EPPlus) move to `cs/Server`'s project, which references the prebuilt
  `HaxeServer.dll` by `<Reference HintPath>`. hxc writes no `.deps.json` or nuspec; the consuming
  project produces those, as it does today.
- **Debug info**: a Portable PDB with Document rows (`.hx` paths + SHA-256), sequence points per
  expression statement, hidden sequence points for generated code, local scopes and variable names.
  Embedded source and Source Link are optional. The DLL links to it through CodeView and PdbChecksum
  debug-directory entries. `-debug` does not turn off JIT optimization: the server app build always
  passes it, and under gencs the `dotnet publish` configuration decided optimization instead
  (`HaxeServer.csproj` sets no `<Optimize>`, so only `-c Release` was optimized, and several of
  the server app's Docker scripts publish with `-c Debug`). The assembly gets a `DebuggableAttribute` with
  `DisableOptimizations` only under `-D dotnet-debug-jit`, for stepping with every local kept live.
  *(The define's name is my call.)*
- **Verification**: `dotnet-ilverify` (10.x) runs on every generated test assembly. Differential
  tests compare against Haxe 4.3.7 gencs output (built with `dotnet build`) running the same program,
  with stdout and `haxe.Serializer` output diffed.

## Milestones (suggested order; the builder may reorder)

1. **`--net-lib` / `--net-std` reader.** ECMA-335 metadata reading, converted into extern Haxe types
   like Haxe 4.3.7's net-lib loader does (`@:csNative`, `@:libType`, `@:delegate`, `@:event` metas
   already exist in `src/hxc/data/Metas.hx`). **Exit:** hxc type-checks the server app with
   `--no-output` and reports the same diagnostics as Haxe 4.3.7. Useful even before any codegen.
2. **Writers + minimal emitter.** Metadata tables/heaps, PE writer, IL encoder, a small program with
   classes, statics, strings, arrays, exceptions. A cast between instantiations of a generic class
   is a compile error until milestone 3. **Exit:** runs on `dotnet`, ILVerify clean, deterministic.
3. **Runtime parity.** hxc's runtime copy compiled through the generator; `Dynamic`, reflection,
   enums, closures, anonymous objects, `Null<T>`, `Std`/`Type`/`Reflect`, Serializer, and `Array`
   casts that share storage (*Casts between generic instantiations*). **Exit:** the differential
   suite against Haxe 4.3.7 gencs passes, apart from the recorded issue-8314 divergences.
4. **Interop.** `@:nativeGen`, attributes, properties, nullability, delegates/events, overloads,
   generics that cross into referenced assemblies, the inline-C# subset, manifest resources.
   **Exit:** The server app builds to `HaxeServer.dll`, `cs/Server` builds against it, AI tool
   schemas match today's, ILVerify against the deployed assemblies is clean.
5. **Portable PDB.** **Exit:** breakpoints and stepping in `.hx` files in Visual Studio and VS Code
   (built with `-D dotnet-debug-jit`), and `.hx` line numbers in exception stack traces from an
   optimized build.
6. **The server app acceptance.** The two-way test database migration described in Success.

## Left to the builder

- Internal module layout under `src/hxc/codegen/` (e.g. a `dotnet/` folder next to `jvm/`), and how
  much of the JVM backend's lowering is shared or copied.
- IL lowering strategy for Haxe's expression-oriented constructs.
- An IL size pass once milestone 3 compiles the runtime. Milestone 2 always emits long-form
  branches, never fuses a comparison into its branch (`bne.un`, `ble`, …), and lowers `switch` to a
  chain of comparisons. The JIT folds those back, but IL size decides what it inlines (a callee of
  16 bytes or less always is), so measure the server app's method sizes and shorten branches, fuse
  comparisons or emit `switch` tables only where small methods are pushed over. No benchmark gates
  it (see Non-goals).
- How the differential tests plug into hxc's existing harness (`src/hxia/harness`,
  `tests/divergences.json`).
- PDB extras (embedded source, Source Link).
- Which the server app build variants (`Server_Core`, `Server_Reports` in Builder.hx) come after the main
  `Server` build.
- Builder.hx changes in the server app to call the new generator and drop the `HaxeServer.csproj` compile and
  text patches (to be done in the server app's repository, separately).

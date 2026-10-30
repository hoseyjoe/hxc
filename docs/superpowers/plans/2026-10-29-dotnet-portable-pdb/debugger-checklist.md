# Debugger checklist, .NET Portable PDB

Run by hand, in VS Code and then in Visual Studio 2022 or later. Each item says what to open, where to
click and what should appear; write what happened on its `Result:` line (what appeared, or what went
wrong, with the exact text of any message).

## Setup

1. Build the sample: in `D:/_github/hxc/tests/dotnet/debugger`, run `hxc build.hxml` (with
   `HAXE_STD_PATH=C:/HaxeToolkit/haxe/std` set). `out/out.dll` and `out/out.pdb` appear.
2. `dotnet out/out.dll` prints five lines, each naming `src/sample/Main.hx` and a line number:
   `total 28`, `inner 56`, `closure 15`, `caught side too large: 3`, `field 42`.
3. The PDB names files by short paths (`src/sample/Main.hx`, `src/sample/Shapes.hx`, `haxe-std/...`,
   `hxc-runtime/...`), so each debugger has to be told where those folders are (below).

The lines used below (1-based):

| File | Line | Code |
| --- | --- | --- |
| `src/sample/Main.hx` | 7 | `var count = 3;` (the loop is not unrolled, because its bound is a variable) |
| `src/sample/Main.hx` | 8 | `for (i in 0...count) {` |
| `src/sample/Main.hx` | 9 | `var side = i + 1;` |
| `src/sample/Main.hx` | 10 | `total += shapes.area(side);` |
| `src/sample/Main.hx` | 12 | `trace("total " + total);` (after the loop) |
| `src/sample/Main.hx` | 14 | `var inner = total * 2;` (inside the inner block) |
| `src/sample/Main.hx` | 15 | `trace("inner " + inner);` |
| `src/sample/Main.hx` | 19 | `trace("closure " + add(5));` |
| `src/sample/Main.hx` | 21 | `shapes.fail(3);` (inside the `try`) |
| `src/sample/Main.hx` | 25 | `trace("field " + Reflect.field(...));` |
| `src/sample/Shapes.hx` | 11 | `var squared = side * side;` |
| `src/sample/Shapes.hx` | 12 | `var result = squared * scale;` |
| `src/sample/Shapes.hx` | 18 | `throw "side too large: " + side;` |

## VS Code

Prerequisite: the C# extension (or C# Dev Kit), which provides the `coreclr` debugger.

Open the folder `D:/_github/hxc/tests/dotnet/debugger` (File > Open Folder). Its
`.vscode/launch.json` launches `out/out.dll` with `"justMyCode": false`, looks for the PDB in `out/`, and
maps `src/` and `haxe-std/` to real folders with `sourceFileMap`. (`haxelib/<library>/` can be mapped the
same way; the sample uses no library.)

1. **Breakpoint binding, before the program starts.** (This result decides whether a later task adds a
   full-path fallback under `-D dotnet-debug-jit`, so write down exactly what you see.) Open
   `src/sample/Shapes.hx`, click in the gutter left of line 11 to set a breakpoint, then press F5
   (start "Debug the sample (.NET)"). Before the program runs, the breakpoint is a solid red dot, not a
   hollow grey one, and execution stops on line 11 with the line highlighted.
   Result:
2. **Step over.** Press F10. The highlight moves to line 12.
   Result:
3. **Step out.** Press Shift+F11. Execution returns to `src/sample/Main.hx`, at line 10 (the call site) or
   the line after it, and the Call Stack shows `sample.Main.main` at a `.hx` line.
   Result:
4. **Step into the other file.** Remove the breakpoint in `Shapes.hx`, set one on `src/sample/Main.hx`
   line 10 and restart (Ctrl+Shift+F5). When it stops on line 10, press F11. Execution enters
   `src/sample/Shapes.hx` at line 11, and that file is the one shown.
   Result:
5. **Stepping stops at the loop's line on every iteration.** With the breakpoint on `src/sample/Main.hx`
   line 10, continue to it, then press F10 repeatedly through the end of the loop body. Does stepping stop
   on line 8 (`for`) each time the loop comes round, then on line 9 and line 10 again? Check all three
   iterations (the Variables pane shows `i` as 0, 1, 2). Write down any iteration where line 8 is skipped.
   After the third iteration, stepping goes on to line 12.
   Result:
6. **Locals in the inner block.** Set a breakpoint on `src/sample/Main.hx` line 15 and continue (F5) to it.
   The Variables pane, under Locals, lists `inner` (56), `shapes` and `total` by their Haxe names. Step
   (F10) to line 19, which is after the block: `inner` is no longer listed.
   Result:
7. **A Watch of a local in C# syntax.** While stopped on line 15, add `total + 1` to the Watch pane. It
   shows 29, with no error.
   Result:
8. **A Watch in Haxe-only syntax.** Add each of `[total, 1]` (an array literal, Haxe-only),
   `cast(total, Int)` and `if (total > 0) 1 else 2` to the Watch pane. Note which show a value and which
   show an error, with the error text.
   Result:
9. **Stepping into `Reflect.field` shows hxc's runtime source.** Set a breakpoint on `src/sample/Main.hx`
   line 25 and continue to it. Press F11 until execution is inside `Reflect.field`. A source file opens:
   either `haxe-std/Reflect.hx` (found through `sourceFileMap`) or a tab named `hxc-runtime/...` holding
   hxc's embedded text. Write down the name, which of the two it is, and whether stepping goes on line by
   line in it. If a "source not available" page opens instead, copy its text.
   Result:
10. **An exception's Call Stack.** Remove other breakpoints, and in the Breakpoints pane tick "Uncaught
    Exceptions" and "All Exceptions" (or set a breakpoint on `src/sample/Shapes.hx` line 18). Restart, and
    continue until execution stops at the `throw`. The Call Stack lists `sample.Shapes.fail` at
    `src/sample/Shapes.hx:18` and `sample.Main.main` at `src/sample/Main.hx:21`: `.hx` files and lines.
    Result:

## Visual Studio 2022 or later

Prerequisite: a Visual Studio with the ".NET desktop development" workload.

Visual Studio cannot open a DLL as a project, so start it through a console project: create any C#
Console project, open its Properties > Debug > Launch Profiles, and add an "Executable" profile whose
executable is `dotnet` and whose arguments are `D:/_github/hxc/tests/dotnet/debugger/out/out.dll`; select
that profile. (The project's own program does not run.) Then set up symbols and sources:

- Tools > Options > Debugging > Symbols: add the folder `D:/_github/hxc/tests/dotnet/debugger/out`.
- Tools > Options > Debugging > General: untick "Enable Just My Code".
- Solution Explorer: right-click the solution > Properties > Common Properties > Debug Source Files, and
  add `D:/_github/hxc/tests/dotnet/debugger/` (the folder that contains `src/`) and
  `C:/HaxeToolkit/haxe/` (the folder that contains `std/`, for the `haxe-std/` names).

Write in item 1's Result how you started the program, and which of these settings you had to use.

1. **Breakpoint binding, before the program starts.** (This result decides whether a later task adds a
   full-path fallback under `-D dotnet-debug-jit`, so write down exactly what you see.) With the settings
   above, open `src/sample/Shapes.hx` (File > Open > File) and click the margin left of line 11. The
   breakpoint is a solid red circle, not a hollow one with the warning "The breakpoint will not currently
   be hit". Press F5. Execution stops on line 11. If the breakpoint does not bind, try "Find source"
   instead: run until something stops inside `sample.Shapes.area` (for example Debug > Break All), double-click
   that Call Stack frame, choose "Find source" and select `src/sample/Shapes.hx`; say whether a breakpoint
   on line 11 then binds on a restart.
   Result:
2. **Step over.** Press F10. The yellow arrow moves to line 12.
   Result:
3. **Step out.** Press Shift+F11. Execution returns to `src/sample/Main.hx`, at line 10 or the line after it.
   Result:
4. **Step into the other file.** Remove the breakpoint in `Shapes.hx`, set one on `src/sample/Main.hx`
   line 10 and restart. When it stops on line 10, press F11. The yellow arrow goes to
   `src/sample/Shapes.hx` line 11, and that file is shown.
   Result:
5. **Stepping stops at the loop's line on every iteration.** With the breakpoint on `src/sample/Main.hx`
   line 10, continue to it, then press F10 repeatedly through the end of the loop body. Does stepping stop
   on line 8 (`for`) each time the loop comes round, then on line 9 and line 10 again? Check all three
   iterations. Write down any iteration where line 8 is skipped. After the third iteration, stepping goes
   on to line 12.
   Result:
6. **Locals in the inner block.** Break on `src/sample/Main.hx` line 15; open Debug > Windows > Locals.
   `inner` (56) is listed by that name, with `shapes` and `total`. Step (F10) to line 19: `inner` is gone.
   Result:
7. **A Watch of a local in C# syntax.** In Debug > Windows > Watch > Watch 1 add `total + 1`. It shows 29,
   with no error.
   Result:
8. **A Watch in Haxe-only syntax.** Add each of `[total, 1]`, `cast(total, Int)` and
   `if (total > 0) 1 else 2` to Watch 1. Note which show a value and which show an error, with the error
   text. (The Document language is C#'s, so C# syntax is expected to work and Haxe-only syntax not to.)
   Result:
9. **Stepping into `Reflect.field` shows hxc's runtime source.** Break on `src/sample/Main.hx` line 25 and
   press F11 until execution is inside `Reflect.field`. A document opens: `haxe-std/Reflect.hx`, or
   `hxc-runtime/...` holding hxc's embedded text. Write down the name, which of the two it is, and whether
   stepping goes on line by line in it.
   Result:
10. **An exception's Call Stack.** Remove other breakpoints; in Debug > Windows > Exception Settings tick
    "Common Language Runtime Exceptions" (or break on `src/sample/Shapes.hx` line 18). Start debugging.
    When execution stops at the throw, the Call Stack window lists `sample.Shapes.fail` at
    `src/sample/Shapes.hx` line 18 and `sample.Main.main` at `src/sample/Main.hx` line 21.
    Result:

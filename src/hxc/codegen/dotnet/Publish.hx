package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.ast.Position;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.context.Context;

// -D dotnet-aot and -D dotnet-r2r: after the assembly is written and the after-generate callbacks have run,
// publishes it with the .NET SDK. The project has no C# of its own: the written assembly stands in for the
// compiler's output. -D dotnet-aot leaves a native program beside the assembly, which starts at hxc's entry
// point, with its arguments and its STAThread. -D dotnet-r2r puts the assembly back in place with ReadyToRun code
// beside its IL, so it runs and is referenced as before.
class Publish {
	public static function check(ctx:Context, g:DotnetCtx, isDll:Bool):Void {
		if (ctx.defines.rawDefined("dotnet_r2r")) {
			if (ctx.defines.rawDefined("dotnet_aot"))
				g.error("-D dotnet-r2r and -D dotnet-aot can't be used together: a native program has no use for an assembly's ReadyToRun code", Position.nullPos);
			if (ctx.defines.rawDefined("dotnet_debug_jit"))
				g.error("-D dotnet-r2r and -D dotnet-debug-jit can't be used together: the precompiled code is optimized, which -D dotnet-debug-jit asks the JIT not to do", Position.nullPos);
		}
		if (!ctx.defines.rawDefined("dotnet_aot")) return;
		if (isDll) g.error("-D dotnet-aot needs -main: a library has no entry point to start a native program at", Position.nullPos);
		var descriptor = descriptorOf(ctx);
		if (descriptor != null && !FileSystem.exists(descriptor))
			g.error("-D dotnet-aot-descriptor: " + descriptor + " was not found", Position.nullPos);
	}

	static function descriptorOf(ctx:Context):Null<String> {
		return ctx.defines.rawDefined("dotnet_aot_descriptor") ? ctx.defines.rawDefinedValueSafe("dotnet_aot_descriptor") : null;
	}

	public static function wanted(ctx:Context):Bool {
		return ctx.defines.rawDefined("dotnet_aot") || ctx.defines.rawDefined("dotnet_r2r");
	}

	public static function publish(ctx:Context):Void {
		var aot = ctx.defines.rawDefined("dotnet_aot");
		var define = aot ? "-D dotnet-aot" : "-D dotnet-r2r";
		var kind = aot ? "aot" : "r2r";
		var dir = GenerateDotnet.outputDir(ctx);
		var project = FileSystem.fullPath(dir + "/" + kind);
		FileSystem.createDirectory(project);
		var name = GenerateDotnet.assemblyName(ctx, dir), version = NetSetup.dotnetVersion(ctx);
		var file = project + "/" + kind + ".csproj";
		sys.io.File.saveContent(file, aot ? aotProject(ctx, name, version) : r2rProject(ctx, name, version));
		var log = project + "/publish.log";
		var result = run(["publish", file, "-c", "Release", "-nologo", "-v:q", "-nodeReuse:false"]);
		if (result == null) {
			ctx.addDiagnostic("dotnet: " + define + " needs the .NET SDK, and `dotnet` could not be started", Position.nullPos);
			return;
		}
		sys.io.File.saveContent(log, result.output);
		if (result.code != 0)
			ctx.addDiagnostic("dotnet: " + define + ": the publish failed (the whole report is in " + log + ")\n" + errorLines(result.output), Position.nullPos);
	}

	// The assembly is rooted, as the runtime's reflection reaches its members by name, which the compiler can't see.
	static function aotProject(ctx:Context, name:String, version:Int):String {
		var items = ['    <TrimmerRootAssembly Include="' + escape(name) + '" />'];
		var descriptor = descriptorOf(ctx);
		if (descriptor != null) items.push('    <TrimmerRootDescriptor Include="' + escape(FileSystem.fullPath(descriptor)) + '" />');
		var program = name + (Sys.systemName() == "Windows" ? ".exe" : "");
		return projectFile(ctx, name, version, ['    <OutputType>Exe</OutputType>', '    <PublishAot>true</PublishAot>'], items, program);
	}

	// Framework-dependent, for the machine's own OS and CPU: elsewhere the runtime ignores the ReadyToRun code and
	// runs the IL. hxc writes the runtimeconfig, so the publish writes none, nor a deps file.
	static function r2rProject(ctx:Context, name:String, version:Int):String {
		return projectFile(ctx, name, version, [
			"    <RuntimeIdentifier>$(NETCoreSdkPortableRuntimeIdentifier)</RuntimeIdentifier>",
			'    <SelfContained>false</SelfContained>',
			'    <PublishReadyToRun>true</PublishReadyToRun>',
			'    <GenerateDependencyFile>false</GenerateDependencyFile>',
			'    <GenerateRuntimeConfigurationFiles>false</GenerateRuntimeConfigurationFiles>'
		], [], name + ".dll");
	}

	// Joined with "\n" so the file is the same whatever line endings this source was checked out with. The
	// --net-lib assemblies are references; `published` is copied from the publish back to the output directory.
	static function projectFile(ctx:Context, name:String, version:Int, properties:Array<String>, items:Array<String>, published:String):String {
		items = items.copy();
		for (lib in ctx.netLibs) {
			if (lib.isStd) continue;
			var file = FileSystem.fullPath(lib.filePath);
			var simple = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
			items.push('    <Reference Include="' + escape(simple) + '"><HintPath>' + escape(file) + '</HintPath></Reference>');
		}
		var lines = ['<Project>', '  <Import Project="Sdk.props" Sdk="Microsoft.NET.Sdk" />', '  <PropertyGroup>'].concat(properties).concat([
			'    <TargetFramework>net' + version + '.0</TargetFramework>',
			'    <AssemblyName>' + escape(name) + '</AssemblyName>',
			'    <PublishDir>publish/</PublishDir>',
			'    <ProduceReferenceAssembly>false</ProduceReferenceAssembly>',
			'    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>',
			'    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>',
			'    <SatelliteResourceLanguages>en</SatelliteResourceLanguages>',
			'  </PropertyGroup>'
		]);
		if (items.length > 0) lines = lines.concat(['  <ItemGroup>', items.join("\n"), '  </ItemGroup>']);
		return lines.concat([
			'  <Import Project="Sdk.targets" Sdk="Microsoft.NET.Sdk" />',
			'  <Target Name="CoreCompile">',
			'    <Copy SourceFiles="../' + escape(name) + '.dll" DestinationFiles="@(IntermediateAssembly)" />',
			'  </Target>',
			'  <Target Name="CopyPublished" AfterTargets="Publish">',
			'    <Copy SourceFiles="publish/' + escape(published) + '" DestinationFolder=".." />',
			'  </Target>',
			'</Project>',
			''
		]).join("\n");
	}

	// A name or path as MSBuild reads it literally, inside an XML attribute or element.
	static function escape(s:String):String {
		for (c in ["%", "$", "@", ";", "?", "*", "'"])
			s = s.split(c).join("%" + StringTools.hex(c.charCodeAt(0), 2));
		return StringTools.htmlEscape(s, true);
	}

	// Runs dotnet to its end, null if it can't start. MSBuild reports on stdout, so stderr is read second. On
	// Windows the SDK's linker lookup calls vswhere by name, and a Visual Studio install leaves it off the PATH.
	static function run(args:Array<String>):Null<{code:Int, output:String}> {
		var path = Sys.getEnv("PATH");
		var programFiles = Sys.getEnv("ProgramFiles(x86)");
		var installer = programFiles == null ? null : programFiles + "\\Microsoft Visual Studio\\Installer";
		var addVsWhere = installer != null && FileSystem.exists(installer);
		if (addVsWhere) Sys.putEnv("PATH", installer + ";" + path);
		var result = try {
			var p = new sys.io.Process("dotnet", args);
			var output = p.stdout.readAll().toString() + p.stderr.readAll().toString();
			var code = p.exitCode();
			p.close();
			{code: code, output: output};
		} catch (_:Dynamic) null;
		if (addVsWhere) Sys.putEnv("PATH", path);
		return result;
	}

	// MSBuild's error lines, each once, or the whole report if it has none.
	static function errorLines(output:String):String {
		var lines = [];
		for (l in output.split("\n")) {
			var line = StringTools.trim(l);
			if (line.indexOf(": error ") >= 0 && lines.indexOf(line) < 0) lines.push(line);
		}
		return lines.length > 0 ? lines.join("\n") : StringTools.trim(output);
	}
}

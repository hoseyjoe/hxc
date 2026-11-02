package hxc.codegen.dotnet;

import sys.FileSystem;
import hxc.ast.Position;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.context.Context;

// -D dotnet-aot: after the assembly is written and the after-generate callbacks have run, publishes it through
// Native AOT with the .NET SDK and leaves the native program beside it. The project in <dir>/aot has no C# of its
// own: the written assembly stands in for the compiler's output, so the program starts at hxc's entry point, with
// its arguments and its STAThread.
class AotPublish {
	public static function check(ctx:Context, g:DotnetCtx, isDll:Bool):Void {
		if (!ctx.defines.rawDefined("dotnet_aot")) return;
		if (isDll) g.error("-D dotnet-aot needs -main: a library has no entry point to start a native program at", Position.nullPos);
		var descriptor = descriptorOf(ctx);
		if (descriptor != null && !FileSystem.exists(descriptor))
			g.error("-D dotnet-aot-descriptor: " + descriptor + " was not found", Position.nullPos);
	}

	static function descriptorOf(ctx:Context):Null<String> {
		return ctx.defines.rawDefined("dotnet_aot_descriptor") ? ctx.defines.rawDefinedValueSafe("dotnet_aot_descriptor") : null;
	}

	public static function publish(ctx:Context):Void {
		var dir = GenerateDotnet.outputDir(ctx);
		var project = FileSystem.fullPath(dir + "/aot");
		FileSystem.createDirectory(project);
		sys.io.File.saveContent(project + "/aot.csproj", projectFile(ctx, GenerateDotnet.assemblyName(ctx, dir), NetSetup.dotnetVersion(ctx)));
		var log = project + "/publish.log";
		var result = run(["publish", project + "/aot.csproj", "-c", "Release", "-nologo", "-v:q", "-nodeReuse:false"]);
		if (result == null) {
			ctx.addDiagnostic("dotnet: -D dotnet-aot needs the .NET SDK, and `dotnet` could not be started", Position.nullPos);
			return;
		}
		sys.io.File.saveContent(log, result.output);
		if (result.code != 0)
			ctx.addDiagnostic("dotnet: -D dotnet-aot: the publish failed (the whole report is in " + log + ")\n" + errorLines(result.output), Position.nullPos);
	}

	// Joined with "\n" so the file is the same whatever line endings this source was checked out with. The
	// assembly is rooted, as the runtime's reflection reaches its members by name, which the compiler can't see.
	static function projectFile(ctx:Context, name:String, version:Int):String {
		var items = ['    <TrimmerRootAssembly Include="' + escape(name) + '" />'];
		var descriptor = descriptorOf(ctx);
		if (descriptor != null) items.push('    <TrimmerRootDescriptor Include="' + escape(FileSystem.fullPath(descriptor)) + '" />');
		for (lib in ctx.netLibs) {
			if (lib.isStd) continue;
			var file = FileSystem.fullPath(lib.filePath);
			var simple = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
			items.push('    <Reference Include="' + escape(simple) + '"><HintPath>' + escape(file) + '</HintPath></Reference>');
		}
		var program = name + (Sys.systemName() == "Windows" ? ".exe" : "");
		return [
			'<Project>',
			'  <Import Project="Sdk.props" Sdk="Microsoft.NET.Sdk" />',
			'  <PropertyGroup>',
			'    <OutputType>Exe</OutputType>',
			'    <TargetFramework>net' + version + '.0</TargetFramework>',
			'    <AssemblyName>' + escape(name) + '</AssemblyName>',
			'    <PublishAot>true</PublishAot>',
			'    <PublishDir>publish/</PublishDir>',
			'    <ProduceReferenceAssembly>false</ProduceReferenceAssembly>',
			'    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>',
			'    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>',
			'    <SatelliteResourceLanguages>en</SatelliteResourceLanguages>',
			'  </PropertyGroup>',
			'  <ItemGroup>',
			items.join("\n"),
			'  </ItemGroup>',
			'  <Import Project="Sdk.targets" Sdk="Microsoft.NET.Sdk" />',
			'  <Target Name="CoreCompile">',
			'    <Copy SourceFiles="../' + escape(name) + '.dll" DestinationFiles="@(IntermediateAssembly)" />',
			'  </Target>',
			'  <Target Name="CopyNativeProgram" AfterTargets="Publish">',
			'    <Copy SourceFiles="publish/' + escape(program) + '" DestinationFolder=".." />',
			'  </Target>',
			'</Project>',
			''
		].join("\n");
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

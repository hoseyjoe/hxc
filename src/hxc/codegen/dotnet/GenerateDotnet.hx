package hxc.codegen.dotnet;

import hxc.context.Context;

// The entry point of the .NET IL generator (--cs <dir> -D dotnet): writes <name>.dll into the output
// directory, plus <name>.runtimeconfig.json for a program with a main.

class GenerateDotnet {
	// Joined with "\n" so the file is the same whatever line endings this source was checked out with.
	static final runtimeConfig = [
		'{',
		'  "runtimeOptions": {',
		'    "tfm": "net10.0",',
		'    "framework": {',
		'      "name": "Microsoft.NETCore.App",',
		'      "version": "10.0.0"',
		'    }',
		'  }',
		'}',
		''
	].join("\n");

	public static function generate(ctx:Context):Void {
		var dir = ctx.file.split("\\").join("/");
		while (dir.length > 1 && StringTools.endsWith(dir, "/")) dir = dir.substr(0, dir.length - 1);
		// The assembly is named by -D dll-name, else by the output directory's last segment.
		var name = ctx.defines.rawDefined("dll_name") ? ctx.defines.rawDefinedValueSafe("dll_name") : dir.substr(dir.lastIndexOf("/") + 1);
		var isDll = ctx.main == null;
		var mb = new ModuleBuilder(name, isDll);
		sys.io.File.saveBytes(dir + "/" + name + ".dll", mb.finish(0));
		if (!isDll) sys.io.File.saveContent(dir + "/" + name + ".runtimeconfig.json", runtimeConfig);
	}
}

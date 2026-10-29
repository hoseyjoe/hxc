package hxc.codegen.dotnet;

import haxe.io.Path;

// The name a PDB's Document row gives a source file: relative to the current folder when the file is
// under it, else its full path, with forward slashes.

class PdbPaths {
	// The current folder, absolute, ending with a slash.
	final cwd:String;

	public function new(cwd:String) {
		this.cwd = Path.addTrailingSlash(Path.normalize(sys.FileSystem.absolutePath(cwd)));
	}

	public function name(file:String):String {
		// A file of the embedded runtime is on no disk.
		if (RuntimeSources.isVirtual(file)) return file;
		var full = Path.normalize(sys.FileSystem.absolutePath(file));
		var under = Sys.systemName() == "Windows" ? StringTools.startsWith(full.toLowerCase(), cwd.toLowerCase()) : StringTools.startsWith(full, cwd);
		return under ? full.substr(cwd.length) : full;
	}
}

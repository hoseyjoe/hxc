package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.codegen.dotnet.IlMeta.TypeDefSemantics;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMetaTools.IlNotFound;
import hxc.codegen.dotnet.NetConverter;

// an assembly indexed by Haxe path when it loads, whose classes are converted only when a module is
// asked for.
class NetLibrary {
	public var name(default, null):String;
	public var filePath(default, null):String;
	public var isStd(default, null):Bool;
	// an extern lib is only read, never copied next to the output
	public var isExtern:Bool = false;

	var com:Context;
	var ilctx:Null<NetLibCtx> = null;
	// keyed by sTypePath; a type the library lacks is cached as null too
	var cache:Map<String, Null<IlClass>> = new Map();

	public function new(com:Context, name:String, filePath:String, isStd:Bool) {
		this.com = com;
		this.name = name;
		this.filePath = filePath;
		this.isStd = isStd;
	}

	function netpathToHx(path:IlPath):Path return NetConverter.netpathToHx(isStd, path);

	public function load():Void {
		var pe = PeReader.read(sys.io.File.getBytes(filePath));
		var clrHeader = PeReader.readClrHeader(pe);
		var meta = IlMetaReader.readMetaTables(pe, clrHeader);
		var debug = com.defines.rawDefined("net_loader_debug");
		if (debug) Sys.println("for lib " + filePath);
		// the types are keyed again now that nested ones know their enclosing type
		meta.typedefs = new Map();
		for (td in meta.typedefOrder) {
			var path = IlMetaTools.getPath(TypeDef(td));
			var hx = netpathToHx(path);
			if (debug) Sys.println("found " + Globals.sTypePath(hx));
			com.netPathMap.set(Globals.sTypePath(hx), path);
			meta.typedefs.set(IlPaths.key(path), td);
		}
		ilctx = {nstd: isStd, ncom: com, nil: meta};
	}

	function getCtx():NetLibCtx {
		if (ilctx == null) load();
		return ilctx;
	}

	// the top-level types, in table order
	public function listModules():Array<Path> {
		return [
			for (td in getCtx().nil.typedefOrder) {
				var path = IlMetaTools.getPath(TypeDef(td));
				if (path.nested.length == 0) netpathToHx(path);
			}
		];
	}

	public function lookup(path:Path):Null<IlClass> {
		var key = Globals.sTypePath(path);
		if (cache.exists(key)) return cache.get(key);
		var r:Null<IlClass> = try {
			var ctx = getCtx();
			var cls = IlMetaTools.convertClass(ctx.nil, NetConverter.hxpathToNet(com, path));
			NetConverter.normalizeIlcls(ctx, cls);
		} catch (_:IlNotFound) null;
		cache.set(key, r);
		return r;
	}

	// the class, then its nested types; a sealed delegate also gives the abstract that wraps it.
	public function build(path:Path, p:Position):Null<Array<TypeDecl>> {
		var p = new Position(filePath + " @ " + Globals.sTypePath(path), 0, 0);
		// the package is not used: the module path comes from the request
		var cp:Array<TypeDecl> = [];
		var debug = com.defines.rawDefined("net_loader_debug");
		function build(path:Path) {
			try {
				if (debug) Sys.println("looking up " + Globals.sTypePath(path));
				var cls = lookup(path);
				if (cls == null) return;
				var isDelegate = cls.csuper != null && switch (cls.csuper.snorm) {
					case LClass(p, _): p.ns.length == 1 && p.ns[0] == "System" && p.nested.length == 0
						&& (p.name == "Delegate" || p.name == "MulticastDelegate");
					case _: false;
				}
				if (isDelegate && cls.cflags.semantics.indexOf(SSealed) >= 0) {
					var ctx = getCtx();
					var hxcls = NetConverter.convertIlClass(ctx, p, cls, true);
					var delegate = NetConverter.convertDelegate(ctx, p, cls);
					cp.unshift(delegate);
					cp.unshift(hxcls);
				} else if (!NetConverter.isCompilerGenerated(cls)) {
					cp.unshift(NetConverter.convertIlClass(getCtx(), p, cls, false));
				} else
					return;
				for (ilpath in cls.cnested) build(netpathToHx(ilpath));
			} catch (_:IlNotFound) {} catch (_:NetExit) {}
		}
		build(path);
		return cp.length == 0 ? null : cp;
	}
}

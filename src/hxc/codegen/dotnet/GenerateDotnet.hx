package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta.TableIdx;
import hxc.codegen.dotnet.TclassToIl;

// The state of one generation: the module being built, member tokens keyed by field identity, and
// what the stub rule recorded.
class DotnetCtx {
	public final ctx:Context;
	public final mb:ModuleBuilder;
	public final types:DotnetTypes;
	public final sigs:SigWriter;
	public final externs:ExternMembers;
	public final methodTokens = new ObjectMap<TClassField, Int>();
	public final methodSigs = new ObjectMap<TClassField, {ret:IlSigNorm, args:Array<IlSigNorm>}>();
	public final fieldTokens = new ObjectMap<TClassField, Int>();
	public final fieldSigs = new ObjectMap<TClassField, IlSigNorm>();
	public final planOf = new ObjectMap<TClass, ClassPlan>();
	// The plan of the class declaring each Haxe field and method.
	public final ownerOf = new ObjectMap<TClassField, ClassPlan>();
	public var plans:Array<ClassPlan> = [];
	// "skipped", "stubbed" and "ignored" lines for -D dotnet-stub-report.
	public final records:Array<String> = [];
	public var mainClass:Null<TClass> = null;
	public var entryPoint = 0;
	public var diagnostics = 0;

	final stdRoots:Array<String>;

	public function new(ctx:Context, mb:ModuleBuilder) {
		this.ctx = ctx;
		this.mb = mb;
		types = new DotnetTypes(ctx, mb);
		sigs = new SigWriter(mb.typeToken);
		externs = new ExternMembers(ctx, types);
		stdRoots = [for (p in ctx.stdPath) normalizePath(p)];
	}

	static function normalizePath(p:String):String {
		var s = p.split("\\").join("/");
		return Sys.systemName() == "Windows" ? s.toLowerCase() : s;
	}

	// Code from a file under one of the std directories.
	public function isStd(pos:Position):Bool {
		var f = normalizePath(pos.file);
		for (r in stdRoots) if (r != "" && StringTools.startsWith(f, r)) return true;
		return false;
	}

	public function report(u:Unsupported):Void {
		ctx.addDiagnostic("dotnet: " + u.what + " " + u.verb() + " not supported yet", u.pos == null ? Position.nullPos : u.pos);
		diagnostics++;
	}

	// The metadata token box, unbox.any, castclass and member references take for a type.
	public function typeTokenOf(s:IlSigNorm):Int {
		return switch (s) {
			case LClass(p, []): ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, false));
			case LValueType(p, []): ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, true));
			case _:
				var p = DotnetTypes.primitivePath(s);
				if (p != null) ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, DotnetTypes.isValueType(s)));
				else mb.typeSpec(sigs.typeSpec(s));
		}
	}

	var classes:Null<Map<String, TClass>> = null;

	// The Haxe class, extern or not, that a .NET path names.
	public function classAt(p:IlPath):Null<TClass> {
		if (classes == null) {
			classes = new Map();
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c):
					var path = if (!TypeFunctions.hasClassFlag(c, CExtern)) DotnetNames.typePath(mt) else try types.externPath(c) catch (_:Unsupported) null;
					if (path != null && !classes.exists(IlPaths.key(path))) classes.set(IlPaths.key(path), c);
				case _:
			}
		}
		return classes.get(IlPaths.key(p));
	}

	// A class defined by Haxe code (not an extern) with type arguments.
	public function isGenericHaxeClass(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, args) | LValueType(p, args) if (args.length > 0):
				var c = classAt(p);
				c != null && !TypeFunctions.hasClassFlag(c, CExtern);
			case _: false;
		}
	}

	// Whether a value of the non-generic class `from` already is a `to`, through its superclasses and
	// interfaces as Haxe declares them.
	public function isUpcast(from:IlSigNorm, to:IlSigNorm):Bool {
		var c = switch (from) {
			case LClass(p, []): classAt(p);
			case _: null;
		}
		if (c == null) return false;
		function reaches(c:TClass, params:Array<T>):Bool {
			var s = try types.toSig(TInst(c, params)) catch (_:Unsupported) return false;
			if (IlPaths.sigEq(s, to)) return true;
			var supers = c.interfaces.copy();
			if (c.superClass != null) supers.push(c.superClass);
			for (sup in supers) {
				var args = [for (t in sup.params) TypeFunctions.applyParams(c.params, params, t)];
				if (reaches(sup.c, args)) return true;
			}
			return false;
		}
		return reaches(c, []);
	}

	// cs.Boot.init's token when cs.Boot is one of the program's types, as gencs calls it. A cs.Boot
	// that was left out throws, so the entry point reports it.
	public function bootInit():Null<Int> {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (DotnetTypes.haxePath(mt) == "cs.Boot"):
				types.checkKept(mt);
				var init = c.statics.get("init");
				var token = init == null ? null : methodTokens.get(init);
				if (token == null) throw "internal error: cs.Boot has no init method";
				return token;
			case _:
		}
		return null;
	}
}

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
		var g = new DotnetCtx(ctx, mb);
		var identities = new Map<String, ModuleBuilder.AssemblyIdentity>();
		mb.externScope = function(path:IlPath) {
			for (lib in ctx.netLibs) if (lib.definesType(path)) {
				var id = identities.get(lib.filePath);
				if (id == null) {
					id = lib.identity();
					identities.set(lib.filePath, id);
				}
				return id;
			}
			throw "internal error: no referenced assembly defines " + NetConverter.ilpathS(path);
		}
		DotnetNames.noRoot = ctx.defines.rawDefined("no_root");

		var candidates:Array<TClass> = [];
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
				candidates.push(c);
				if (ctx.mainClass != null && Globals.sTypePath(c.path) == Globals.sTypePath(ctx.mainClass)) g.mainClass = c;
			case TEnumDecl(e) if (!e.isExtern):
				leaveOut(g, mt, e.pos, new Unsupported("enums", true, e.pos));
			case _:
		}
		if (ctx.main != null && g.mainClass == null) {
			// The main class is found by its expression when the path differs, e.g. through @:native.
			switch (ctx.main.expr) {
				case TCall({expr: TField(_, FStatic(c, _))}, _): g.mainClass = c;
				case _:
			}
		}

		// A class that cannot be declared is left out, and so is every class that refers to it; this
		// runs until nothing more is left out.
		var changed = true;
		while (changed) {
			changed = false;
			g.plans = [];
			for (c in candidates) {
				var mt = TClassDecl(c);
				if (g.types.leftOut.exists(DotnetTypes.haxePath(mt))) continue;
				try {
					TclassToIl.declare(g, c);
				} catch (u:Unsupported) {
					leaveOut(g, mt, c.pos, u);
					changed = true;
				}
			}
		}
		var plans = [];
		for (p in g.plans) {
			plans.push(p);
			if (p.c == g.mainClass && p.c.path.name == "Main") plans.push(TclassToIl.entryPointClass(g, p.c));
		}
		g.plans = plans;

		for (p in plans) p.token = mb.typeDef(p.flags, p.path);
		for (p in plans) TclassToIl.write(g, p);
		// GenericParam rows go in owner order, a TypeDef's before its methods'.
		var generics = [];
		for (p in plans) {
			for (i in 0...p.classParams.length) generics.push({owner: p.token, number: i, name: p.classParams[i].name});
			for (m in p.methods) for (i in 0...m.generics.length) generics.push({owner: m.token, number: i, name: m.generics[i]});
		}
		inline function key(owner:Int) return ModuleBuilder.coded(TableIdx.ITypeOrMethodDef, owner);
		haxe.ds.ArraySort.sort(generics, (a, b) -> key(a.owner) != key(b.owner) ? key(a.owner) - key(b.owner) : a.number - b.number);
		for (gp in generics) mb.genericParam(gp.owner, gp.number, gp.name);
		for (p in plans) TclassToIl.emitPlan(g, p);

		if (ctx.defines.rawDefined("dotnet_stub_report")) {
			var lines = g.records.copy();
			lines.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (l in lines) ctx.info(l, Position.nullPos);
		}
		if (g.diagnostics > 0) return;
		if (!isDll && g.entryPoint == 0) throw "internal error: the program has no entry point";
		sys.io.File.saveBytes(dir + "/" + name + ".dll", mb.finish(g.entryPoint));
		if (!isDll) sys.io.File.saveContent(dir + "/" + name + ".runtimeconfig.json", runtimeConfig);
	}

	// A standard-library type is left out and recorded; a user type is an error.
	static function leaveOut(g:DotnetCtx, mt:ModuleType, pos:Position, u:Unsupported):Void {
		var path = DotnetTypes.haxePath(mt);
		g.types.leftOut.set(path, u.what);
		if (g.isStd(pos)) {
			g.records.push("skipped " + path + ": " + u.what);
		} else {
			if (u.pos == null) u.pos = pos;
			g.report(u);
		}
	}
}

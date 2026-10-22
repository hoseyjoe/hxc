package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.IlData;

// Something the generator cannot compile yet. `what` names it for "dotnet: <what> is not supported
// yet"; `plural` picks "are". A null position is filled in by the expression or member being lowered.
class Unsupported {
	public var what:String;
	public var pos:Null<Position>;
	public var plural:Bool;

	public function new(what:String, plural:Bool, ?pos:Position) {
		this.what = what;
		this.plural = plural;
		this.pos = pos;
	}

	public function verb():String return plural ? "are" : "is";

	public function toString():String return "Unsupported(" + what + ")";
}

// Haxe types as CLR signatures, as gencs maps them.
class DotnetTypes {
	final ctx:Context;
	final mb:ModuleBuilder;

	// The types left out of the assembly, keyed by Haxe path, with the reason; GenerateDotnet fills it.
	public final leftOut = new Map<String, String>();

	// The type parameters of the class and method whose signatures are being written.
	var classParams:TypeParams = [];
	var methodParams:TypeParams = [];

	public function new(ctx:Context, mb:ModuleBuilder) {
		this.ctx = ctx;
		this.mb = mb;
	}

	public function withParams<R>(classParams:TypeParams, methodParams:TypeParams, f:() -> R):R {
		var oc = this.classParams, om = this.methodParams;
		this.classParams = classParams;
		this.methodParams = methodParams;
		try {
			var r = f();
			this.classParams = oc;
			this.methodParams = om;
			return r;
		} catch (e:Dynamic) {
			this.classParams = oc;
			this.methodParams = om;
			throw e;
		}
	}

	// The class type parameters signatures are being written in terms of.
	public function currentClassParams():TypeParams return classParams;

	public function inParams(classParams:TypeParams, methodParams:TypeParams, f:() -> Void):Void {
		withParams(classParams, methodParams, () -> {
			f();
			return true;
		});
	}

	public static function haxePath(mt:ModuleType):String {
		var infos = TypeFunctions.tInfos(mt);
		for (m in infos.meta)
			if (m.name == ":realPath" && m.params.length == 1) switch (m.params[0].expr) {
				case EConst(CString(s, _)): return s;
				case _:
			}
		return Globals.sTypePath(infos.path);
	}

	static function isPath(p:Path, pack:Array<String>, name:String):Bool {
		return p.name == name && IlPaths.strsEq(p.pack, pack);
	}

	public static function isValueType(s:IlSigNorm):Bool {
		return switch (s) {
			case LBool | LChar | LInt8 | LUInt8 | LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64
				| LIntPtr | LUIntPtr | LTypedReference | LValueType(_, _):
				true;
			case _: false;
		}
	}

	// The primitive a System type is written as in a signature, or null.
	public static function primitive(p:IlPath):Null<IlSigNorm> {
		if (p.nested.length > 0 || p.ns.length != 1 || p.ns[0] != "System") return null;
		return switch (p.name) {
			case "Object": LObject;
			case "String": LString;
			case "Boolean": LBool;
			case "Char": LChar;
			case "SByte": LInt8;
			case "Byte": LUInt8;
			case "Int16": LInt16;
			case "UInt16": LUInt16;
			case "Int32": LInt32;
			case "UInt32": LUInt32;
			case "Int64": LInt64;
			case "UInt64": LUInt64;
			case "Single": LFloat32;
			case "Double": LFloat64;
			case "IntPtr": LIntPtr;
			case "UIntPtr": LUIntPtr;
			case "TypedReference": LTypedReference;
			case _: null;
		}
	}

	// The System type of a primitive, for the tokens box and unbox.any take.
	public static function primitivePath(s:IlSigNorm):Null<IlPath> {
		var name = switch (s) {
			case LObject: "Object";
			case LString: "String";
			case LBool: "Boolean";
			case LChar: "Char";
			case LInt8: "SByte";
			case LUInt8: "Byte";
			case LInt16: "Int16";
			case LUInt16: "UInt16";
			case LInt32: "Int32";
			case LUInt32: "UInt32";
			case LInt64: "Int64";
			case LUInt64: "UInt64";
			case LFloat32: "Single";
			case LFloat64: "Double";
			case LIntPtr: "IntPtr";
			case LUIntPtr: "UIntPtr";
			case LTypedReference: "TypedReference";
			case _: return null;
		}
		return {ns: ["System"], nested: [], name: name};
	}

	// The .NET path of an extern class or enum: the referenced assemblies' own, else @:native.
	public function externPathOf(mt:ModuleType):IlPath {
		var infos = TypeFunctions.tInfos(mt);
		var p = ctx.netPathMap.get(Globals.sTypePath(infos.path));
		if (p != null) return p;
		var native = DotnetNames.nativeName(infos.meta);
		if (native != null) {
			var parts = native.split(".");
			var name = parts.pop();
			return {ns: parts, nested: [], name: name};
		}
		throw new Unsupported("the extern type " + Globals.sTypePath(infos.path) + " without a .NET name", false);
	}

	public function externPath(c:TClass):Null<IlPath> {
		return externPathOf(TClassDecl(c));
	}

	// A referenced type must come from one of the referenced assemblies.
	function defined(p:IlPath):IlPath {
		for (lib in ctx.netLibs) if (lib.definesType(p)) return p;
		throw new Unsupported("the .NET type " + NetConverter.ilpathS(p) + " outside the referenced assemblies", false);
	}

	// A type the assembly defines, unless it was left out.
	public function checkKept(mt:ModuleType):Void {
		var key = haxePath(mt);
		var why = leftOut.get(key);
		if (why != null) throw new Unsupported(key + " (left out: " + why + ")", false);
	}

	function typeParam(c:TClass):IlSigNorm {
		for (i in 0...classParams.length) switch (classParams[i].type) {
			case TInst(c2, _) if (c2 == c): return LTypeParam(i);
			case _:
		}
		for (i in 0...methodParams.length) switch (methodParams[i].type) {
			case TInst(c2, _) if (c2 == c): return LMethodTypeParam(i);
			case _:
		}
		// A type parameter of a local function or one the signature does not declare.
		return LObject;
	}

	public function toSig(t:T):IlSigNorm {
		return switch (t) {
			case TMono(m): m.type == null ? LObject : toSig(m.type);
			case TLazy(f): toSig(TypeFunctions.lazyType(f));
			case TDynamic(_) | TAnon(_): LObject;
			case TFun(_): throw new Unsupported("function types", true);
			case TType(d, [p]) if (isPath(d.path, ["cs"], "Ref") || isPath(d.path, ["cs"], "Out")):
				LManagedPointer(toSig(p));
			case TType(d, params): toSig(TypeFunctions.applyTypedef(d, params));
			case TEnum(e, params):
				if (!e.isExtern) {
					checkKept(TEnumDecl(e));
					throw new Unsupported("enums", true);
				}
				LValueType(defined(externPathOf(TEnumDecl(e))), []);
			case TInst(c, params):
				switch (c.kind) {
					case KTypeParameter(_): return typeParam(c);
					case _:
				}
				if (isPath(c.path, [], "String")) return LString;
				if (TypeFunctions.hasClassFlag(c, CExtern)) {
					if (isPath(c.path, ["cs"], "NativeArray")) return LVector(toSig(params[0]));
					var p = externPath(c);
					var prim = primitive(p);
					if (prim != null) return prim;
					var args = [for (a in params) toSig(a)];
					defined(p);
					TypeFunctions.hasMeta(":struct", c.meta) ? LValueType(p, args) : LClass(p, args);
				} else {
					checkKept(TClassDecl(c));
					var p = DotnetNames.typePath(TClassDecl(c));
					var args = [for (a in params) toSig(a)];
					TypeFunctions.hasMeta(":struct", c.meta) ? LValueType(p, args) : LClass(p, args);
				}
			case TAbstract(a, params):
				var p = a.path;
				if (p.pack.length == 0) switch (p.name) {
					case "Int": return LInt32;
					case "Float": return LFloat64;
					case "Bool": return LBool;
					case "Void": return LVoid;
					case "Single": return LFloat32;
					case "UInt": return LUInt32;
					case "Dynamic": return LObject;
					case "Null":
						var s = toSig(params[0]);
						if (isValueType(s)) throw new Unsupported("Null<T> of a value type", false);
						return s;
					case _:
				}
				if (isPath(p, ["cs"], "Pointer")) return LPointer(toSig(params[0]));
				if (p.pack.length == 1 && p.pack[0] == "cs" && p.name != "Pointer" && a.module.path.name == "StdTypes") switch (p.name) {
					case "Int8": return LInt8;
					case "Int16": return LInt16;
					case "Char16": return LChar;
					case "UInt8": return LUInt8;
					case "UInt16": return LUInt16;
					case "Int64": return LInt64;
					case "UInt64": return LUInt64;
					case _:
				}
				if (TypeFunctions.hasMeta(":coreType", a.meta)) throw new Unsupported("the core type " + Globals.sTypePath(p), false);
				toSig(TypeFunctions.getUnderlyingType(a, params));
		}
	}
}

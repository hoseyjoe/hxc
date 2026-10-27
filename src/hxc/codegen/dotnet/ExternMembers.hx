package hxc.codegen.dotnet;

import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;

enum ExternField {
	// initOnly: readonly in C#, which only a constructor may store to or take the address of.
	XField(sig:IlSigNorm, initOnly:Bool);
	// A literal, which has no storage: it is loaded as its value. `sig` is the field's declared type,
	// which says whether a small integer is signed.
	XConstant(c:IlConstant, sig:IlSigNorm);
	XProperty(sig:IlSigNorm, getter:Null<String>, setter:Null<String>);
}

// The members of referenced assemblies that extern Haxe fields stand for, as those assemblies declare
// them. The typer already chose the overload; this only finds its definition.

class ExternMembers {
	final ctx:Context;
	final types:DotnetTypes;

	public function new(ctx:Context, types:DotnetTypes) {
		this.ctx = ctx;
		this.types = types;
	}

	// The class as the assembly NetRefs finds for it declares it.
	function rawClass(path:IlPath):IlClass {
		var refs = NetRefs.of(ctx);
		var lib = refs.definer(path);
		if (lib == null) throw Unsupported.error(refs.missing(path));
		var cls = lib.rawClass(path);
		if (cls == null)
			throw Unsupported.bug("the .NET type " + NetConverter.ilpathS(path) + ", which " + lib.filePath + " defines but hxc cannot read");
		return cls;
	}

	static function isSystem(s:Null<IlSigT>, name:String):Bool {
		if (s == null) return false;
		return switch (s.snorm) {
			case LClass(p, _): p.ns.length == 1 && p.ns[0] == "System" && p.nested.length == 0 && p.name == name;
			case _: false;
		}
	}

	public static function isValueTypeClass(cls:IlClass):Bool {
		// System.Enum itself extends System.ValueType but is a class.
		return isSystem(cls.csuper, "ValueType") && !DotnetTypes.isSystemEnum(cls.cpath) || isSystem(cls.csuper, "Enum");
	}

	// Replaces the class type parameters of `s` with `args`.
	public static function subst(s:IlSigNorm, args:Array<IlSigNorm>):IlSigNorm {
		inline function all(l:Array<IlSigNorm>) return [for (a in l) subst(a, args)];
		return switch (s) {
			case LTypeParam(i) if (i < args.length): args[i];
			case LPointer(t): LPointer(subst(t, args));
			case LManagedPointer(t): LManagedPointer(subst(t, args));
			case LVector(t): LVector(subst(t, args));
			case LArray(t, d): LArray(subst(t, args), d);
			case LValueType(p, l): LValueType(p, all(l));
			case LClass(p, l): LClass(p, all(l));
			case LMethod(cc, r, l): LMethod(cc, subst(r, args), all(l));
			case _: s;
		}
	}

	// The supertypes of `c`'s .NET class, each with its parent signature in terms of `c`'s type
	// parameters.
	function chain(c:TClass):Array<{cls:IlClass, parent:IlSigNorm}> {
		var path = types.externPath(c);
		var cls = rawClass(path);
		var parent = LClass(path, [for (i in 0...cls.ctypes.length) LTypeParam(i)]);
		var r = [];
		while (true) {
			if (isValueTypeClass(cls)) parent = switch (parent) {
				case LClass(p, l): LValueType(p, l);
				case s: s;
			}
			r.push({cls: cls, parent: parent});
			if (cls.csuper == null) break;
			var sup = switch (subst(cls.csuper.snorm, switch (parent) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			})) {
				case LClass(p, l): {path: p, args: l};
				case LObject: {path: ({ns: ["System"], nested: [], name: "Object"} : IlPath), args: []};
				case _: break;
			}
			cls = rawClass(sup.path);
			parent = LClass(sup.path, sup.args);
		}
		return r;
	}

	// The name the referenced assembly gives the member: @:native's when the converter renamed it.
	public static function memberName(cf:TClassField):String {
		var n = DotnetNames.nativeName(cf.meta);
		return n != null ? n : cf.name;
	}

	// Static methods of a generic class take Dynamic where the class has a type parameter, as the
	// converter declared them.
	static function eraseClassParams(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LTypeParam(_): LObject;
			case LPointer(t): LPointer(eraseClassParams(t));
			case LManagedPointer(t): LManagedPointer(eraseClassParams(t));
			case LVector(t): LVector(eraseClassParams(t));
			case LArray(t, d): LArray(eraseClassParams(t), d);
			case LValueType(p, l): LValueType(p, [for (a in l) eraseClassParams(a)]);
			case LClass(p, l): LClass(p, [for (a in l) eraseClassParams(a)]);
			case _: s;
		}
	}

	public function method(c:TClass, cf:TClassField):{parent:IlSigNorm, name:String, sig:IlSigNorm, isStatic:Bool, genericCount:Int, isVirtual:Bool} {
		var isCtor = cf.name == "new";
		var isStatic = !isCtor && TypeFunctions.hasClassFieldFlag(cf, CfStatic);
		var name = isCtor ? ".ctor" : memberName(cf);
		var want = types.withParams(c.params, cf.params, function() {
			return switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig): [for (a in sig.args) types.toSig(a.t)];
				case _: throw "internal error: extern method " + cf.name + " has no function type";
			}
		});
		for (link in chain(c)) {
			var args = switch (link.parent) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			};
			for (m in link.cls.cmethods) {
				if (m.mname != name || m.margs.length != want.length || m.mtypes.length != cf.params.length) continue;
				if ((m.mflags.contract.indexOf(CMStatic) >= 0) != isStatic) continue;
				var got = [for (a in m.margs) isStatic ? eraseClassParams(a.sig.snorm) : subst(a.sig.snorm, args)];
				if (IlPaths.sigsEq(got, want)) {
					var contract = m.mflags.contract;
					return {
						parent: link.parent,
						name: name,
						sig: m.msig.snorm,
						isStatic: isStatic,
						genericCount: m.mtypes.length,
						isVirtual: contract.indexOf(CMVirtual) >= 0 && contract.indexOf(CMFinal) < 0
					};
				}
			}
			if (isCtor) break;
		}
		throw new Unsupported("the .NET method " + Globals.sTypePath(c.path) + "." + cf.name + " with these argument types", false);
	}

	// The static overloads of an operator, such as op_Equality, that C# considers for an operand of
	// `c`'s .NET class: those of the nearest class in its chain declaring any.
	// An extern class no referenced assembly defines has no metadata to declare any; its members are
	// refused where they are used.
	public function operators(c:TClass, name:String):Array<{parent:IlSigNorm, sig:IlSigNorm, args:Array<IlSigNorm>}> {
		var path = try types.externPath(c) catch (_:Unsupported) null;
		if (path == null || NetRefs.of(ctx).definer(path) == null) return [];
		for (link in chain(c)) {
			var found = [];
			for (m in link.cls.cmethods) {
				if (m.mname != name || m.mflags.contract.indexOf(CMStatic) < 0) continue;
				switch (link.parent) {
					case LClass(_, l) | LValueType(_, l) if (l.length > 0):
						throw new Unsupported("operators of generic .NET types", true);
					case _:
				}
				found.push({parent: link.parent, sig: m.msig.snorm, args: [for (a in m.margs) a.sig.snorm]});
			}
			if (found.length > 0) return found;
		}
		return [];
	}

	// The type a .NET enum stores its values as (its value__ field's), or null when `path` is not an
	// enum of the referenced assemblies.
	public function enumUnderlying(path:IlPath):Null<IlSigNorm> {
		if (NetRefs.of(ctx).definer(path) == null) return null;
		var cls = rawClass(path);
		if (!isSystem(cls.csuper, "Enum")) return null;
		for (f in cls.cfields) if (f.fname == "value__") return f.fsig.snorm;
		return null;
	}

	// The literal a constructor of an extern .NET enum stands for, and the type the enum stores it as.
	public function enumLiteral(en:TEnum, ef:TEnumField):{c:IlConstant, underlying:IlSigNorm} {
		var path = types.externPathOf(TEnumDecl(en));
		var refs = NetRefs.of(ctx);
		if (refs.definer(path) == null) throw Unsupported.error(refs.missing(path));
		var underlying = enumUnderlying(path);
		if (underlying == null) throw new Unsupported("the .NET enum " + NetConverter.ilpathS(path) + " outside the referenced assemblies", false);
		var name = DotnetNames.nativeName(ef.meta);
		if (name == null) name = ef.name;
		for (f in rawClass(path).cfields) if (f.fname == name && f.fconstant != null) return {c: f.fconstant, underlying: underlying};
		throw new Unsupported("the unknown .NET enum constant " + Globals.sTypePath(en.path) + "." + ef.name, false);
	}

	public function field(c:TClass, cf:TClassField):ExternField {
		var name = memberName(cf);
		for (link in chain(c)) {
			for (f in link.cls.cfields) if (f.fname == name) return f.fconstant != null ? XConstant(f.fconstant, f.fsig.snorm) : XField(f.fsig.snorm, f.fflags.contract.indexOf(CInitOnly) >= 0);
			for (p in link.cls.cprops) if (p.pname == name) {
				var t = switch (p.psig.snorm) {
					case LMethod(_, ret, _): ret;
					case s: s;
				}
				return XProperty(t, p.pget == null ? null : p.pget.name, p.pset == null ? null : p.pset.name);
			}
		}
		throw new Unsupported("the unknown .NET field " + Globals.sTypePath(c.path) + "." + cf.name, false);
	}
}

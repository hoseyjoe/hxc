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

// A .NET method an extern method binds to. `omitted`: the trailing parameters a call leaves out, which
// C# fills from their defaults. `typeArgs`: the type arguments of a generic method that a non-generic
// extern method binds to, as the declared argument types give them.
typedef ExternMethod = {
	parent:IlSigNorm,
	name:String,
	sig:IlSigNorm,
	isStatic:Bool,
	genericCount:Int,
	isVirtual:Bool,
	omitted:Array<IlMethodArg>,
	typeArgs:Null<Array<IlSigNorm>>
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

	static function linkArgs(link:{cls:IlClass, parent:IlSigNorm}):Array<IlSigNorm> {
		return switch (link.parent) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
	}

	// A member's signature `s` in terms of the extern's class type parameters, `args` being the declaring
	// class's arguments in those terms.
	static function open(s:IlSigNorm, args:Array<IlSigNorm>, isStatic:Bool):IlSigNorm {
		return isStatic ? eraseClassParams(s) : subst(s, args);
	}

	// A converted (`:csNative`) extern stands for the metadata as it is; any other is written by hand.
	static function isHandWritten(c:TClass):Bool return !TypeFunctions.hasMeta(":csNative", c.meta);

	// The method of `c`'s .NET class that the extern method `cf` stands for. A method with exactly the
	// declared signature comes first, which is all a converted extern's member binds to (the typer chose
	// it already). A hand-written extern's method otherwise binds as C# binds a call with the declared
	// types, under ruling 1's restricted rule: the one applicable overload of the most derived class that
	// has any, through C#'s implicit conversions, followed by parameters the call leaves out that are
	// optional or a params array; a generic one with type arguments the declared types give. A
	// hand-written extern's return type must convert from the method's too. `exactOnly` binds the exact
	// match or nothing, for a member whose own signature an implementation or override takes.
	public function method(c:TClass, cf:TClassField, exactOnly = false):ExternMethod {
		var isCtor = cf.name == "new";
		var isStatic = !isCtor && TypeFunctions.hasClassFieldFlag(cf, CfStatic);
		var name = isCtor ? ".ctor" : memberName(cf);
		var declared = switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): sig;
			case _: throw "internal error: extern method " + cf.name + " has no function type";
		}
		var want = types.withParams(c.params, cf.params, () -> [for (a in declared.args) types.toSig(a.t)]);
		var links = chain(c);
		if (isCtor) links = [links[0]];
		var handWritten = isHandWritten(c);
		for (link in links) {
			var args = linkArgs(link);
			for (m in link.cls.cmethods) {
				if (m.mname != name || m.margs.length != want.length || m.mtypes.length != cf.params.length) continue;
				if ((m.mflags.contract.indexOf(CMStatic) >= 0) != isStatic) continue;
				var got = [for (a in m.margs) open(a.sig.snorm, args, isStatic)];
				if (IlPaths.sigsEq(got, want)) return bound(c, cf, link, m, isStatic, want.length, null, handWritten && !isCtor);
			}
		}
		if (exactOnly || !handWritten)
			throw new Unsupported("the .NET method " + Globals.sTypePath(c.path) + "." + cf.name + " with these argument types", false);
		var what = isCtor ? "constructor of " + typeS(c) : "overload of " + typeS(c) + "." + name;
		var given = "(" + [for (s in want) sigS(s)].join(", ") + ")";
		for (link in links) {
			var found = applicable(link, name, isStatic, want, cf.params.length);
			if (found.length == 1) return bound(c, cf, link, found[0].m, isStatic, want.length, found[0].typeArgs, !isCtor);
			if (found.length > 1) throw Unsupported.error("more than one .NET " + what + " accepts " + given);
		}
		// A Haxe-optional value-type argument is a haxe.lang.Null<T>, which the typer pads a left-out one
		// with and which converts to no .NET value type: gencs's C# fails there (CS1503). Ruling 4.
		var plain = want.copy(), first:Null<String> = null;
		for (i in 0...want.length) switch (want[i]) {
			case LValueType(_, [t]) if (declared.args[i].opt && types.isNullOf(want[i])):
				plain[i] = t;
				if (first == null) first = declared.args[i].name;
			case _:
		}
		if (first != null) for (link in links) if (applicable(link, name, isStatic, plain, cf.params.length).length > 0)
			throw new Unsupported("leaving out the optional value-type argument " + first + " of an extern method", false);
		throw Unsupported.error("no .NET " + what + " takes " + given);
	}

	// The binding of `cf` to `m`, a method of `link`'s class, for a call that gives `given` arguments.
	// `checkReturn`: the declared return type must convert from `m`'s.
	function bound(c:TClass, cf:TClassField, link:{cls:IlClass, parent:IlSigNorm}, m:IlMethod, isStatic:Bool, given:Int,
			typeArgs:Null<Array<IlSigNorm>>, checkReturn:Bool):ExternMethod {
		var name = m.mname;
		if (checkReturn) {
			var declared = types.withParams(c.params, cf.params, () -> switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig): types.toSig(sig.ret);
				case _: throw "internal error: extern method " + cf.name + " has no function type";
			});
			var ret = open(m.mret.snorm, linkArgs(link), isStatic);
			if (typeArgs != null) ret = DotnetTypes.substitute(ret, [], typeArgs);
			if (!declared.match(LVoid) && !implicitlyConverts(ret, declared))
				throw Unsupported.error(typeS(c) + "." + name + " returns " + sigS(ret) + ", which does not convert to the declared " + sigS(declared));
		}
		var contract = m.mflags.contract;
		return {
			parent: link.parent,
			name: name,
			sig: m.msig.snorm,
			isStatic: isStatic,
			genericCount: m.mtypes.length,
			isVirtual: contract.indexOf(CMVirtual) >= 0 && contract.indexOf(CMFinal) < 0,
			omitted: m.margs.slice(given),
			typeArgs: typeArgs
		};
	}

	// The methods named `name` of `link`'s class, in metadata order, that a call with arguments of the
	// types `want` can bind: each argument converts implicitly to its parameter, and each parameter left
	// out has a default or is the params array. A generic method of another arity than the extern's
	// `typeParams` (which then has none) is one when the declared types give each type argument.
	function applicable(link:{cls:IlClass, parent:IlSigNorm}, name:String, isStatic:Bool, want:Array<IlSigNorm>,
			typeParams:Int):Array<{m:IlMethod, typeArgs:Null<Array<IlSigNorm>>}> {
		var args = linkArgs(link);
		var r = [];
		for (m in link.cls.cmethods) {
			if (m.mname != name || m.margs.length < want.length || !isAccessible(m)) continue;
			if ((m.mflags.contract.indexOf(CMStatic) >= 0) != isStatic) continue;
			var got = [for (a in m.margs) open(a.sig.snorm, args, isStatic)];
			var typeArgs:Null<Array<IlSigNorm>> = null;
			if (m.mtypes.length != typeParams) {
				if (typeParams != 0) continue;
				typeArgs = inferTypeArgs(m, got, want, args, isStatic);
				if (typeArgs == null) continue;
				got = [for (s in got) DotnetTypes.substitute(s, [], typeArgs)];
			}
			var ok = true;
			for (i in 0...got.length) if (i < want.length ? !implicitlyConverts(want[i], got[i]) : !canOmit(m.margs, i)) {
				ok = false;
				break;
			}
			if (ok) r.push({m: m, typeArgs: typeArgs});
		}
		return r;
	}

	// C# sees public and protected members from outside the assembly.
	static function isAccessible(m:IlMethod):Bool return m.mflags.access.match(FAPublic | FAFamily | FAFamOrAssem);

	// Whether a call may leave out the parameter `i` of `margs`: it has a default value, is [Optional], or
	// is the last one and a params array.
	static function canOmit(margs:Array<IlMethodArg>, i:Int):Bool {
		var a = margs[i];
		if (a.pdefault != null) return !a.pdefault.match(PParamArray) || i == margs.length - 1;
		return a.constant != null || a.flags.io.indexOf(POpt) >= 0;
	}

	// The type arguments of the generic method `m` that the declared argument types `want` give, as C#
	// infers them from arguments of those types: each type parameter meets one type wherever it occurs in
	// the given parameters `got`, and meets its constraints. Null when one is not given, meets two types
	// or fails a constraint.
	function inferTypeArgs(m:IlMethod, got:Array<IlSigNorm>, want:Array<IlSigNorm>, classArgs:Array<IlSigNorm>,
			isStatic:Bool):Null<Array<IlSigNorm>> {
		var bound:Array<Null<IlSigNorm>> = [for (_ in m.mtypes) null];
		var clash = false;
		function meet(g:IlSigNorm, w:IlSigNorm):Void {
			switch [g, w] {
				case [LMethodTypeParam(i), _] if (i < bound.length):
					if (bound[i] == null) bound[i] = w else if (!IlPaths.sigEq(bound[i], w)) clash = true;
				case [LManagedPointer(g1), LManagedPointer(w1)] | [LVector(g1), LVector(w1)]:
					meet(g1, w1);
				case [LClass(p1, l1), LClass(p2, l2)] | [LValueType(p1, l1), LValueType(p2, l2)] if (IlPaths.equals(p1, p2) && l1.length == l2.length):
					for (k in 0...l1.length) meet(l1[k], l2[k]);
				case _:
			}
		}
		for (i in 0...want.length) meet(got[i], want[i]);
		if (clash) return null;
		var r = [];
		for (b in bound) {
			if (b == null) return null;
			r.push(b);
		}
		for (k in 0...m.mtypes.length) {
			var tp = m.mtypes[k], t = r[k];
			var isValue = DotnetTypes.isValueType(t);
			if (tp.tflags.constraint.indexOf(CValueType) >= 0 && (!isValue || DotnetTypes.isSystemNullable(t))) return null;
			if (tp.tflags.constraint.indexOf(CInstanceType) >= 0 && isValue) return null;
			for (cst in tp.tconstraints)
				if (!implicitlyConverts(t, DotnetTypes.substitute(open(cst.snorm, classArgs, isStatic), [], r))) return null;
		}
		return r;
	}

	// System.Object, System.String and the primitives as signatures write them.
	static function norm(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LClass(p, []) | LValueType(p, []):
				var prim = DotnetTypes.primitive(p);
				prim != null ? prim : s;
			case _: s;
		}
	}

	// C#'s implicit numeric conversions, but those to decimal.
	static function widens(from:IlSigNorm, to:IlSigNorm):Bool {
		return switch (from) {
			case LInt8: to.match(LInt16 | LInt32 | LInt64 | LFloat32 | LFloat64);
			case LUInt8: to.match(LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64);
			case LInt16: to.match(LInt32 | LInt64 | LFloat32 | LFloat64);
			case LUInt16: to.match(LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64);
			case LChar: to.match(LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64);
			case LInt32: to.match(LInt64 | LFloat32 | LFloat64);
			case LUInt32: to.match(LInt64 | LUInt64 | LFloat32 | LFloat64);
			case LInt64 | LUInt64: to.match(LFloat32 | LFloat64);
			case LFloat32: to.match(LFloat64);
			case _: false;
		}
	}

	// Whether C# converts a `from` to a `to` implicitly, as ruling 1 counts it: identity, a reference
	// upcast along the metadata's superclasses and interfaces or to object, boxing (to object, or to a
	// superclass or interface of the value type: System.ValueType, System.Enum for an enum), the implicit
	// numeric conversions but those to decimal, and A to Nullable<A>. A by-reference type converts by
	// identity only. A type no referenced assembly defines has no supertypes but object.
	public function implicitlyConverts(from:IlSigNorm, to:IlSigNorm):Bool {
		from = norm(from);
		to = norm(to);
		if (IlPaths.sigEq(from, to)) return true;
		inline function opaque(s:IlSigNorm) return s.match(LVoid | LPointer(_) | LManagedPointer(_) | LTypedReference | LSentinel | LMethod(_, _, _));
		if (opaque(from) || opaque(to)) return false;
		if (widens(from, to)) return true;
		if (DotnetTypes.isSystemNullable(to)) return switch (to) {
			case LValueType(_, [a]): IlPaths.sigEq(from, norm(a));
			case _: false;
		}
		if (to.match(LObject)) return true;
		if (from.match(LTypeParam(_) | LMethodTypeParam(_)) || !to.match(LClass(_, _))) return false;
		var todo = [from], seen = new Map<String, Bool>();
		while (todo.length > 0) {
			for (sup in supertypes(todo.shift())) {
				var n = norm(sup);
				if (IlPaths.sigEq(n, to)) return true;
				var k = sigS(n);
				if (!seen.exists(k)) {
					seen.set(k, true);
					todo.push(n);
				}
			}
		}
		return false;
	}

	// The superclass and interfaces of `s`'s .NET type, with its type arguments applied; none for a type no
	// referenced assembly defines. An array's are System.Array's.
	function supertypes(s:IlSigNorm):Array<IlSigNorm> {
		var path:Null<IlPath> = null, args:Array<IlSigNorm> = [];
		switch (s) {
			case LClass(p, l) | LValueType(p, l):
				path = p;
				args = l;
			case LVector(_) | LArray(_, _):
				path = {ns: ["System"], nested: [], name: "Array"};
			case _:
				path = DotnetTypes.primitivePath(s);
		}
		if (path == null) return [];
		try {
			if (NetRefs.of(ctx).definer(path) == null) return [];
			var cls = rawClass(path);
			var r = [for (i in cls.cimplements) subst(i.snorm, args)];
			if (cls.csuper != null) r.unshift(subst(cls.csuper.snorm, args));
			return r;
		} catch (_:Unsupported) {
			return [];
		}
	}

	// The .NET type of `c`, as messages name it.
	function typeS(c:TClass):String return sigS(LClass(types.externPath(c), []));

	// A signature as C# writes the type, for messages.
	public static function sigS(s:IlSigNorm):String {
		return switch (s) {
			case LVoid: "void";
			case LBool: "bool";
			case LChar: "char";
			case LInt8: "sbyte";
			case LUInt8: "byte";
			case LInt16: "short";
			case LUInt16: "ushort";
			case LInt32: "int";
			case LUInt32: "uint";
			case LInt64: "long";
			case LUInt64: "ulong";
			case LFloat32: "float";
			case LFloat64: "double";
			case LString: "string";
			case LObject: "object";
			case LIntPtr: "nint";
			case LUIntPtr: "nuint";
			case LTypedReference: "System.TypedReference";
			case LPointer(t): sigS(t) + "*";
			case LManagedPointer(t): "ref " + sigS(t);
			case LVector(t): sigS(t) + "[]";
			case LArray(t, d): sigS(t) + "[" + [for (_ in 1...d.length) ","].join("") + "]";
			case LValueType(p, l) | LClass(p, l):
				var n = ~/`[0-9]+/g.replace(NetConverter.ilpathS(p), "");
				l.length == 0 ? n : n + "<" + [for (a in l) sigS(a)].join(", ") + ">";
			case LTypeParam(i): "!" + i;
			case LMethodTypeParam(i): "!!" + i;
			case LMethod(_, r, l): sigS(r) + "(" + [for (a in l) sigS(a)].join(", ") + ")";
			case LSentinel: "...";
		}
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

	// Whether the .NET struct `path`, a type of the referenced assemblies, declares a public instance
	// Equals(itself), which C# binds `x.Equals(y)` to before Object.Equals(object). False for a generic
	// struct, whose Equals(T) is not looked for.
	public function declaresSelfEquals(path:IlPath):Bool {
		if (NetRefs.of(ctx).definer(path) == null) return false;
		for (m in rawClass(path).cmethods) {
			if (m.mname != "Equals" || m.margs.length != 1 || m.mtypes.length != 0 || m.mflags.contract.indexOf(CMStatic) >= 0) continue;
			if (m.mflags.access == FAPublic && IlPaths.sigEq(m.margs[0].sig.snorm, LValueType(path, []))) return true;
		}
		return false;
	}

	// The literal a constructor of an extern .NET enum stands for, and the type the enum stores it as.
	public function enumLiteral(en:TEnum, ef:TEnumField):{c:IlConstant, underlying:IlSigNorm} {
		var path = types.externPathOf(TEnumDecl(en));
		var refs = NetRefs.of(ctx);
		if (refs.definer(path) == null) throw Unsupported.error(refs.missing(path));
		var underlying = enumUnderlying(path);
		if (underlying == null) throw Unsupported.error("the .NET type " + NetConverter.ilpathS(path) + " is not an enum");
		var name = DotnetNames.nativeName(ef.meta);
		if (name == null) name = ef.name;
		for (f in rawClass(path).cfields) if (f.fname == name && f.fconstant != null) return {c: f.fconstant, underlying: underlying};
		throw new Unsupported("the unknown .NET enum constant " + Globals.sTypePath(en.path) + "." + ef.name, false);
	}

	// The field or property of `c`'s .NET class that the extern variable `cf` stands for, which an access
	// `reads` or `writes` (both: by address). A hand-written extern's declared type must convert from the
	// member's for a read and to it for a write (ruling 1).
	public function field(c:TClass, cf:TClassField, reads = true, writes = false):ExternField {
		var name = memberName(cf);
		for (link in chain(c)) {
			for (f in link.cls.cfields) if (f.fname == name) {
				checkVar(c, cf, link, f.fsig.snorm, reads, writes);
				return f.fconstant != null ? XConstant(f.fconstant, f.fsig.snorm) : XField(f.fsig.snorm, f.fflags.contract.indexOf(CInitOnly) >= 0);
			}
			for (p in link.cls.cprops) if (p.pname == name) {
				var t = switch (p.psig.snorm) {
					case LMethod(_, ret, _): ret;
					case s: s;
				}
				checkVar(c, cf, link, t, reads, writes);
				return XProperty(t, p.pget == null ? null : p.pget.name, p.pset == null ? null : p.pset.name);
			}
		}
		throw new Unsupported("the unknown .NET field " + Globals.sTypePath(c.path) + "." + cf.name, false);
	}

	// Refuses an access to `link`'s member of the type `sig` through the hand-written extern variable `cf`
	// whose declared type does not convert as the access needs.
	function checkVar(c:TClass, cf:TClassField, link:{cls:IlClass, parent:IlSigNorm}, sig:IlSigNorm, reads:Bool, writes:Bool):Void {
		if (!isHandWritten(c)) return;
		var declared = types.withParams(c.params, [], () -> types.toSig(cf.type));
		var actual = open(sig, linkArgs(link), TypeFunctions.hasClassFieldFlag(cf, CfStatic));
		var what = typeS(c) + "." + memberName(cf);
		if (reads && !implicitlyConverts(actual, declared))
			throw Unsupported.error(what + " is of the type " + sigS(actual) + ", which does not convert to the declared " + sigS(declared));
		if (writes && !implicitlyConverts(declared, actual))
			throw Unsupported.error("the declared " + sigS(declared) + " does not convert to " + sigS(actual) + ", the type of " + what);
	}
}

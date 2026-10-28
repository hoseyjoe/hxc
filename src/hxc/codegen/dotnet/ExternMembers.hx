package hxc.codegen.dotnet;

import hxc.ast.Ast;
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

// The indexer C# picks for one int32 argument (`indexer`). `parent`: the .NET class declaring it, with the
// type arguments of the receiver's class applied. `indexSig` and `valueSig`: the property's parameter and
// type as the metadata declares them, in terms of `parent`'s type parameters, which a call site writes
// them as and `subst` with `parent`'s arguments gives the types they stand for. An accessor is null where
// the property has no public one.
typedef ExternIndexer = {
	parent:IlSigNorm,
	getter:Null<String>,
	setter:Null<String>,
	indexSig:IlSigNorm,
	valueSig:IlSigNorm
}

// A call site of an extern method, for ExternMembers.method: its arguments, their own types (null where
// a type is Dynamic or has no signature), the class whose code makes the call, and the type arguments of
// the extern class and of the extern method there (ruling I; `methodArgs` is empty when the method has
// none). `receiver`: for an instance call whose receiver's static type is an extern class below the one
// declaring the method, that class, where C# starts looking (ruling M), with its type arguments
// `receiverArgs`; the binding's `parent` is then in terms of its type parameters.
typedef ExternCall = {
	args:Array<TExpr>,
	argTypes:Array<Null<IlSigNorm>>,
	caller:Null<TClass>,
	classArgs:Array<IlSigNorm>,
	methodArgs:Array<IlSigNorm>,
	?receiver:TClass,
	?receiverArgs:Array<IlSigNorm>,
	?receiverStatic:TClass,
	?receiverOpaque:Bool
};

// An access to an extern variable, for ExternMembers.field (ruling Y): the class whose code makes it, the
// receiver's static class and opacity as in ExternCall (ruling R), and, for an instance access whose
// receiver's static type is an extern class below the one declaring the variable, that class, where C# starts
// looking, with its type arguments; `classArgs` are the declaring class's type arguments there.
typedef FieldSite = {
	caller:Null<TClass>,
	classArgs:Array<IlSigNorm>,
	?receiver:TClass,
	?receiverArgs:Array<IlSigNorm>,
	?receiverStatic:TClass,
	?receiverOpaque:Bool
};

// The member an access to an extern variable binds, and the .NET type declaring it (`parent`), in terms of the
// type parameters of the class the lookup starts at (the site's receiver, else the declaring extern class).
typedef BoundField = {member:ExternField, parent:IlSigNorm};

// The receiver of a call, for ruling R: its static class (null for `this`, `base` and a static call), or
// `opaque` for a type parameter, whose members protected access does not reach (C# starts from the
// constraint, and hxc emits the receiver as that constraint's erasure).
private typedef Receiver = {cls:Null<TClass>, opaque:Bool};

// What C# converts an argument by besides its type (ruling X), as gencs writes it: an integer constant, with
// its value where hxc can fold it, or the null literal (only where gencs writes `null`: into a reference type
// of an extern method that is not an @:overload one, whose arguments it casts). Inline C# gives them as C#
// does: an int constant and the null literal (CsToIl).
enum ArgKind {
	KPlain;
	KIntConst(value:Null<Int>);
	KNull;
}

// The type arguments a call gives the extern class's and the extern method's type parameters.
private typedef Inst = {cls:Array<IlSigNorm>, meth:Array<IlSigNorm>};

// Whether a call applies to a .NET method, where hxc's model of C#'s conversions can tell (ruling E).
private enum Applies {
	AYes;
	ANo;
	AUnknown;
}

// A method `resolve` binds: the index of its link in the chain and in that class's methods.
private typedef Bound = {link:Int, index:Int, typeArgs:Null<Array<IlSigNorm>>};

private enum Resolution {
	RBound(b:Bound);
	// More than one method applies.
	RAmbiguous;
	// Some method may apply, where hxc cannot tell; `candidates` methods apply or may apply.
	RUnknown(candidates:Int);
	RNone;
}

// The members of referenced assemblies that extern Haxe fields stand for, as those assemblies declare
// them. The typer already chose the overload; this only finds its definition.

class ExternMembers {
	final ctx:Context;
	final types:DotnetTypes;
	// Ruling J: what each Haxe-compiled type converts to (`conversionsOf`), by its signature's `sigKey`; null
	// for one hxc cannot list.
	final compiledConversionsCache = new Map<String, Null<Array<IlSigNorm>>>();
	// The program's own classes and interfaces by their CLR path's IlPaths.key (`compiledClass`).
	var compiledByPath:Null<Map<String, TClass>> = null;
	// The namespaces of the program's classes and interfaces, and those enclosing them, dotted.
	var compiledNamespaces:Null<Map<String, Bool>> = null;
	// Set when ruling X decides a conversion by an argument's value rather than its type, for the note a
	// refusal then carries (`byValueNote`).
	var byValue = false;

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

	// Whether the .NET class `c` stands for is a delegate type, one extending System.MulticastDelegate.
	public function isDelegate(c:TClass):Bool {
		var path = try types.externPath(c) catch (_:Unsupported) null;
		return path != null && NetRefs.of(ctx).definer(path) != null && isSystem(rawClass(path).csuper, "MulticastDelegate");
	}

	// The parameter and return types of the Invoke of the .NET delegate type `d`, with `d`'s type arguments
	// applied; null when `d` is not a delegate type with the `.ctor(object, native int)` that a delegate is
	// made with.
	public function delegateInvoke(d:IlSigNorm):Null<{args:Array<IlSigNorm>, ret:IlSigNorm}> {
		var path, args;
		switch (d) {
			case LClass(p, l):
				path = p;
				args = l;
			case _:
				return null;
		}
		if (NetRefs.of(ctx).definer(path) == null) return null;
		var cls = rawClass(path);
		if (!isSystem(cls.csuper, "MulticastDelegate")) return null;
		var ctor = false, invoke = null;
		for (m in cls.cmethods) {
			var isStatic = m.mflags.contract.indexOf(CMStatic) >= 0;
			if (m.mname == ".ctor" && !isStatic && IlPaths.sigsEq([for (a in m.margs) a.sig.snorm], [LObject, LIntPtr])) ctor = true;
			if (m.mname == "Invoke" && !isStatic && m.mtypes.length == 0) invoke = m;
		}
		if (!ctor || invoke == null) return null;
		return {args: [for (a in invoke.margs) subst(a.sig.snorm, args)], ret: subst(invoke.mret.snorm, args)};
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
		return chainFrom(path, [for (i in 0...rawClass(path).ctypes.length) LTypeParam(i)]);
	}

	// The supertypes of the .NET class `path` with the type arguments `args`, each with its parent signature
	// in terms of those arguments.
	function chainFrom(path:IlPath, args:Array<IlSigNorm>):Array<{cls:IlClass, parent:IlSigNorm}> {
		var cls = rawClass(path);
		var parent = LClass(path, args);
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

	// The method of `c`'s .NET class that the extern method `cf` stands for.
	// - A converted extern's member, or with `exactOnly` (an implementation or override, which takes the
	//   member's own signature), binds the method with exactly the declared signature, the first along
	//   the class chain.
	// - A hand-written extern's method binds as C# binds a call with the declared types, under the
	//   restricted rule of ruling 1 as rulings E and G amend it (`resolve`), walking from the receiver's
	//   class when the call gives one (ruling M). A call site passes `call`, whose arguments' own types
	//   must bind the same method (ruling F′) unless the extern method is an @:overload one, whose
	//   arguments gencs casts to the declared types; a generic method's type arguments are then theirs.
	//   Both bindings take the call's type arguments for the class's and the method's type parameters
	//   (ruling I), and convert an integer constant or a null literal argument by its value too (ruling X).
	//   Its return type must convert from the method's too.
	public function method(c:TClass, cf:TClassField, exactOnly = false, ?call:ExternCall):ExternMethod {
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
		if (exactOnly || !isHandWritten(c)) {
			for (link in links) {
				var args = linkArgs(link);
				for (m in link.cls.cmethods) {
					if (m.mname != name || m.margs.length != want.length || m.mtypes.length != cf.params.length) continue;
					if ((m.mflags.contract.indexOf(CMStatic) >= 0) != isStatic) continue;
					var got = [for (a in m.margs) open(a.sig.snorm, args, isStatic)];
					if (IlPaths.sigsEq(got, want)) return bound(c, cf, link, m, isStatic, want.length, null, false);
				}
			}
			throw new Unsupported("the .NET method " + Globals.sTypePath(c.path) + "." + cf.name + " with these argument types", false);
		}
		var caller = call == null ? null : call.caller;
		var receiverStatic:Null<Receiver> = call == null ? null : {cls: call.receiverStatic, opaque: call.receiverOpaque == true};
		// The call's type arguments for the declared types (`c`'s and the method's), and for the methods'
		// parameters (the receiver's class's when the walk starts there, ruling M).
		var inst:Null<Inst> = call == null ? null : {cls: call.classArgs, meth: call.methodArgs};
		var candInst = inst;
		var start = c;
		if (call != null && call.receiver != null && !isCtor && !isStatic) {
			start = call.receiver;
			links = chain(start);
			candInst = {cls: call.receiverArgs, meth: call.methodArgs};
		}
		if (inst != null) want = [for (s in want) DotnetTypes.substitute(s, inst.cls, inst.meth)];
		var overloaded = isOverloaded(c, cf, isStatic, isCtor);
		// Ruling X: integer constants and null literals as gencs writes them. It casts the arguments of an
		// @:overload extern to the declared types, which keeps a constant one and types a null; it writes a null
		// into a value type as default(T).
		var kinds:Null<Array<ArgKind>> = call == null ? null : [
			for (i in 0...want.length) {
				var k = i < call.args.length ? argKind(call.args[i]) : KPlain;
				k.match(KNull) && (overloaded || !takesNull(want[i])) ? KPlain : k;
			}
		];
		byValue = false;
		var what = isCtor ? "constructor of " + typeS(start) : "overload of " + typeS(start) + "." + name;
		inline function list(l:Array<IlSigNorm>) return "(" + [for (s in l) sigS(s)].join(", ") + ")";
		var found = switch (resolve(links, name, isStatic, want, cf.params.length, caller, receiverStatic, candInst, kinds)) {
			case RBound(b):
				b;
			case RAmbiguous:
				throw Unsupported.error("more than one .NET " + what + " accepts " + list(want) + byValueNote());
			case RUnknown(1):
				throw Unsupported.error("hxc cannot tell whether the .NET "
					+ (isCtor ? "constructor of " + typeS(start) : "method " + typeS(start) + "." + name) + " accepts " + list(want) + byValueNote());
			case RUnknown(_):
				throw Unsupported.error("more than one .NET " + what + " may accept " + list(want) + byValueNote());
			case RNone:
				ruling4(links, name, isStatic, want, declared, cf.params.length, caller, receiverStatic, call, candInst, kinds);
				throw Unsupported.error("no .NET " + what + " takes " + list(want));
		}
		if (call != null && !overloaded) {
			// Ruling K: a Haxe-compiled argument keeps its own type, which converts as ruling J says.
			var byArgs = [
				for (i in 0...want.length) {
					var s = i < call.argTypes.length ? call.argTypes[i] : null;
					// gencs unwraps or wraps a haxe.lang.Null<T> where the declared type is not one (a basic-typed
					// argument to a declared Null<T> included, ruling Q), and casts a basic-typed argument to
					// another declared basic type (ruling N).
					if (s == null || types.isNullOf(s) != types.isNullOf(want[i]) && (types.isNullOf(s) || isBasic(s))
						|| isBasic(s) && isBasic(want[i])) want[i] else s;
				}
			];
			if (!IlPaths.sigsEq(byArgs, want)) {
				// Ruling F′: both bind the same method; its type arguments are the arguments' own, as C# infers
				// them, and `bound` checks the return with them.
				byValue = false;
				switch (resolve(links, name, isStatic, byArgs, cf.params.length, caller, receiverStatic, candInst, kinds)) {
					case RBound(b) if (b.link == found.link && b.index == found.index):
						found = b;
					case _:
						throw Unsupported.error("the .NET " + what + " depends on the argument types " + list(byArgs)
							+ (byValue ? ", and " + byValueText : "; declare it with @:overload"));
				}
			}
		}
		var link = links[found.link];
		return bound(c, cf, link, link.cls.cmethods[found.index], isStatic, want.length, found.typeArgs, !isCtor, inst, candInst);
	}

	static final byValueText = "C# converts an integer constant or null argument by its value; declare the parameter's exact type, or use @:overload";

	// The note a refusal carries when ruling X decided a conversion by an argument's value.
	function byValueNote():String {
		return byValue ? " (" + byValueText + ")" : "";
	}

	// How C# sees the argument `e` besides its type (ruling X): the null literal, or an integer constant (an Int
	// literal, or a fold of them, through parentheses, metadata and casts).
	static function argKind(e:TExpr):ArgKind {
		if (isNull(e)) return KNull;
		var c = intConstant(e);
		return c == null ? KPlain : KIntConst(c.value);
	}

	// `e` as an integer constant, with its value where hxc can fold it (null otherwise), or null when it is
	// not one. Haxe's Int arithmetic wraps, as C#'s unchecked constants do.
	static function intConstant(e:TExpr):Null<{value:Null<Int>}> {
		return switch (e.expr) {
			case TConst(TInt(v)):
				{value: v};
			case TParenthesis(e1) | TMeta(_, e1) | TCast(e1, null):
				intConstant(e1);
			case TUnop(op = Neg | NegBits, Prefix, e1):
				var c = intConstant(e1);
				c == null ? null : {value: c.value == null ? null : op == Neg ? -c.value : ~c.value};
			case TBinop(op = OpAdd | OpSub | OpMult | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr, e1, e2):
				var a = intConstant(e1), b = intConstant(e2);
				if (a == null || b == null) return null;
				var r:Null<Int> = null;
				if (a.value != null && b.value != null) {
					var x:Int = a.value, y:Int = b.value;
					r = switch (op) {
						case OpAdd: x + y;
						case OpSub: x - y;
						case OpMult: x * y;
						case OpMod: y == 0 ? null : x % y;
						case OpAnd: x & y;
						case OpOr: x | y;
						case OpXor: x ^ y;
						case OpShl: x << (y & 31);
						case OpShr: x >> (y & 31);
						case _: x >>> (y & 31);
					}
				}
				var folded:{value:Null<Int>} = {value: r};
				folded;
			case _:
				null;
		}
	}

	// A type a null literal converts to in C#: a reference type, or System.Nullable<T>.
	static function takesNull(s:IlSigNorm):Bool {
		return switch (norm(s)) {
			case LObject | LString | LClass(_, _) | LVector(_) | LArray(_, _): true;
			case LValueType(_, _): DotnetTypes.isSystemNullable(s);
			case _: false;
		}
	}

	// Whether the argument of the kind `k`, of the type `from` in this binding, converts implicitly to `to`
	// (ruling X). An Int constant also converts to a narrower integral type it fits, and a 0 to an enum, which
	// hxc does not model: unknown (an Int constant gencs writes as it is, or casts to int). The null literal
	// converts to every reference type and Nullable<T>, and to no value type.
	function convertsArg(k:ArgKind, from:IlSigNorm, to:IlSigNorm):Applies {
		switch (k) {
			case KNull:
				byValue = true;
				return switch (norm(to)) {
					case _ if (takesNull(to)): AYes;
					case LPointer(_) | LTypeParam(_) | LMethodTypeParam(_): AUnknown;
					case _: ANo;
				}
			case KIntConst(v) if (norm(from).match(LInt32)):
				var t = norm(to);
				inline function fits(lo:Float, hi:Float) return v == null || v >= lo && v <= hi;
				var narrower = switch (t) {
					case LInt8: fits(-128, 127);
					case LUInt8: fits(0, 255);
					case LInt16: fits(-32768, 32767);
					case LUInt16: fits(0, 65535);
					case LUInt32 | LUInt64: fits(0, 2147483647);
					case _: null;
				}
				if (narrower != null) {
					if (!narrower) return ANo;
					byValue = true;
					return AUnknown;
				}
				var path = switch (t) {
					case LValueType(p, []): p;
					case _: null;
				}
				if ((v == null || v == 0) && path != null && enumUnderlying(path) != null) {
					byValue = true;
					return AUnknown;
				}
				return converts(from, to);
			case _:
				return converts(from, to);
		}
	}

	// A type gencs casts an argument to where the declared type is another one of them (ruling N): Bool, the
	// integers, Char and the floating-point types.
	static function isBasic(s:IlSigNorm):Bool {
		return norm(s).match(LBool | LChar | LInt8 | LUInt8 | LInt16 | LUInt16 | LInt32 | LUInt32 | LInt64 | LUInt64 | LFloat32 | LFloat64);
	}

	// Ruling O: a call through the extern interface `receiver` of the method `cf` that the extern interface
	// `c` declares, which `receiver` extends. Refused when a .NET interface between their .NET types (the
	// receiver's included, `c`'s not) declares a member of the same name (a method, property or event, any
	// of which hides the method in C#), where C#'s interface member
	// lookup, which hxc does not model, may bind another method. A converted `c`'s member was chosen by the
	// typer from the metadata.
	public function checkInterfaceReceiver(receiver:TClass, c:TClass, cf:TClassField):Void {
		if (!isHandWritten(c)) return;
		var name = memberName(cf);
		var target = types.externPath(c);
		var derives = new Map<String, Bool>();
		function reachesTarget(p:IlPath):Bool {
			var k = IlPaths.key(p);
			if (derives.exists(k)) return derives.get(k);
			derives.set(k, false);
			var r = IlPaths.equals(p, target);
			if (!r) for (i in rawClass(p).cimplements) switch (i.snorm) {
				case LClass(ip, _) if (isDefined(ip) && reachesTarget(ip)):
					r = true;
				case _:
			}
			derives.set(k, r);
			return r;
		}
		var seen = new Map<String, Bool>();
		function visit(p:IlPath):Void {
			if (IlPaths.equals(p, target) || seen.exists(IlPaths.key(p))) return;
			seen.set(IlPaths.key(p), true);
			var cls = rawClass(p);
			if (Lambda.exists(cls.cmethods, m -> m.mname == name) || Lambda.exists(cls.cprops, q -> q.pname == name)
				|| Lambda.exists(cls.cevents, e -> e.ename == name))
				throw Unsupported.error("the .NET method " + typeS(c) + "." + name + " is also declared on " + sigS(LClass(p, []))
					+ "; hxc does not model C#'s interface member lookup");
			for (i in cls.cimplements) switch (i.snorm) {
				case LClass(ip, _) if (isDefined(ip) && reachesTarget(ip)): visit(ip);
				case _:
			}
		}
		var start = types.externPath(receiver);
		if (isDefined(start) && reachesTarget(start)) visit(start);
	}

	// The program's class or interface whose CLR path is `p`, or null.
	public function compiledClass(p:IlPath):Null<TClass> {
		if (compiledByPath == null) {
			compiledByPath = new Map();
			compiledNamespaces = new Map();
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern) && !c.kind.match(KTypeParameter(_))):
					var path = DotnetNames.typePath(mt);
					var key = IlPaths.key(path);
					if (!compiledByPath.exists(key)) compiledByPath.set(key, c);
					for (k in 1...path.ns.length + 1) compiledNamespaces.set(path.ns.slice(0, k).join("."), true);
				case _:
			}
		}
		return compiledByPath.get(IlPaths.key(p));
	}

	// Whether a type of the program or of an assembly NetRefs reads is in the namespace `ns` or one inside it,
	// as C#'s name lookup sees namespaces (CsToIl).
	public function namespaceExists(ns:Array<String>):Bool {
		compiledClass({ns: [], nested: [], name: ""});
		return compiledNamespaces.exists(ns.join(".")) || NetRefs.of(ctx).namespaceExists(ns);
	}

	// Ruling J (as K amends it): the types the Haxe-compiled class or interface `s` converts to implicitly,
	// but object, computed once per type: those `compiledConversions` lists for its class, with `s`'s type
	// arguments for the class's type parameters. Null for a type hxc cannot list (no program class has its
	// path, or its arguments are not one per type parameter).
	function conversionsOf(s:IlSigNorm):Null<Array<IlSigNorm>> {
		var key = sigKey(s);
		if (compiledConversionsCache.exists(key)) return compiledConversionsCache.get(key);
		var r:Null<Array<IlSigNorm>> = switch (s) {
			case LClass(p, args) | LValueType(p, args):
				var c = compiledClass(p);
				if (c == null || args.length != c.params.length) null else {
					var own = types.withParams(c.params, [], () -> compiledConversions(c));
					own == null ? null : [for (t in own) DotnetTypes.substitute(t, args, [])];
				}
			case _: null;
		}
		compiledConversionsCache.set(key, r);
		return r;
	}

	// Ruling J: the types the Haxe-compiled class or interface `c0`, with its own type parameters, converts
	// to implicitly, but object: the classes of its Haxe superclass chain, itself included, and the
	// interfaces they implement, directly or through Haxe interfaces; each extern one with its .NET
	// supertypes; System.ValueType for a @:struct class (ruling K). Null when one has no signature.
	function compiledConversions(c0:TClass):Null<Array<IlSigNorm>> {
		var c = c0, params = [for (p in c0.params) p.type];
		var r = [], seen = new Map<String, Bool>();
		function add(s:IlSigNorm):Void {
			var todo = [norm(s)];
			while (todo.length > 0) {
				var n = todo.shift();
				var k = sigKey(n);
				if (seen.exists(k)) continue;
				seen.set(k, true);
				r.push(n);
				if (!isCompiled(n)) for (sup in supertypes(n)) todo.push(norm(sup));
			}
		}
		function addInterface(ic:TClass, iparams:Array<T>):Void {
			add(types.toSig(TInst(ic, iparams)));
			if (TypeFunctions.hasClassFlag(ic, CExtern)) return;
			for (i in ic.interfaces) addInterface(i.c, [for (p in i.params) TypeFunctions.applyParams(ic.params, iparams, p)]);
		}
		try {
			while (true) {
				add(types.toSig(TInst(c, params)));
				if (TypeFunctions.hasClassFlag(c, CExtern)) break;
				for (i in c.interfaces) addInterface(i.c, [for (p in i.params) TypeFunctions.applyParams(c.params, params, p)]);
				var sup = c.superClass;
				if (sup == null) break;
				var cparams = c.params, args = params;
				params = [for (p in sup.params) TypeFunctions.applyParams(cparams, args, p)];
				c = sup.c;
			}
		} catch (_:Unsupported) {
			return null;
		}
		if (TypeFunctions.hasMeta(":struct", c0.meta)) add(LClass({ns: ["System"], nested: [], name: "ValueType"}, []));
		return r;
	}

	// Whether the extern method is one of @:overload ones, which gencs calls with its arguments cast to
	// the declared types.
	static function isOverloaded(c:TClass, cf:TClassField, isStatic:Bool, isCtor:Bool):Bool {
		inline function overloaded(f:Null<TClassField>)
			return f != null && (f.overloads.length > 0 || TypeFunctions.hasClassFieldFlag(f, CfOverload) || TypeFunctions.hasMeta(":overload", f.meta));
		return overloaded(cf) || overloaded(isCtor ? c.constructor : isStatic ? c.statics.get(cf.name) : c.fields.get(cf.name));
	}

	// Ruling 4: a Haxe-optional value-type argument is a haxe.lang.Null<T>, which converts to no .NET
	// value type; gencs's C# fails there (CS1503). Refuses when the call would bind with such arguments
	// as their T; a null argument (what the typer pads a left-out one with) is left out.
	function ruling4(links:Array<{cls:IlClass, parent:IlSigNorm}>, name:String, isStatic:Bool, want:Array<IlSigNorm>,
			declared:TSignature, typeParams:Int, caller:Null<TClass>, receiverStatic:Null<Receiver>, call:Null<ExternCall>, inst:Null<Inst>,
			kinds:Null<Array<ArgKind>>):Void {
		var plain = want.copy(), first = -1;
		for (i in 0...want.length) switch (want[i]) {
			case LValueType(_, [t]) if (declared.args[i].opt && types.isNullOf(want[i])):
				plain[i] = t;
				if (first < 0) first = i;
			case _:
		}
		if (first < 0 || resolve(links, name, isStatic, plain, typeParams, caller, receiverStatic, inst, kinds).match(RNone)) return;
		var argName = declared.args[first].name;
		var given = call != null && first < call.args.length && !isNull(call.args[first]);
		if (given)
			throw Unsupported.error("the optional value-type argument " + argName + " of an extern method is passed as " + sigS(want[first])
				+ ", which the .NET method does not accept");
		throw Unsupported.error("leaving out the optional value-type argument " + argName + " of an extern method");
	}

	static function isNull(e:TExpr):Bool {
		return switch (e.expr) {
			case TConst(TNull): true;
			case TParenthesis(e1) | TMeta(_, e1): isNull(e1);
			case _: false;
		}
	}

	// Ruling G: the methods named `name` declared by each link of the chain, overrides left out, from the
	// most derived. In a link, the one exact match binds, else the one applicable method when no other
	// may apply (ruling E). A link where none applies or may apply passes to the next. `inst`: the call's
	// type arguments, which the methods' parameters take (ruling I). `kinds`: the arguments' kinds (ruling X).
	function resolve(links:Array<{cls:IlClass, parent:IlSigNorm}>, name:String, isStatic:Bool, want:Array<IlSigNorm>,
			typeParams:Int, caller:Null<TClass>, receiverStatic:Null<Receiver>, inst:Null<Inst>, ?kinds:Array<ArgKind>, closed = false):Resolution {
		for (li in 0...links.length) {
			var link = links[li];
			var exact = [], yes = [], unknown = 0;
			for (idx in 0...link.cls.cmethods.length) {
				var m = link.cls.cmethods[idx];
				if (m.mname != name || (m.mflags.contract.indexOf(CMStatic) >= 0) != isStatic || isOverride(m)) continue;
				var isProtected = switch (m.mflags.access) {
					case FAPublic: false;
					case FAFamily | FAFamOrAssem: true;
					case _: continue;
				}
				var a = applies(m, link, want, typeParams, isStatic, inst, kinds, closed);
				if (a.applies == ANo) continue;
				var b:Bound = {link: li, index: idx, typeArgs: a.typeArgs};
				if (isProtected && !protectedOk(caller, link.cls.cpath, receiverStatic, isStatic)) unknown++;
				else if (a.applies == AUnknown) unknown++;
				else {
					yes.push(b);
					if (a.exact) exact.push(b);
				}
			}
			if (exact.length == 1) return RBound(exact[0]);
			if (yes.length == 1 && unknown == 0) return RBound(yes[0]);
			if (unknown > 0) return RUnknown(unknown + yes.length);
			if (yes.length > 1) return RAmbiguous;
		}
		return RNone;
	}

	// An override, which C# looks for where the method was first declared.
	static function isOverride(m:IlMethod):Bool return overrides(m.mflags);

	static function overrides(flags:MethodFlags):Bool
		return flags.contract.indexOf(CMVirtual) >= 0 && flags.vtable.indexOf(VNewSlot) < 0;

	// Ruling R: whether a protected member of the .NET type `path` is accessible: `caller` derives from `path`,
	// and the receiver's static class is `caller` or derives from it (a static member has no receiver; a null
	// receiver, or a null class, is `this` or `base`; an opaque one, a type parameter, never is).
	function protectedOk(caller:Null<TClass>, path:IlPath, receiver:Null<Receiver>, isStatic:Bool):Bool {
		if (!callerReaches(caller, path)) return false;
		if (isStatic || receiver == null) return true;
		if (receiver.opaque) return false;
		var c = receiver.cls;
		if (c == null) return true;
		while (c != null) {
			if (c == caller) return true;
			c = c.superClass == null ? null : c.superClass.c;
		}
		return false;
	}

	// Whether `caller` derives from the .NET type `path`, which a protected member needs.
	function callerReaches(caller:Null<TClass>, path:IlPath):Bool {
		var s = caller == null ? null : caller.superClass;
		while (s != null) {
			if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
				try {
					for (link in chain(s.c)) if (IlPaths.equals(link.cls.cpath, path)) return true;
				} catch (_:Unsupported) {}
				return false;
			}
			s = s.c.superClass;
		}
		return false;
	}

	// Whether a call with arguments of the types `want` applies to `m`, a method of `link`'s class, in its
	// normal form: each argument converts implicitly to its parameter, and each parameter left out has a
	// default or is the params array. A generic method of another arity than the extern's `typeParams`
	// (which then has none) takes the type arguments the declared types give; one with a type argument
	// they do not give, or with a constraint, may apply when nothing else rules it out. So may one whose
	// params array's expanded form could take the arguments. `exact`: the parameters are `want`. `inst`:
	// the call's type arguments, which the parameters take (those of the method's own type parameters
	// when the extern method has them). `kinds`: the arguments' kinds, by which C# also converts an integer
	// constant or a null literal (ruling X); a null literal is never an exact match, and gives no type argument.
	// `closed`: the links' type arguments are the receiver's own (inline C#, `bindCs`), which a static
	// method's parameters take too, rather than the converter's erasure.
	function applies(m:IlMethod, link:{cls:IlClass, parent:IlSigNorm}, want:Array<IlSigNorm>, typeParams:Int, isStatic:Bool,
			inst:Null<Inst>, kinds:Null<Array<ArgKind>>, closed = false):{applies:Applies, typeArgs:Null<Array<IlSigNorm>>, exact:Bool} {
		var no = {applies: ANo, typeArgs: null, exact: false};
		inline function kind(i:Int) return kinds == null || i >= kinds.length ? KPlain : kinds[i];
		var args = linkArgs(link);
		var n = m.margs.length;
		var params = n > 0 && m.margs[n - 1].pdefault != null && m.margs[n - 1].pdefault.match(PParamArray);
		if (want.length > n && !params) return no;
		for (i in want.length...n) if (!canOmit(m.margs, i)) return no;
		var got = [for (a in m.margs) instantiate(open(a.sig.snorm, args, isStatic && !closed), inst, m.mtypes.length == typeParams)];
		var typeArgs:Null<Array<IlSigNorm>> = null;
		var result = AYes;
		if (m.mtypes.length != typeParams) {
			if (typeParams != 0) return no;
			typeArgs = inferTypeArgs(m, got, [for (i in 0...want.length) kind(i).match(KNull) ? null : want[i]]);
			if (typeArgs == null) {
				// Positions without the method's type parameters may still rule it out.
				for (i in 0...want.length)
					if (i < n && !hasMethodParam(got[i]) && convertsArg(kind(i), want[i], got[i]) == ANo) return no;
				return {applies: AUnknown, typeArgs: null, exact: false};
			}
			got = [for (s in got) DotnetTypes.substitute(s, [], typeArgs)];
		}
		for (i in 0...want.length) {
			var a = i < n ? convertsArg(kind(i), want[i], got[i]) : ANo;
			if (a == ANo) {
				result = ANo;
				break;
			}
			if (a == AUnknown) result = AUnknown;
		}
		if (result != AYes && params && want.length >= n - 1) {
			// The expanded form: the arguments past the fixed parameters go into the params array.
			var elem = switch (got[n - 1]) {
				case LVector(t): t;
				case _: null;
			}
			var possible = elem != null;
			for (i in 0...want.length) if (possible && convertsArg(kind(i), want[i], i < n - 1 ? got[i] : elem) == ANo) possible = false;
			if (possible) result = AUnknown;
		}
		if (result == ANo) return no;
		var exact = result == AYes && typeArgs == null && want.length == n && IlPaths.sigsEq(got, want)
			&& !Lambda.exists([for (i in 0...want.length) i], i -> kind(i).match(KNull));
		return {applies: result, typeArgs: typeArgs, exact: exact};
	}

	// `s` with the call's type arguments `inst`, the method's own ones when `withMethod`.
	static function instantiate(s:IlSigNorm, inst:Null<Inst>, withMethod:Bool):IlSigNorm {
		return inst == null ? s : DotnetTypes.substitute(s, inst.cls, withMethod ? inst.meth : []);
	}

	static function hasMethodParam(s:IlSigNorm):Bool {
		return switch (s) {
			case LMethodTypeParam(_): true;
			case LPointer(t) | LManagedPointer(t) | LVector(t) | LArray(t, _): hasMethodParam(t);
			case LValueType(_, l) | LClass(_, l): Lambda.exists(l, hasMethodParam);
			case LMethod(_, r, l): hasMethodParam(r) || Lambda.exists(l, hasMethodParam);
			case _: false;
		}
	}

	// Whether a call may leave out the parameter `i` of `margs`: it has a default value, is [Optional], or
	// is the last one and a params array. A ref or out parameter never is.
	static function canOmit(margs:Array<IlMethodArg>, i:Int):Bool {
		var a = margs[i];
		if (a.sig.snorm.match(LManagedPointer(_))) return false;
		if (a.pdefault != null) return !a.pdefault.match(PParamArray) || i == margs.length - 1;
		return a.constant != null || a.flags.io.indexOf(POpt) >= 0;
	}

	// The type arguments of the generic method `m` that the declared argument types `want` give (a null one, a
	// null literal's, gives none, as in C#): each type
	// parameter meets one type wherever it occurs in the given parameters `got`. Null when one is not
	// given or meets two types, or when one is constrained, which this does not check (ruling E).
	function inferTypeArgs(m:IlMethod, got:Array<IlSigNorm>, want:Array<Null<IlSigNorm>>):Null<Array<IlSigNorm>> {
		for (tp in m.mtypes) if (tp.tflags.constraint.length > 0 || tp.tconstraints.length > 0) return null;
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
		for (i in 0...want.length) if (i < got.length && want[i] != null) meet(got[i], want[i]);
		if (clash) return null;
		var r = [];
		for (b in bound) {
			if (b == null) return null;
			r.push(b);
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

	// C#'s implicit numeric conversions between the primitives (decimal and nint/nuint are left to
	// `converts`).
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

	// Whether C# converts a `from` to a `to` implicitly, as `converts` decides it for certain.
	public function implicitlyConverts(from:IlSigNorm, to:IlSigNorm):Bool return converts(from, to) == AYes;

	static function isSystemNamed(s:IlSigNorm, name:String):Bool {
		return switch (s) {
			case LClass(p, _) | LValueType(p, _): p.nested.length == 0 && p.name == name && IlPaths.strsEq(p.ns, ["System"]);
			case _: false;
		}
	}

	// Whether C# converts a `from` to a `to` implicitly (ruling 1, with ruling E's unknowns): yes for
	// identity, a reference upcast along the metadata's superclasses and interfaces, anything to object,
	// boxing to a superclass or interface of the value type, the implicit numeric conversions between
	// primitives, and A to Nullable<A>; a Haxe-compiled class as ruling J says. Unknown where hxc does
	// not model C#'s rules: Span and ReadOnlySpan, decimal, nint and nuint, Nullable<B> from another type,
	// a type declaring op_Implicit, an array to a generic interface or another array, and a variant
	// generic target. A by-reference type converts by identity only.
	function converts(from:IlSigNorm, to:IlSigNorm):Applies {
		from = norm(from);
		to = norm(to);
		if (IlPaths.sigEq(from, to)) return AYes;
		inline function opaque(s:IlSigNorm) return s.match(LVoid | LPointer(_) | LManagedPointer(_) | LTypedReference | LSentinel | LMethod(_, _, _));
		if (opaque(from) || opaque(to)) return ANo;
		inline function span(s:IlSigNorm) return isSystemNamed(s, "Span`1") || isSystemNamed(s, "ReadOnlySpan`1");
		if (isCompiled(from)) {
			// Rulings J and K; unknown where hxc cannot list the type's conversions, and for a variant
			// generic interface or delegate it does not list (ruling L).
			if (to.match(LObject)) return AYes;
			if (DotnetTypes.isSystemNullable(to)) return switch (to) {
				case LValueType(_, [a]) if (IlPaths.sigEq(from, a)): AYes;
				case _: ANo;
			}
			var supers = conversionsOf(from);
			if (supers == null) return AUnknown;
			for (sup in supers) if (IlPaths.sigEq(sup, to)) return AYes;
			// A Haxe-compiled class never derives from a delegate type, variant or not.
			return isVariant(to) && !isDelegateType(to) ? AUnknown : ANo;
		}
		if (span(from) || span(to)) return AUnknown;
		if (to.match(LObject)) return AYes;
		inline function unmodelled(s:IlSigNorm) return s.match(LIntPtr | LUIntPtr) || isSystemNamed(s, "Decimal");
		if (unmodelled(from) || unmodelled(to)) return AUnknown;
		if (widens(from, to)) return AYes;
		if (DotnetTypes.isSystemNullable(to)) return switch (to) {
			case LValueType(_, [a]) if (IlPaths.sigEq(from, norm(a))): AYes;
			case _: AUnknown;
		}
		if (from.match(LTypeParam(_) | LMethodTypeParam(_))) return ANo;
		var r = ANo;
		switch (from) {
			case LVector(_) | LArray(_, _):
				switch (to) {
					case LVector(_) | LArray(_, _):
						return AUnknown;
					case LClass(_, l) if (l.length > 0):
						return AUnknown;
					case _:
				}
			case _:
		}
		if (to.match(LClass(_, _)) && reaches(from, to)) return AYes;
		if (isVariant(to) || declaresImplicit(from) || declaresImplicit(to)) return AUnknown;
		return r;
	}

	// A type of the program being compiled (no referenced assembly defines it), but haxe.lang.Null<T>.
	function isCompiled(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, _) | LValueType(p, _): !types.isNullOf(s) && !isDefined(p);
			case _: false;
		}
	}

	function isDefined(p:IlPath):Bool {
		return try NetRefs.of(ctx).definer(p) != null catch (_:Unsupported) false;
	}

	// Whether the metadata's superclasses and interfaces of `from` reach `to`.
	function reaches(from:IlSigNorm, to:IlSigNorm):Bool {
		var todo = [from], seen = new Map<String, Bool>();
		while (todo.length > 0) {
			for (sup in supertypes(todo.shift())) {
				var n = norm(sup);
				if (IlPaths.sigEq(n, to)) return true;
				var k = sigKey(n);
				if (!seen.exists(k)) {
					seen.set(k, true);
					todo.push(n);
				}
			}
		}
		return false;
	}

	// Whether `s` is an interface: a Haxe-compiled one, or a .NET one by its metadata.
	public function isInterface(s:IlSigNorm):Bool {
		switch (s) {
			case LClass(p, _):
				var c = compiledClass(p);
				if (c != null) return TypeFunctions.hasClassFlag(c, CInterface);
			case _:
				return false;
		}
		var cls = classOf(s);
		return cls != null && cls.cflags.semantics.indexOf(SInterface) >= 0;
	}

	// The .NET class of `s`, or null for one no referenced assembly defines.
	function classOf(s:IlSigNorm):Null<IlClass> {
		var path = switch (s) {
			case LClass(p, _) | LValueType(p, _): p;
			case LVector(_) | LArray(_, _): ({ns: ["System"], nested: [], name: "Array"} : IlPath);
			case _: DotnetTypes.primitivePath(s);
		}
		if (path == null || !isDefined(path)) return null;
		return try rawClass(path) catch (_:Unsupported) null;
	}

	// Whether `s` is a .NET delegate type, one extending System.MulticastDelegate.
	function isDelegateType(s:IlSigNorm):Bool {
		var cls = classOf(s);
		return cls != null && isSystem(cls.csuper, "MulticastDelegate");
	}

	// A generic interface or delegate with a variant type parameter.
	function isVariant(s:IlSigNorm):Bool {
		switch (s) {
			case LClass(_, l) if (l.length > 0):
			case _: return false;
		}
		var cls = classOf(s);
		if (cls == null) return false;
		for (tp in cls.ctypes) if (tp.tflags.variance != VNone) return true;
		return false;
	}

	// Whether `s`'s .NET class or a superclass declares a user-defined implicit conversion.
	function declaresImplicit(s:IlSigNorm):Bool {
		var cls = classOf(s);
		for (_ in 0...64) {
			if (cls == null) return false;
			for (m in cls.cmethods) if (m.mname == "op_Implicit") return true;
			if (cls.csuper == null) return false;
			cls = classOf(cls.csuper.snorm);
		}
		return false;
	}

	// The user-defined conversion (`T.op_Implicit` or, with `explicit`, `T.op_Explicit` too) that `s`'s .NET
	// class or a superclass declares, as messages name it; null when there is none. Decimal's are left out:
	// inline C# applies them itself (CsToIl).
	public function userConversion(s:IlSigNorm, explicit:Bool):Null<String> {
		if (isSystemNamed(s, "Decimal")) return null;
		var cls = classOf(s);
		var names = explicit ? ["op_Implicit", "op_Explicit"] : ["op_Implicit"];
		for (_ in 0...64) {
			if (cls == null) return null;
			for (name in names)
				for (m in cls.cmethods) if (m.mname == name) return sigS(LClass(cls.cpath, [])) + "." + name;
			if (cls.csuper == null) return null;
			cls = classOf(cls.csuper.snorm);
		}
		return null;
	}

	// The superclass and interfaces of `s`'s .NET type, with its type arguments applied; none for a type no
	// referenced assembly defines. An array's are System.Array's.
	function supertypes(s:IlSigNorm):Array<IlSigNorm> {
		var cls = classOf(s);
		if (cls == null) return [];
		var args = switch (s) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		var r = [for (i in cls.cimplements) subst(i.snorm, args)];
		if (cls.csuper != null) r.unshift(subst(cls.csuper.snorm, args));
		return r;
	}

	// The binding of `cf` to `m`, a method of `link`'s class, for a call that gives `given` arguments.
	// `checkReturn`: the declared return type, with the call's type arguments `inst`, must convert from
	// `m`'s, with `candInst` (the receiver's class's, ruling M) and `typeArgs`.
	function bound(c:TClass, cf:TClassField, link:{cls:IlClass, parent:IlSigNorm}, m:IlMethod, isStatic:Bool, given:Int,
			typeArgs:Null<Array<IlSigNorm>>, checkReturn:Bool, ?inst:Inst, ?candInst:Inst):ExternMethod {
		var name = m.mname;
		if (checkReturn) {
			var declared = instantiate(types.withParams(c.params, cf.params, () -> switch (TypeFunctions.follow(cf.type)) {
				case TFun(sig): types.toSig(sig.ret);
				case _: throw "internal error: extern method " + cf.name + " has no function type";
			}), inst, true);
			var ret = instantiate(open(m.mret.snorm, linkArgs(link), isStatic), candInst, m.mtypes.length == cf.params.length);
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

	// The .NET type of `c`, as messages name it.
	function typeS(c:TClass):String return sigS(LClass(types.externPath(c), []));

	// A signature as a key that tells every two types apart, generic arity and nesting included, unlike `sigS`.
	static function sigKey(s:IlSigNorm):String {
		inline function all(l:Array<IlSigNorm>) return "<" + [for (a in l) sigKey(a)].join(",") + ">";
		return switch (s) {
			case LClass(p, l): "c" + IlPaths.key(p) + all(l);
			case LValueType(p, l): "v" + IlPaths.key(p) + all(l);
			case LPointer(t): "*" + sigKey(t);
			case LManagedPointer(t): "&" + sigKey(t);
			case LVector(t): "[]" + sigKey(t);
			case LArray(t, d): "[" + [for (b in d) b.lower + ":" + b.size].join(",") + "]" + sigKey(t);
			case LMethod(_, r, l): "m" + sigKey(r) + all(l);
			case _: sigS(s);
		}
	}

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

	// Whether the method the CLR finds for an interface method named `name` of the signature `sig` (an
	// LMethod), walking `c`'s .NET class and its base classes with `classArgs` for `c`'s type parameters, is a
	// public virtual one: the first instance method of that name and signature decides it, as C# binds the
	// inherited member there and needs no forwarding stub only when the CLR maps the interface method to it.
	public function inheritsVirtual(c:TClass, classArgs:Array<IlSigNorm>, name:String, sig:IlSigNorm):Bool {
		return inheritedMethod(c, classArgs, name, sig) == true;
	}

	// inheritsVirtual's walk: null when no instance method of that name and signature is found, else whether
	// the first one found is public virtual.
	public function inheritedMethod(c:TClass, classArgs:Array<IlSigNorm>, name:String, sig:IlSigNorm):Null<Bool> {
		var want = switch (sig) {
			case LMethod(_, r, l): {ret: r, args: l};
			case _: throw "internal error: not a method signature";
		}
		for (link in chain(c)) {
			var args = [for (a in linkArgs(link)) subst(a, classArgs)];
			for (m in link.cls.cmethods) {
				if (m.mname != name || m.mtypes.length != 0 || m.margs.length != want.args.length) continue;
				if (m.mflags.contract.indexOf(CMStatic) >= 0) continue;
				if (!IlPaths.sigEq(subst(m.mret.snorm, args), want.ret)) continue;
				if (!IlPaths.sigsEq([for (a in m.margs) subst(a.sig.snorm, args)], want.args)) continue;
				return m.mflags.access == FAPublic && m.mflags.contract.indexOf(CMVirtual) >= 0;
			}
		}
		return null;
	}

	// The field or property of `c`'s .NET class that the extern variable `cf` stands for, which an access
	// `reads` or `writes` (both: by address), as C# looks it up (ruling Y): from the receiver's class when the
	// `site` gives one, through the public members and the protected ones ruling R makes accessible. A
	// protected one it does not is refused, as C# looks further up there. An accessor that is not accessible
	// is left out. A hand-written extern's declared type must convert from the member's for a read and to it
	// for a write (ruling 1).
	public function field(c:TClass, cf:TClassField, reads = true, writes = false, ?site:FieldSite):BoundField {
		var name = memberName(cf);
		var start = site != null && site.receiver != null && !TypeFunctions.hasClassFieldFlag(cf, CfStatic) ? site.receiver : c;
		var caller = site == null ? null : site.caller;
		var receiver:Receiver = {cls: site == null ? null : site.receiverStatic, opaque: site != null && site.receiverOpaque == true};
		var inst = start == c ? null : {cls: site.classArgs, start: site.receiverArgs};
		// Whether a member of `link` with the access `a` is visible: true when it is, false for a protected one
		// that ruling R does not reach, null for one C# never sees from another assembly.
		function visible(a:FieldAccess, link:{cls:IlClass, parent:IlSigNorm}, isStatic:Bool):Null<Bool> {
			return switch (a) {
				case FAPublic: true;
				case FAFamily | FAFamOrAssem: protectedOk(caller, link.cls.cpath, receiver, isStatic);
				case _: null;
			}
		}
		function inaccessible(link:{cls:IlClass, parent:IlSigNorm}):Unsupported {
			return Unsupported.error("hxc cannot tell whether the protected .NET member " + sigS(LClass(link.cls.cpath, [])) + "." + name
				+ " is accessible here");
		}
		for (link in chain(start)) {
			for (f in link.cls.cfields) if (f.fname == name) {
				var isStatic = f.fflags.contract.indexOf(CStatic) >= 0;
				switch (visible(f.fflags.access, link, isStatic)) {
					case null: continue;
					case false: throw inaccessible(link);
					case true:
				}
				checkVar(c, cf, link, f.fsig.snorm, isStatic, reads, writes, inst);
				var member = f.fconstant != null ? XConstant(f.fconstant, f.fsig.snorm) : XField(f.fsig.snorm, f.fflags.contract.indexOf(CInitOnly) >= 0);
				return {member: member, parent: link.parent};
			}
			for (p in link.cls.cprops) if (p.pname == name) {
				var t = switch (p.psig.snorm) {
					case LMethod(_, ret, _): ret;
					case s: s;
				}
				var acc = p.pget != null ? p.pget : p.pset;
				var isStatic = acc != null && acc.flags.contract.indexOf(CMStatic) >= 0;
				// A property is as accessible as its most accessible accessor.
				var getter = p.pget == null ? null : visible(p.pget.flags.access, link, isStatic);
				var setter = p.pset == null ? null : visible(p.pset.flags.access, link, isStatic);
				if (getter == null && setter == null) continue;
				if (getter != true && setter != true) throw inaccessible(link);
				checkVar(c, cf, link, t, isStatic, reads, writes, inst);
				return {member: XProperty(t, getter == true ? p.pget.name : null, setter == true ? p.pset.name : null), parent: link.parent};
			}
		}
		throw new Unsupported("the unknown .NET field " + Globals.sTypePath(c.path) + "." + cf.name, false);
	}

	// The class's DefaultMemberAttribute name, which C# gives every class that declares an indexer, or null.
	static function defaultMember(cls:IlClass):Null<String> {
		for (a in cls.cattrs) {
			var t = IlMetaTools.attrType(a);
			if (t == null || t.name != "DefaultMemberAttribute" || !IlPaths.strsEq(t.ns, ["System", "Reflection"]) || a.value == null) continue;
			switch (a.value.fixed) {
				case [InstConstant(IString(b))]: return b.toString();
				case _:
			}
		}
		return null;
	}

	// The indexer of `c`'s .NET class that C# picks for `x[i]` with an int32 `i` (values notes §3): walking
	// the chain from `c`, the first class that declares an accessible one-parameter indexer (a property of its
	// DefaultMemberAttribute's name, which leaves out the explicit interface implementations, named by the
	// interface, and the overrides, which C# looks for where the base declared them) that int32 converts to;
	// there the one with an int32 parameter, else the one such. Null when no class has one. Refused when hxc
	// cannot tell which applies, or when more than one does, rather than picking by chance (as `resolve` does
	// for methods). A protected one is accessible to a `caller` below its class through a `receiver` of the caller's
	// type or below it (`protectedOk`, ruling R), and may apply otherwise. `params`: `c`'s type arguments. `index`:
	// the index expression, an integer constant of which C# also converts by its value (ruling X).
	public function indexer(c:TClass, params:Array<T>, ?caller:TClass, ?receiver:TClass, ?index:TExpr):Null<ExternIndexer> {
		var args = types.classArgs(c, params);
		var kind = index == null || isNull(index) ? KPlain : argKind(index);
		byValue = false;
		for (link in chain(c)) {
			var name = defaultMember(link.cls);
			if (name == null) continue;
			var parentArgs = [for (a in linkArgs(link)) subst(a, args)];
			var exact = [], yes = [], unknown = 0;
			for (p in link.cls.cprops) {
				if (p.pname != name) continue;
				var sigs = switch (p.psig.snorm) {
					case LMethod(_, ret, [idx]): {ret: ret, idx: idx};
					case _: continue;
				}
				var first = p.pget != null ? p.pget : p.pset;
				if (first == null || first.flags.contract.indexOf(CMStatic) >= 0 || overrides(first.flags)) continue;
				var hidden = false;
				function accessible(a:Null<IlAccessor>):Null<String> {
					if (a == null) return null;
					return switch (a.flags.access) {
						case FAPublic:
							a.name;
						case FAFamily | FAFamOrAssem if (protectedOk(caller, link.cls.cpath, {cls: receiver, opaque: false}, false)):
							a.name;
						case FAFamily | FAFamOrAssem:
							hidden = true;
							null;
						case _:
							null;
					}
				}
				var getter = accessible(p.pget), setter = accessible(p.pset);
				if (getter == null && setter == null) {
					if (hidden) unknown++;
					continue;
				}
				var param = subst(sigs.idx, parentArgs);
				var found:ExternIndexer = {
					parent: switch (link.parent) {
						case LClass(path, _): LClass(path, parentArgs);
						case LValueType(path, _): LValueType(path, parentArgs);
						case s: s;
					},
					getter: getter,
					setter: setter,
					indexSig: sigs.idx,
					valueSig: sigs.ret
				};
				switch (convertsArg(kind, LInt32, param)) {
					case AYes:
						yes.push(found);
						if (IlPaths.sigEq(norm(param), LInt32)) exact.push(found);
					case AUnknown:
						unknown++;
					case ANo:
				}
			}
			var where = sigS(LClass(link.cls.cpath, []));
			if (exact.length == 1) return exact[0];
			if (yes.length == 1 && unknown == 0) return yes[0];
			var note = byValue ? " (C# converts an integer constant index by its value; index with a variable)" : "";
			if (unknown > 0) throw Unsupported.error("hxc cannot tell which .NET indexer of " + where + " an int argument selects" + note);
			if (yes.length > 1) throw Unsupported.error("more than one .NET indexer of " + where + " accepts an int argument" + note);
		}
		return null;
	}

	// Refuses an access to an element of the type `value` (substituted) through `c`'s indexer, as an element
	// of the Haxe type `declared` (a hand-written extern's ArrayAccess, or the typer's from the first
	// one-parameter property of a converted one, which may not be the indexer C# picks), when it does not
	// convert as the access needs (ruling 1, as `checkVar` does for a variable).
	public function checkIndexerElement(c:TClass, value:IlSigNorm, declared:IlSigNorm, reads:Bool, writes:Bool):Void {
		if (reads && !implicitlyConverts(value, declared))
			throw Unsupported.error("the .NET indexer of " + typeS(c) + " is of the type " + sigS(value) + ", which does not convert to the declared "
				+ sigS(declared));
		if (writes && !implicitlyConverts(declared, value))
			throw Unsupported.error("the declared " + sigS(declared) + " does not convert to " + sigS(value) + ", the type of the .NET indexer of "
				+ typeS(c));
	}

	// Refuses an access to `link`'s member of the type `sig` (static or not, `isStatic`) through the
	// hand-written extern variable `cf` that declares it the other way, or whose declared type does not
	// convert as the access needs. `inst`: where the lookup started below `c` (ruling Y), the type arguments
	// of `c` and of that class at the access, which the declared type and the member's take.
	function checkVar(c:TClass, cf:TClassField, link:{cls:IlClass, parent:IlSigNorm}, sig:IlSigNorm, isStatic:Bool, reads:Bool,
			writes:Bool, inst:Null<{cls:Array<IlSigNorm>, start:Array<IlSigNorm>}>):Void {
		if (!isHandWritten(c)) return;
		var what = typeS(c) + "." + memberName(cf);
		var declaredStatic = TypeFunctions.hasClassFieldFlag(cf, CfStatic);
		if (declaredStatic != isStatic)
			throw Unsupported.error(what + " is " + (isStatic ? "a static" : "an instance") + " member, which the extern declares as "
				+ (isStatic ? "an instance" : "a static") + " variable");
		var declared = types.withParams(c.params, [], () -> types.toSig(cf.type));
		var actual = open(sig, linkArgs(link), isStatic);
		if (inst != null) {
			declared = subst(declared, inst.cls);
			actual = subst(actual, inst.start);
		}
		if (reads && !implicitlyConverts(actual, declared))
			throw Unsupported.error(what + " is of the type " + sigS(actual) + ", which does not convert to the declared " + sigS(declared));
		if (writes && !implicitlyConverts(declared, actual))
			throw Unsupported.error("the declared " + sigS(declared) + " does not convert to " + sigS(actual) + ", the type of " + what);
	}

	// ---- inline C# (CsToIl): members of CLR types, looked up as C# looks them up

	// The .NET class and type arguments the member lookup on a receiver of the type `s` starts at: its own,
	// System's for a primitive, System.Array's for an array. Null for a type that has none here (a type
	// parameter, a pointer, void).
	static function lookupStart(s:IlSigNorm):Null<{path:IlPath, args:Array<IlSigNorm>}> {
		return switch (s) {
			case LClass(p, l) | LValueType(p, l): {path: p, args: l};
			case LVector(_) | LArray(_, _): {path: {ns: ["System"], nested: [], name: "Array"}, args: []};
			case _:
				var p = DotnetTypes.primitivePath(s);
				p == null ? null : {path: p, args: []};
		}
	}

	// The classes the lookup of the member `name` on a receiver of the type `recv` walks, from its class up.
	// For an interface, C#'s interface member lookup: the one interface, of `recv`'s and those it extends
	// (transitively), that declares a member of that name, else Object's members; refused where several do,
	// as hxc does not model which hides which (4a's ruling O).
	function csChain(recv:IlSigNorm, ?name:String):Array<{cls:IlClass, parent:IlSigNorm}> {
		var start = lookupStart(recv);
		if (start == null) throw new Unsupported("members of " + sigS(recv) + " in inline C#", true);
		var cls = rawClass(start.path);
		if (name == null || cls.cflags.semantics.indexOf(SInterface) < 0) return chainFrom(start.path, start.args);
		var todo = [{cls: cls, parent: LClass(start.path, start.args)}], seen = new Map<String, Bool>(), declaring = [];
		while (todo.length > 0) {
			var link = todo.shift();
			var k = sigKey(link.parent);
			if (seen.exists(k)) continue;
			seen.set(k, true);
			var c = link.cls;
			if (Lambda.exists(c.cmethods, m -> m.mname == name) || Lambda.exists(c.cprops, p -> p.pname == name)
				|| Lambda.exists(c.cfields, f -> f.fname == name) || Lambda.exists(c.cevents, e -> e.ename == name))
				declaring.push(link);
			for (i in c.cimplements) switch (subst(i.snorm, linkArgs(link))) {
				case LClass(p, l) if (isDefined(p)): todo.push({cls: rawClass(p), parent: LClass(p, l)});
				case _:
			}
		}
		if (declaring.length > 1)
			throw Unsupported.error("the .NET member " + sigS(recv) + "." + name + " is declared on " + sigS(declaring[0].parent) + " and on "
				+ sigS(declaring[1].parent) + "; hxc does not model C#'s interface member lookup");
		if (declaring.length == 1) return declaring;
		return chainFrom({ns: ["System"], nested: [], name: "Object"}, []);
	}

	// The signature C# gives the .NET type `path` with the type arguments `args`: a primitive's, a value
	// type's or a class's. Refused when `args` are not one per type parameter.
	public function csType(path:IlPath, args:Array<IlSigNorm>):IlSigNorm {
		var prim = DotnetTypes.primitive(path);
		if (prim != null && args.length == 0) return prim;
		var cls = rawClass(path);
		if (cls.ctypes.length != args.length)
			throw Unsupported.error("the .NET type " + sigS(LClass(path, [])) + " takes " + cls.ctypes.length + " type arguments, not " + args.length);
		return isValueTypeClass(cls) ? LValueType(path, args) : LClass(path, args);
	}

	// Whether C# code in another assembly can name the .NET type `path`: public, or nested public.
	public function isVisibleType(path:IlPath):Bool {
		var cls = try rawClass(path) catch (_:Unsupported) null;
		return cls != null && cls.cflags.vis.match(VPublic | VNestedPublic);
	}

	// The field, literal constant or property (without index parameters) named `name` that C# finds on a
	// receiver of the type `recv` (`isStatic`: a type, not a value), walking from its class up as `field` does
	// (ruling Y), through the public members; the parent is in terms of `recv`'s type arguments, the member's
	// signature open as the metadata declares it. Null when the first class declaring a member of that name
	// declares a method, or when none does. A protected member, or one of the other kind (static or not), is
	// refused rather than looked past.
	public function memberCs(recv:IlSigNorm, name:String, isStatic:Bool):Null<BoundField> {
		var what = sigS(recv) + "." + name;
		function check(access:FieldAccess, link:{cls:IlClass, parent:IlSigNorm}, memberStatic:Bool):Bool {
			switch (access) {
				case FAPublic:
				case FAFamily | FAFamOrAssem:
					throw Unsupported.error("hxc cannot tell whether the protected .NET member " + sigS(LClass(link.cls.cpath, [])) + "." + name
						+ " is accessible here");
				case _:
					return false;
			}
			if (memberStatic != isStatic)
				throw Unsupported.error("the .NET member " + what + " is " + (memberStatic ? "a static" : "an instance") + " member, which inline C# reaches through "
					+ (isStatic ? "its type" : "a value") + " (C# error " + (isStatic ? "CS0120" : "CS0176") + ")");
			return true;
		}
		for (link in csChain(recv, name)) {
			for (f in link.cls.cfields) if (f.fname == name && check(f.fflags.access, link, f.fflags.contract.indexOf(CStatic) >= 0)) {
				var member = f.fconstant != null ? XConstant(f.fconstant, f.fsig.snorm) : XField(f.fsig.snorm, f.fflags.contract.indexOf(CInitOnly) >= 0);
				return {member: member, parent: link.parent};
			}
			for (p in link.cls.cprops) if (p.pname == name) {
				var t = switch (p.psig.snorm) {
					case LMethod(_, ret, []): ret;
					case LMethod(_, _, _): continue;
					case s: s;
				}
				var getter = p.pget;
				if (getter == null || !check(getter.flags.access, link, getter.flags.contract.indexOf(CMStatic) >= 0))
					throw Unsupported.error("the .NET property " + what + " has no public getter");
				var setter = p.pset != null && p.pset.flags.access == FAPublic ? p.pset.name : null;
				return {member: XProperty(t, getter.name, setter), parent: link.parent};
			}
			for (m in link.cls.cmethods) if (m.mname == name && m.mflags.access.match(FAPublic | FAFamily | FAFamOrAssem)) return null;
		}
		return null;
	}

	// Whether some class along `recv`'s chain declares a method named `name`.
	public function hasMethodCs(recv:IlSigNorm, name:String):Bool {
		for (link in csChain(recv, name)) for (m in link.cls.cmethods) if (m.mname == name) return true;
		return false;
	}

	// Whether the .NET struct `recv` declares a public parameterless constructor, which C#'s `new T()` calls
	// rather than giving default(T).
	public function hasParameterlessCtor(recv:IlSigNorm):Bool {
		for (m in csChain(recv)[0].cls.cmethods)
			if (m.mname == ".ctor" && m.margs.length == 0 && m.mflags.access == FAPublic && m.mflags.contract.indexOf(CMStatic) < 0) return true;
		return false;
	}

	// The name of the getter of the indexer C# finds on a receiver of the type `recv`: that of the property the
	// first class along the chain with a DefaultMemberAttribute names; null when none has one.
	public function indexerGetterCs(recv:IlSigNorm):Null<String> {
		for (link in csChain(recv)) {
			var name = defaultMember(link.cls);
			if (name == null) continue;
			for (p in link.cls.cprops) if (p.pname == name && p.pget != null) return p.pget.name;
			return null;
		}
		return null;
	}

	// The method named `name` (".ctor" for `new`) that C# binds for a call on a receiver of the type `recv`
	// (`isStatic`: on a type) with arguments of the types `args` and the kinds `argKinds` (ruling X), as 4a's
	// hand-written externs bind (`resolve`): link by link from `recv`'s class, overrides left out, the one
	// exact match, else the one applicable method; refused where more than one applies or hxc cannot tell.
	// A protected method is never taken, as hxc cannot tell whether the receiver allows it. Null when no
	// class along the chain declares a method of that name.
	public function bindCs(recv:IlSigNorm, name:String, isStatic:Bool, args:Array<IlSigNorm>, argKinds:Array<ArgKind>, pos:hxc.ast.Position):Null<CsMethod> {
		var isCtor = name == ".ctor";
		var links = isCtor ? csChain(recv) : csChain(recv, name);
		var what = isCtor ? "constructor of " + sigS(recv) : "overload of " + sigS(recv) + "." + name;
		function fail(text:String):Dynamic {
			var u = Unsupported.error(text);
			u.pos = pos;
			throw u;
		}
		if (isCtor) {
			links = [links[0]];
			var sem = links[0].cls.cflags.semantics;
			if (sem.indexOf(SAbstract) >= 0 || sem.indexOf(SInterface) >= 0)
				fail("the .NET type " + sigS(recv) + " is abstract or an interface, which `new` cannot create (C# error CS0144)");
		}
		if (!Lambda.exists(links, l -> Lambda.exists(l.cls.cmethods, m -> m.mname == name))) return null;
		var receiver:Null<Receiver> = isStatic ? null : {cls: null, opaque: true};
		byValue = false;
		var list = "(" + [for (i in 0...args.length) argKinds[i].match(KNull) ? "null" : sigS(args[i])].join(", ") + ")";
		var found:Bound = switch (resolve(links, name, isStatic, args, 0, null, receiver, null, argKinds, true)) {
			case RBound(b): b;
			case RAmbiguous: fail("more than one .NET " + what + " accepts " + list);
			case RUnknown(1):
				fail("hxc cannot tell whether the .NET " + (isCtor ? "constructor of " + sigS(recv) : "method " + sigS(recv) + "." + name) + " accepts "
					+ list);
			case RUnknown(_): fail("more than one .NET " + what + " may accept " + list);
			case RNone: fail("no .NET " + what + " takes " + list);
		}
		var link = links[found.link];
		var m = link.cls.cmethods[found.index];
		var largs = linkArgs(link);
		var targs = found.typeArgs == null ? [] : found.typeArgs;
		var contract = m.mflags.contract;
		return {
			parent: link.parent,
			name: m.mname,
			sig: m.msig.snorm,
			genericCount: m.mtypes.length,
			typeArgs: found.typeArgs,
			isVirtual: contract.indexOf(CMVirtual) >= 0 && contract.indexOf(CMFinal) < 0,
			params: [for (a in m.margs) DotnetTypes.substitute(a.sig.snorm, largs, targs)],
			ret: DotnetTypes.substitute(m.mret.snorm, largs, targs),
			omitted: m.margs.slice(args.length)
		};
	}
}

// A .NET method inline C# binds (ExternMembers.bindCs): `parent`, the class declaring it with the receiver's
// type arguments; `sig`, its signature as declared, for its token; `params` and `ret` with the type arguments
// applied; `omitted`, the trailing parameters the call leaves out.
typedef CsMethod = {
	parent:IlSigNorm,
	name:String,
	sig:IlSigNorm,
	genericCount:Int,
	typeArgs:Null<Array<IlSigNorm>>,
	isVirtual:Bool,
	params:Array<IlSigNorm>,
	ret:IlSigNorm,
	omitted:Array<IlMethodArg>
}

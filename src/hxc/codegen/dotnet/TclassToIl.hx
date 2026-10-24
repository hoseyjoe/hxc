package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.HxGen;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.ReflectionMembers;
import hxc.codegen.dotnet.TexprToIl;

enum MethodKind {
	MField(cf:TClassField);
	// C#'s constructor for a class that declares none: it calls the base type's parameterless one.
	MImplicitCtor;
	MEntryPoint;
	// Static var initializers and __init__.
	MCctor;
	// gencs's ToString for a class with toString():String, which returns this.toString().
	MToString(toString:TClassField);
	// An hxgen class's constructor taking haxe.lang.EmptyObject, which runs no constructor body.
	MEmptyCtor;
	// An hxgen class's real constructor: base(EmptyObject.EMPTY), or the parameterless base constructor
	// when the body calls no super(...), then the static constructor with `this` and the arguments.
	MSplitCtor(ctor:HaxeCtor);
	// The static __hx_ctor_* method holding a constructor's initializers and body, `__hx_this` (its first
	// argument) standing for `this` and super(...) calling the base class's static constructor.
	MStaticCtor(ctor:HaxeCtor);
	// A constructor cloned from the .NET base class's, under a class that descends from one.
	MClonedCtor(ctor:HaxeCtor);
	// One of gencs's `__hx_*` reflection members.
	MReflect(r:ReflectMember);
	// For an override with a contravariant parameter (OOverload): the override with the overridden
	// method's signature, which calls the method, a new virtual overload with its own signature.
	MBridge(cf:TClassField);
}

// How an override takes the slot of the method it overrides, as gencs's FixOverrides fixes one whose
// CLR signature differs from the slot's: the same signature; the slot's, the parameters whose types
// changed renamed `__temp_<name><n>` and converted into locals of their own names and types at the
// top of the body; or, when a parameter is contravariant (the base method's type unifies with the
// override's and not the other way round, unless the override's is Dynamic), the method keeps its own
// signature as a new virtual overload and an override with the slot's (MBridge) calls it.
enum OverrideShape {
	OSame;
	OInline(slot:{args:Array<IlSigNorm>, ret:IlSigNorm});
	OOverload(slot:{args:Array<IlSigNorm>, ret:IlSigNorm});
}

typedef MethodPlan = {
	kind:MethodKind,
	name:String,
	flags:Int,
	hasThis:Bool,
	ret:IlSigNorm,
	args:Array<IlSigNorm>,
	argNames:Array<String>,
	generics:Array<String>,
	pos:Position,
	token:Int,
	// An override that took its slot's signature (OInline): the parameter types its body sees.
	?ownArgs:Array<IlSigNorm>
};

typedef FieldPlan = {cf:TClassField, name:String, flags:Int, sig:IlSigNorm};

// A constructor of a class in gencs's class model: the real one, and the static one holding its body
// (null when the class descends from a native type).
typedef CtorPlan = {hx:HaxeCtor, real:MethodPlan, stat:Null<MethodPlan>};

// What a class becomes, worked out before any row is written, so a class that cannot be declared
// is left out without leaving rows behind. `c` is null for EntryPoint__Main.
typedef ClassPlan = {
	c:Null<TClass>,
	hxPath:String,
	path:IlPath,
	flags:Int,
	// Null for System.Object, and for an interface, which has no base type.
	superSig:Null<IlSigNorm>,
	interfaces:Array<IlSigNorm>,
	fields:Array<FieldPlan>,
	methods:Array<MethodPlan>,
	classParams:TypeParams,
	isStd:Bool,
	// The class's own type, as `this` has it.
	thisSig:IlSigNorm,
	isStruct:Bool,
	// A generic class with a .cctor: gencs's `static bool __hx_init_called`, which lets the .cctor of
	// only the first instantiation run, since the CLR runs one per instantiation.
	initFlag:Bool,
	// gencs's class model (HxGen): the constructors, null for a class outside it, and the constructor
	// taking haxe.lang.EmptyObject.
	ctors:Null<Array<CtorPlan>>,
	emptyCtor:Null<MethodPlan>,
	token:Int
};

// An interface a class implements, with its type arguments in terms of the class's type parameters.
private typedef ImplementedInterface = {c:TClass, params:Array<T>, sig:IlSigNorm};

class TypeAttrs {
	public static inline var PUBLIC = 0x1;
	public static inline var SEQUENTIAL = 0x8;
	public static inline var INTERFACE = 0x20;
	public static inline var ABSTRACT = 0x80;
	public static inline var SEALED = 0x100;
	public static inline var BEFORE_FIELD_INIT = 0x100000;
}

class MethodAttrs {
	public static inline var PRIVATE = 0x1;
	public static inline var FAMILY = 0x4;
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
	public static inline var FINAL = 0x20;
	public static inline var VIRTUAL = 0x40;
	public static inline var HIDE_BY_SIG = 0x80;
	public static inline var NEW_SLOT = 0x100;
	public static inline var ABSTRACT = 0x400;
	public static inline var SPECIAL_NAME = 0x800;
	public static inline var RT_SPECIAL_NAME = 0x1000;
}

class FieldAttrs {
	public static inline var PRIVATE = 0x1;
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
	public static inline var LITERAL = 0x40;
	public static inline var SPECIAL_NAME = 0x200;
	public static inline var RT_SPECIAL_NAME = 0x400;
	public static inline var HAS_DEFAULT = 0x8000;
}

// A Haxe class as a TypeDef with its fields and methods. Every member is public, as gencs makes
// them. Members come as instance fields, static fields, .ctor (for a class in gencs's model the
// EmptyObject one first), instance methods, ToString, the static constructors, static methods, each
// in declaration order, then Main() and .cctor.

class TclassToIl {
	static final objectPath:IlPath = {ns: ["System"], nested: [], name: "Object"};
	static final valueTypePath:IlPath = {ns: ["System"], nested: [], name: "ValueType"};
	static inline final initFlagName = "__hx_init_called";

	static function functionSig(g:DotnetCtx, t:T):{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm} {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): {
					args: [for (a in sig.args) g.types.argSig(a.t, a.opt)],
					names: [for (a in sig.args) a.name],
					ret: g.types.toSig(sig.ret)
				};
			case _: throw "internal error: a method without a function type";
		}
	}

	static function at(u:Unsupported, pos:Position):Unsupported {
		if (u.pos == null) u.pos = pos;
		return u;
	}

	// The class's plan, into g.plans; throws Unsupported when it cannot be declared.
	public static function declare(g:DotnetCtx, c:TClass):Void {
		var isStd = g.isStd(c.pos);
		var plan = try g.types.withParams(c.params, [], () -> planClass(g, c, isStd)) catch (u:Unsupported) throw at(u, c.pos);
		g.plans.push(plan);
		g.planOf.set(c, plan);
	}

	static function planClass(g:DotnetCtx, c:TClass, isStd:Bool):ClassPlan {
		var isInterface = TypeFunctions.hasClassFlag(c, CInterface);
		var isStruct = TypeFunctions.hasMeta(":struct", c.meta);
		if (!isStd && TypeFunctions.hasMeta(":classCode", c.meta)) throw new Unsupported("@:classCode", false);
		var superSig = switch (c.superClass) {
			case null: null;
			case s: g.types.toSig(TInst(s.c, s.params));
		}
		if (superSig != null && superSig.match(LObject)) superSig = null;
		if (superSig != null && !superSig.match(LClass(_, _))) throw new Unsupported("extending a value type", false);
		if (isStruct) {
			if (superSig != null) throw new Unsupported("structs that extend a class", true);
			superSig = LClass(valueTypePath, []);
		}
		// gencs's class model, for an hxgen class that is not a struct (C# has no struct deriving from
		// HxObject). Its constructor bodies move to static methods unless it descends from a native type.
		var model = !isStruct && HxGen.hasCtorModel(c);
		// An extern superclass in gencs's model (@:hxGen) would have to be a Haxe-generated assembly's class,
		// with its empty constructor, static constructors and reflection members; nothing here declares them.
		if (model && c.superClass != null && TypeFunctions.hasClassFlag(c.superClass.c, CExtern) && HxGen.isHxGen(TClassDecl(c.superClass.c)))
			throw new Unsupported("classes extending an extern class marked @:hxGen", true);
		var split = model && !HxGen.descendsFromNative(c);
		if (model && c.superClass == null && DotnetTypes.haxePath(TClassDecl(c)) != DotnetCtx.hxObjectPath)
			superSig = LClass(g.types.stdClassPath(DotnetCtx.hxObjectPath, "haxe.lang.HxObject", false), []);
		var interfaces = interfaceClosure(g, c);
		if (isInterface) for (cf in c.orderedFields) if (cf.kind.match(Var(_))) throw at(new Unsupported("interface variables", true), cf.pos);
		var implementing = isInterface ? new ObjectMap() : interfaceImpls(g, c, interfaces);

		var fields:Array<FieldPlan> = [];
		function addFields(list:Array<TClassField>, isStatic:Bool) {
			for (cf in list) {
				if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) || !TypeFunctions.isPhysicalField(cf)) continue;
				try switch (cf.kind) {
					case Var(_):
						// C# has no field initializers in structs, and gencs moves none into their constructors.
						if (isStruct && !isStatic && cf.expr != null) throw new Unsupported("instance variable initializers in structs", true);
						fields.push({
							cf: cf,
							name: DotnetNames.fieldName(c, cf.name),
							flags: FieldAttrs.PUBLIC | (isStatic ? FieldAttrs.STATIC : 0),
							sig: g.types.toSig(cf.type)
						});
					case Method(MethDynamic):
						throw new Unsupported("dynamic methods", true);
					case Method(_):
				} catch (u:Unsupported) throw at(u, cf.pos);
			}
		}
		addFields(c.orderedFields, false);
		addFields(c.orderedStatics, true);

		var methods:Array<MethodPlan> = [];
		function addMethod(cf:TClassField, isStatic:Bool, isCtor:Bool) {
			switch (cf.kind) {
				case Method(MethMacro): return;
				case Method(_):
				case Var(_): return;
			}
			if (TypeFunctions.hasClassFieldFlag(cf, CfExtern)) return;
			// An @:overload method is one MethodDef per overload.
			for (f in [cf].concat(cf.overloads)) try {
				var isAbstract = isInterface || TypeFunctions.hasClassFieldFlag(f, CfAbstract);
				if (f.expr == null && !isAbstract) continue;
				var sig = g.types.withParams(c.params, f.params, () -> functionSig(g, f.type));
				if (isCtor && isStruct && sig.args.length == 0) {
					// As in gencs, a struct's constructor without arguments is the default one; it must be empty.
					if (!isEmpty(f.expr)) throw new Unsupported("struct constructors without arguments that do something", true);
					continue;
				}
				if (isCtor && !isStruct && !hasSuperCall(f.expr)) checkParameterlessBase(g, c);
				var shape = !isStatic && !isCtor && !isInterface && isOverride(f) ? overrideShape(g, c, TypeFunctions.extractParamTypes(c.params), f, sig) : OSame;
				var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG;
				if (isStatic) flags |= MethodAttrs.STATIC;
				else if (isCtor) flags |= MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME;
				else flags |= virtuality(c, f, isStruct, implementing.exists(f), !shape.match(OOverload(_)));
				var name = isCtor ? ".ctor" : DotnetNames.fieldName(c, f.name);
				var generics = [for (p in f.params) p.name];
				if (!shape.match(OSame) && TypeFunctions.hasClassFieldFlag(f, CfAbstract))
					throw new Unsupported("abstract overrides that change the signature", true);
				switch (shape) {
					case OSame:
						methods.push({
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: !isStatic,
							ret: isCtor ? LVoid : sig.ret,
							args: sig.args,
							argNames: sig.names,
							generics: generics,
							pos: f.pos,
							token: 0
						});
					case OInline(slot):
						methods.push({
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: true,
							ret: slot.ret,
							args: slot.args,
							argNames: tempNames(g, sig, slot),
							generics: generics,
							pos: f.pos,
							token: 0,
							ownArgs: sig.args
						});
					case OOverload(slot):
						// The override first, as gencs writes the overload it adds in front of the method.
						methods.push({
							kind: MBridge(f),
							name: name,
							flags: MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.VIRTUAL,
							hasThis: true,
							ret: slot.ret,
							args: slot.args,
							argNames: tempNames(g, sig, slot),
							generics: generics,
							pos: f.pos,
							token: 0
						});
						methods.push({
							kind: MField(f),
							name: name,
							flags: flags,
							hasThis: true,
							ret: sig.ret,
							args: sig.args,
							argNames: sig.names,
							generics: generics,
							pos: f.pos,
							token: 0
						});
				}
			} catch (u:Unsupported) throw at(u, f.pos);
		}
		var ctors:Null<Array<CtorPlan>> = null;
		var emptyCtor:Null<MethodPlan> = null;
		var staticCtors:Array<MethodPlan> = [];
		if (model) {
			emptyCtor = ctorMethod(MEmptyCtor, [g.emptyObjectSig()], ["empty"], MethodAttrs.PUBLIC, c.pos);
			methods.push(emptyCtor);
			ctors = [];
			for (hc in HxGen.ctors(c)) try {
				var pos = hc.own != null ? hc.own.pos : c.pos;
				var args = [for (a in hc.args) g.types.argSig(a.t, a.opt)];
				var names = [for (a in hc.args) a.name];
				var kind = if (split) {
					MSplitCtor(hc);
				} else if (hc.own != null) {
					if (!hasSuperCall(hc.own.expr)) checkParameterlessBase(g, c);
					MField(hc.own);
				} else if (hc.clone) {
					MClonedCtor(hc);
				} else {
					checkParameterlessBase(g, c);
					MImplicitCtor;
				}
				// A constructor cloned from a protected one stays protected, as gencs keeps @:protected.
				var access = hc.own == null && hc.origin != null && TypeFunctions.hasMeta(":protected", hc.origin.meta) ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC;
				var real = ctorMethod(kind, args, names, access, pos);
				methods.push(real);
				var stat:Null<MethodPlan> = null;
				if (split) {
					// In a generic class, the static constructor has the class's type parameters as its own.
					var self = g.types.withParams([], c.params, () -> g.types.toSig(TInst(c, TypeFunctions.extractParamTypes(c.params))));
					var statArgs = g.types.withParams([], c.params, () -> [for (a in hc.args) g.types.argSig(a.t, a.opt)]);
					stat = {
						kind: MStaticCtor(hc),
						name: HxGen.ctorName(c),
						flags: (TypeFunctions.hasClassFlag(c, CFinal) ? MethodAttrs.PRIVATE : MethodAttrs.FAMILY) | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG,
						hasThis: false,
						ret: LVoid,
						args: [self].concat(statArgs),
						argNames: ["__hx_this"].concat(names),
						generics: [for (p in c.params) p.name + "_c"],
						pos: pos,
						token: 0
					};
					staticCtors.push(stat);
				}
				ctors.push({hx: hc, real: real, stat: stat});
			} catch (u:Unsupported) throw at(u, hc.own != null ? hc.own.pos : c.pos);
		} else if (c.constructor != null && !TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			addMethod(c.constructor, false, true);
		} else if (!isInterface && !isStruct) {
			checkParameterlessBase(g, c);
			methods.push(implicitCtor(c.pos, TypeFunctions.hasClassFlag(c, CAbstract)));
		}
		for (cf in c.orderedFields) addMethod(cf, false, false);
		for (r in ReflectionMembers.members(g, c)) methods.push(ReflectionMembers.plan(g, c, r));
		var toString = isInterface ? null : c.fields.get("toString");
		if (toString != null && wrapsToString(g, c, toString)) {
			methods.push({
				kind: MToString(toString),
				name: "ToString",
				flags: MethodAttrs.PUBLIC | MethodAttrs.VIRTUAL | MethodAttrs.HIDE_BY_SIG,
				hasThis: true,
				ret: LString,
				args: [],
				argNames: [],
				generics: [],
				pos: toString.pos,
				token: 0
			});
		}
		// gencs adds each overload's static constructor in front of the earlier ones, after the main one:
		// the overloads come in reverse, the main one (listed last) still last.
		if (staticCtors.length > 1) {
			var main = staticCtors.pop();
			staticCtors.reverse();
			staticCtors.push(main);
		}
		for (m in staticCtors) methods.push(m);
		for (cf in c.orderedStatics) addMethod(cf, true, false);
		if (g.mainClass == c && c.path.name != "Main") methods.push(entryPoint(c.pos));

		var hasCctor = c.init != null;
		for (f in fields) if (f.flags & FieldAttrs.STATIC != 0 && f.cf.expr != null) hasCctor = true;
		if (hasCctor) {
			methods.push({
				kind: MCctor,
				name: ".cctor",
				flags: MethodAttrs.PRIVATE | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
				hasThis: false,
				ret: LVoid,
				args: [],
				argNames: [],
				generics: [],
				pos: c.pos,
				token: 0
			});
		}

		var flags = TypeAttrs.PUBLIC;
		if (isInterface) {
			flags |= TypeAttrs.INTERFACE | TypeAttrs.ABSTRACT;
		} else {
			if (TypeFunctions.hasClassFlag(c, CAbstract)) flags |= TypeAttrs.ABSTRACT;
			if (TypeFunctions.hasClassFlag(c, CFinal) || isStruct) flags |= TypeAttrs.SEALED;
			if (isStruct) flags |= TypeAttrs.SEQUENTIAL;
			if (!hasCctor) flags |= TypeAttrs.BEFORE_FIELD_INIT;
		}
		return {
			c: c,
			hxPath: DotnetTypes.haxePath(TClassDecl(c)),
			path: DotnetNames.typePath(TClassDecl(c)),
			flags: flags,
			superSig: superSig,
			interfaces: [for (i in interfaces) i.sig],
			fields: fields,
			methods: methods,
			classParams: c.params,
			isStd: isStd,
			thisSig: g.types.toSig(TInst(c, TypeFunctions.extractParamTypes(c.params))),
			isStruct: isStruct,
			initFlag: hasCctor && c.params.length > 0,
			ctors: ctors,
			emptyCtor: emptyCtor,
			token: 0
		};
	}

	// The interfaces the class lists and the ones they extend, as C# writes them all on the type. As
	// gencs makes them, an interface in its model extends haxe.lang.IHxObject, and so does a class in it
	// whose members are the first of the hierarchy (ReflectionMembers.isRoot).
	static function interfaceClosure(g:DotnetCtx, c:TClass):Array<ImplementedInterface> {
		var r:Array<ImplementedInterface> = [];
		var ihx = g.runtimeClass("cs.internal.IHxObject");
		function extendsIHxObject(i:TClass):Bool {
			return ihx != null && i != ihx && TypeFunctions.hasClassFlag(i, CInterface) && !TypeFunctions.hasClassFlag(i, CExtern)
				&& HxGen.isHxGen(TClassDecl(i));
		}
		function add(i:TClass, params:Array<T>) {
			// An extern interface with no .NET counterpart is only a Haxe type.
			if (TypeFunctions.hasClassFlag(i, CExtern) && !g.ctx.netPathMap.exists(Globals.sTypePath(i.path))
				&& DotnetNames.nativeName(i.meta) == null)
				return;
			var sig = g.types.toSig(TInst(i, params));
			for (x in r) if (IlPaths.sigEq(x.sig, sig)) return;
			r.push({c: i, params: params, sig: sig});
			for (sup in i.interfaces) add(sup.c, [for (t in sup.params) TypeFunctions.applyParams(i.params, params, t)]);
			if (extendsIHxObject(i)) add(ihx, []);
		}
		for (i in c.interfaces) add(i.c, i.params);
		if (extendsIHxObject(c) || ihx != null && c != ihx && ReflectionMembers.applies(c) && ReflectionMembers.isRoot(c)) add(ihx, []);
		return r;
	}

	// A method's CLR name and signature, in terms of the class's type parameters and its own.
	static function methodSig(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField):{args:Array<IlSigNorm>, ret:IlSigNorm} {
		var f = g.types.withParams(g.types.currentClassParams(), cf.params, () -> functionSig(g, TypeFunctions.applyParams(owner.params, ownerArgs, cf.type)));
		return {args: f.args, ret: f.ret};
	}

	static function sameSig(a:{args:Array<IlSigNorm>, ret:IlSigNorm}, b:{args:Array<IlSigNorm>, ret:IlSigNorm}):Bool {
		return IlPaths.sigsEq(a.args, b.args) && IlPaths.sigEq(a.ret, b.ret);
	}

	static function isFinalMethod(c:TClass, cf:TClassField):Bool {
		return TypeFunctions.hasClassFieldFlag(cf, CfFinal) || TypeFunctions.hasClassFlag(c, CFinal) || TypeFunctions.hasMeta(":struct", c.meta)
			|| cf.kind.match(Method(MethInline));
	}

	// The class's own methods that implement an interface method. The CLR matches an implementation
	// by name and exact signature, so an interface method without one it would match throws.
	static function interfaceImpls(g:DotnetCtx, c:TClass, interfaces:Array<ImplementedInterface>):ObjectMap<TClassField, Bool> {
		var own = new ObjectMap<TClassField, Bool>();
		var ihx = g.runtimeClass("cs.internal.IHxObject");
		for (i in interfaces) {
			// The reflection members, which the class or HxObject has, implement IHxObject.
			if (i.c == ihx) continue;
			var isExternInterface = TypeFunctions.hasClassFlag(i.c, CExtern);
			for (im in i.c.orderedFields) {
				switch (im.kind) {
					case Var(_):
						if (isExternInterface) throw new Unsupported("properties of .NET interfaces", true);
						// A Haxe interface with variables is left out, and this class with it.
						continue;
					case Method(MethMacro):
						continue;
					case Method(_):
				}
				for (f in [im].concat(im.overloads)) {
					var name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm};
					if (isExternInterface) {
						var m = g.externs.method(i.c, f);
						if (m.genericCount > 0) throw new Unsupported("generic .NET interface methods", true);
						var iargs = switch (i.sig) {
							case LClass(_, l): l;
							case _: [];
						}
						name = m.name;
						want = switch (ExternMembers.subst(m.sig, iargs)) {
							case LMethod(_, r, l): {args: l, ret: r};
							case _: throw "internal error: not a method signature";
						}
					} else {
						name = DotnetNames.fieldName(i.c, f.name);
						want = methodSig(g, i.c, i.params, f);
					}
					findImplementation(g, c, f.name, name, want, own);
				}
			}
		}
		return own;
	}

	static function findImplementation(g:DotnetCtx, c:TClass, hxName:String, name:String, want:{args:Array<IlSigNorm>, ret:IlSigNorm},
			own:ObjectMap<TClassField, Bool>):Void {
		var cur = c;
		var params = TypeFunctions.extractParamTypes(c.params);
		var other = new Unsupported("interface methods implemented with other types", true);
		while (cur != null) {
			var cf = cur.fields.get(hxName);
			if (cf != null) {
				// The .NET base class's own method, which the CLR checks when it loads the type.
				if (TypeFunctions.hasClassFlag(cur, CExtern)) return;
				if (DotnetNames.fieldName(cur, cf.name) != name) throw other;
				for (f in [cf].concat(cf.overloads)) {
					if (!sameSig(methodSig(g, cur, params, f), want)) continue;
					if (cur == c) own.set(f, true);
					else if (isFinalMethod(cur, f)) throw new Unsupported("interface methods implemented by a final inherited method", true);
					return;
				}
				throw other;
			}
			var s = cur.superClass;
			if (s == null) break;
			params = [for (t in s.params) TypeFunctions.applyParams(cur.params, params, t)];
			cur = s.c;
		}
		throw new Unsupported("abstract classes that leave interface methods unimplemented", true);
	}

	// gencs's modifiers: virtual unless final or inline, override without newslot (unless FixOverrides
	// made the method a new overload: `overrides` false), abstract, and final virtual for a non-virtual
	// method that implements an interface method.
	static function virtuality(c:TClass, cf:TClassField, isStruct:Bool, implementsInterface:Bool, overrides:Bool):Int {
		if (TypeFunctions.hasClassFlag(c, CInterface)) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		var isAbstract = TypeFunctions.hasClassFieldFlag(cf, CfAbstract);
		if (overrides && isOverride(cf)) return MethodAttrs.VIRTUAL | (isAbstract ? MethodAttrs.ABSTRACT : 0);
		if (isAbstract) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		if (!isFinalMethod(c, cf)) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT;
		return implementsInterface ? MethodAttrs.VIRTUAL | MethodAttrs.FINAL | MethodAttrs.NEW_SLOT : 0;
	}

	// `override`, and as gencs has it, Equals(Dynamic):Bool and GetHashCode().
	static function isOverride(cf:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) return true;
		return switch [cf.name, TypeFunctions.follow(cf.type)] {
			case ["Equals", TFun(sig)] if (sig.args.length == 1):
				TypeFunctions.follow(sig.args[0].t).match(TDynamic(_)) && switch (TypeFunctions.follow(sig.ret)) {
					case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Bool";
					case _: false;
				};
			case ["GetHashCode", TFun(sig)]: sig.args.length == 0;
			case _: false;
		}
	}

	// How the override `cf` of `owner` (with type arguments `ownerArgs`, in terms of the class being
	// planned), whose signature is `sig`, takes the slot of the method it overrides. The slot of a .NET
	// method or of an overloaded one is taken only with the same signature; a covariant one would
	// silently become a new method.
	static function overrideShape(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField, sig:{args:Array<IlSigNorm>, ret:IlSigNorm}):OverrideShape {
		var changed = new Unsupported("overrides that change the signature", true);
		var s = owner.superClass;
		if (s == null) return OSame;
		var params = [for (t in s.params) TypeFunctions.applyParams(owner.params, ownerArgs, t)];
		while (true) {
			var base = s.c.fields.get(cf.name);
			if (base != null) {
				if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
					if (s.c.params.length > 0 || owner.params.length > 0) throw new Unsupported("overriding methods of generic .NET classes", true);
					var m = try g.externs.method(s.c, cf) catch (_:Unsupported) throw changed;
					if (!m.isVirtual) throw new Unsupported("overriding a non-virtual .NET method", false);
					var ret = switch (m.sig) {
						case LMethod(_, r, _): r;
						case _: throw "internal error: not a method signature";
					}
					if (!IlPaths.sigEq(ret, sig.ret)) throw changed;
					return OSame;
				}
				if (base.overloads.length > 0) {
					for (f in [base].concat(base.overloads)) if (sameSig(methodSig(g, s.c, params, f), sig)) return OSame;
					throw changed;
				}
				var slot = slotSig(g, s.c, params, base);
				if (sameSig(slot, sig)) return OSame;
				if (slot.args.length != sig.args.length || slot.ret.match(LVoid) != sig.ret.match(LVoid) || base.params.length != cf.params.length)
					throw changed;
				return contravariant(g, owner, ownerArgs, cf, s.c, params, base) ? OOverload(slot) : OInline(slot);
			}
			var next = s.c.superClass;
			if (next == null) return OSame;
			params = [for (t in next.params) TypeFunctions.applyParams(s.c.params, params, t)];
			s = {c: next.c, params: params};
		}
	}

	// The CLR signature of the method `cf` of `owner`, which an override of it takes: its own, or for an
	// override that took its slot's (OInline), that one.
	static function slotSig(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField):{args:Array<IlSigNorm>, ret:IlSigNorm} {
		var own = methodSig(g, owner, ownerArgs, cf);
		if (!isOverride(cf)) return own;
		return switch (overrideShape(g, owner, ownerArgs, cf, own)) {
			case OInline(slot): slot;
			case _: own;
		}
	}

	// gencs's has_contravariant_args: a parameter of the base method `bf` whose type unifies with the
	// override's and not the other way round. An override parameter whose real type is Dynamic (Dynamic,
	// EnumValue, an anonymous structure) unifies with anything.
	static function contravariant(g:DotnetCtx, owner:TClass, ownerArgs:Array<T>, cf:TClassField, base:TClass, baseArgs:Array<T>,
			bf:TClassField):Bool {
		function args(t:T):Array<T> {
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): [for (a in sig.args) a.t];
				case _: throw "internal error: a method without a function type";
			}
		}
		var cur = args(TypeFunctions.applyParams(owner.params, ownerArgs, cf.type));
		var orig = args(TypeFunctions.applyParams(base.params, baseArgs, bf.type));
		for (i in 0...cur.length) {
			var real = try g.types.withParams(g.types.currentClassParams(), cf.params, () -> g.types.toSig(cur[i])) catch (_:Unsupported) null;
			if (real != null && real.match(LObject)) continue;
			if (TypeUnification.doesUnify(orig[i], cur[i]) && !TypeUnification.doesUnify(cur[i], orig[i])) return true;
		}
		return false;
	}

	// The parameter names of an override that takes its slot's signature: `__temp_<name><n>` for each
	// parameter whose type changed, numbered by gencommon's mk_temp counter, which runs across the
	// program; the others keep their own.
	static function tempNames(g:DotnetCtx, sig:{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm},
			slot:{args:Array<IlSigNorm>, ret:IlSigNorm}):Array<String> {
		return [
			for (i in 0...sig.args.length)
				IlPaths.sigEq(sig.args[i], slot.args[i]) ? sig.names[i] : "__temp_" + sig.names[i] + (++g.tempCount)
		];
	}

	// gencs adds ToString for a class whose own toString() returns String and overrides nothing.
	static function wrapsToString(g:DotnetCtx, c:TClass, cf:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverride) || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || c.fields.exists("ToString")) return false;
		if (!cf.kind.match(Method(MethNormal | MethInline)) || cf.params.length > 0) return false;
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig) if (sig.args.length == 0):
				var ret = try g.types.toSig(sig.ret) catch (_:Unsupported) null;
				ret != null && ret.match(LString);
			case _: false;
		}
	}

	static function isEmpty(e:TExpr):Bool {
		return switch (e.expr) {
			case TBlock(el): Lambda.foreach(el, isEmpty);
			case TMeta(_, e1) | TParenthesis(e1): isEmpty(e1);
			case TConst(TNull): true;
			case TFunction(tf): isEmpty(tf.expr);
			case _: false;
		}
	}

	static function isSuperCall(e:TExpr):Bool {
		return switch (e.expr) {
			case TCall({expr: TConst(TSuper)}, _): true;
			case TMeta(_, e1) | TParenthesis(e1): isSuperCall(e1);
			case _: false;
		}
	}

	static function hasSuperCall(e:TExpr):Bool {
		return isSuperCall(e) || TexprTools.checkExpr(hasSuperCall, e);
	}

	// A constructor that calls no super(...) calls the base type's parameterless one, which must exist;
	// a Haxe base class without a constructor has the implicit one, which calls its own base's.
	static function checkParameterlessBase(g:DotnetCtx, c:TClass):Void {
		var s = c.superClass;
		while (s != null) {
			var sc = s.c;
			if (TypeFunctions.hasClassFlag(sc, CExtern)) {
				var ctor = sc.constructor;
				var ok = false;
				if (ctor != null) for (cf in [ctor].concat(ctor.overloads)) switch (TypeFunctions.follow(cf.type)) {
					case TFun(sig) if (sig.args.length == 0): ok = true;
					case _:
				}
				if (!ok) throw new Unsupported("a base class without a parameterless constructor", false);
				return;
			}
			if (sc.constructor != null) {
				switch (TypeFunctions.follow(sc.constructor.type)) {
					case TFun(sig) if (sig.args.length == 0):
					case _: throw new Unsupported("inherited constructors", true);
				}
				return;
			}
			s = sc.superClass;
		}
	}

	// A constructor of a class in gencs's class model.
	static function ctorMethod(kind:MethodKind, args:Array<IlSigNorm>, names:Array<String>, access:Int, pos:Position):MethodPlan {
		return {
			kind: kind,
			name: ".ctor",
			flags: access | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
			hasThis: true,
			ret: LVoid,
			args: args,
			argNames: names,
			generics: [],
			pos: pos,
			token: 0
		};
	}

	static function implicitCtor(pos:Position, isAbstract:Bool):MethodPlan {
		return {
			kind: MImplicitCtor,
			name: ".ctor",
			flags: (isAbstract ? MethodAttrs.FAMILY : MethodAttrs.PUBLIC) | MethodAttrs.HIDE_BY_SIG | MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME,
			hasThis: true,
			ret: LVoid,
			args: [],
			argNames: [],
			generics: [],
			pos: pos,
			token: 0
		};
	}

	static function entryPoint(pos:Position):MethodPlan {
		return {
			kind: MEntryPoint,
			name: "Main",
			flags: MethodAttrs.PUBLIC | MethodAttrs.STATIC | MethodAttrs.HIDE_BY_SIG,
			hasThis: false,
			ret: LVoid,
			args: [],
			argNames: [],
			generics: [],
			pos: pos,
			token: 0
		};
	}

	// gencs's EntryPoint__Main, in Main's namespace, for a main class named Main.
	public static function entryPointClass(g:DotnetCtx, main:TClass):ClassPlan {
		var mainPath = DotnetNames.typePath(TClassDecl(main));
		var path:IlPath = {ns: mainPath.ns, nested: [], name: "EntryPoint__Main"};
		return {
			c: null,
			hxPath: "EntryPoint__Main",
			path: path,
			flags: TypeAttrs.PUBLIC | TypeAttrs.BEFORE_FIELD_INIT,
			superSig: null,
			interfaces: [],
			fields: [],
			methods: [implicitCtor(main.pos, false), entryPoint(main.pos)],
			classParams: [],
			isStd: false,
			thisSig: LClass(path, []),
			isStruct: false,
			initFlag: false,
			ctors: null,
			emptyCtor: null,
			token: 0
		};
	}

	// The plan's field and method rows, after every TypeDef row exists.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var mb = g.mb;
		if (plan.flags & TypeAttrs.INTERFACE == 0)
			mb.setExtends(plan.token, plan.superSig == null ? mb.typeToken(objectPath, false) : sigToken(g, plan.superSig));
		var implemented = [for (s in plan.interfaces) sigToken(g, s)];
		implemented.sort((a, b) -> a - b);
		for (i in implemented) mb.interfaceImpl(plan.token, i);
		if (plan.c != null && plan.isStd && TypeFunctions.hasMeta(":classCode", plan.c.meta)) g.records.push("ignored @:classCode in " + plan.hxPath);
		for (f in plan.fields) {
			var token = mb.field(plan.token, f.flags, f.name, g.sigs.field(f.sig));
			g.fieldTokens.set(f.cf, token);
			g.fieldSigs.set(f.cf, f.sig);
			g.ownerOf.set(f.cf, plan);
		}
		if (plan.initFlag) mb.field(plan.token, FieldAttrs.PRIVATE | FieldAttrs.STATIC, initFlagName, g.sigs.field(LBool));
		for (m in plan.methods) {
			m.token = mb.method(plan.token, m.flags, 0, m.name, g.sigs.method(m.hasThis, m.ret, m.args, m.generics.length), m.argNames);
			switch (m.kind) {
				case MField(cf):
					g.methodTokens.set(cf, m.token);
					g.methodPlans.set(cf, m);
					g.methodSigs.set(cf, {ret: m.ret, args: m.args});
					g.ownerOf.set(cf, plan);
				case MSplitCtor(hc) if (hc.own != null):
					g.methodTokens.set(hc.own, m.token);
					g.methodPlans.set(hc.own, m);
					g.methodSigs.set(hc.own, {ret: m.ret, args: m.args});
					g.ownerOf.set(hc.own, plan);
				case MEntryPoint:
					g.entryPoint = m.token;
				case _:
			}
		}
	}

	// A TypeDefOrRef coded index for a class signature.
	static function sigToken(g:DotnetCtx, s:IlSigNorm):Int {
		return switch (s) {
			case LClass(p, []): g.mb.typeToken(p, false);
			case _: ModuleBuilder.coded(hxc.codegen.dotnet.IlMeta.TableIdx.ITypeDefOrRef, g.typeTokenOf(s));
		}
	}

	public static function emit(g:DotnetCtx, c:TClass):Void {
		emitPlan(g, g.planOf.get(c));
	}

	public static function emitPlan(g:DotnetCtx, plan:ClassPlan):Void {
		if (plan.c != null) ReflectionMembers.checkConflicts(g, plan.c);
		for (m in plan.methods) emitMethod(g, plan, m);
	}

	static function label(m:MethodPlan):String {
		return switch (m.kind) {
			case MField(cf): cf.name;
			case MImplicitCtor: "new";
			case MEntryPoint: "Main";
			case MCctor: "__init__";
			case MToString(_): "ToString";
			case MEmptyCtor | MSplitCtor(_) | MClonedCtor(_): "new";
			case MStaticCtor(_): "new";
			case MReflect(r): ReflectionMembers.label(r);
			case MBridge(cf): cf.name;
		}
	}

	// The base type's parameterless constructor: a MethodDef token when this module defines it for a
	// non-generic class, else a MemberRef.
	static function baseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var parent = plan.superSig == null ? LClass(objectPath, []) : plan.superSig;
		var token = 0;
		var superPlan = superPlanOf(g, plan);
		if (superPlan != null && parent.match(LClass(_, []))) for (m in superPlan.methods) if (m.name == ".ctor" && m.args.length == 0) token = m.token;
		if (token == 0) token = g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, [], 0));
		code.ldarg(0);
		code.opToken(IlOps.CALL, token, 1, 0);
	}

	// The plan of the type the class extends, when this module defines it: its Haxe superclass's, or for
	// an hxgen class without one HxObject's.
	static function superPlanOf(g:DotnetCtx, plan:ClassPlan):Null<ClassPlan> {
		if (plan.c == null) return null;
		if (plan.c.superClass != null) return g.planOf.get(plan.c.superClass.c);
		if (plan.ctors == null) return null;
		var h = g.runtimeClass(DotnetCtx.hxObjectPath);
		return h == null || h == plan.c ? null : g.planOf.get(h);
	}

	// A constructor of the base type `parent`: its MethodDef token for a non-generic class, else a
	// MemberRef on the instantiation.
	static function ctorToken(g:DotnetCtx, parent:IlSigNorm, m:MethodPlan):Int {
		if (parent.match(LClass(_, []))) return m.token;
		return g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, m.args, 0));
	}

	// base(EmptyObject.EMPTY): the base class's empty constructor.
	static function emptyBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var superPlan = superPlanOf(g, plan);
		if (superPlan == null || superPlan.emptyCtor == null) throw "internal error: the base class of " + plan.hxPath + " has no empty constructor";
		code.ldarg(0);
		code.ldcI4(0);
		code.opToken(IlOps.CALL, ctorToken(g, plan.superSig, superPlan.emptyCtor), 2, 0);
	}

	// The constructor plan of a class in gencs's model that `origin` (null: the empty `new()`) reaches.
	public static function ctorOf(plan:ClassPlan, origin:Null<TClassField>):CtorPlan {
		for (cp in plan.ctors) if (cp.hx.origin == origin) return cp;
		throw "internal error: " + plan.hxPath + " has no constructor for " + (origin == null ? "new()" : origin.name);
	}

	// A static constructor as a call reaches it: through the class's instantiation with object for each
	// type parameter, with `margs` for the method's own, as gencs writes `C<object>.__hx_ctor_C<T>(...)`.
	public static function staticCtorRef(g:DotnetCtx, plan:ClassPlan, stat:MethodPlan, margs:Array<IlSigNorm>):Int {
		if (plan.classParams.length == 0) return stat.token;
		var owner = DotnetCtx.instanceOf(plan, [for (_ in plan.classParams) LObject]);
		var token = g.mb.memberRef(g.typeTokenOf(owner), stat.name, g.sigs.method(false, LVoid, stat.args, stat.generics.length));
		return g.mb.methodSpec(token, g.sigs.methodSpec(margs));
	}

	// The real constructor of the Haxe class `plan` that `origin` reaches (null: its parameterless one).
	static function realCtorOf(g:DotnetCtx, plan:ClassPlan, origin:Null<TClassField>):MethodPlan {
		if (plan.ctors != null) return ctorOf(plan, origin).real;
		var m = origin == null ? null : g.methodPlans.get(origin);
		if (m == null) for (x in plan.methods) if (x.name == ".ctor" && x.kind.match(MImplicitCtor)) m = x;
		if (m == null) throw "internal error: no constructor of " + plan.hxPath;
		return m;
	}

	// C#'s default value of a type, as gencs passes `null` for each argument.
	static function pushDefault(g:DotnetCtx, code:IlCode, t:IlSigNorm):Void {
		if (DotnetTypes.isValueType(t) || t.match(LTypeParam(_) | LMethodTypeParam(_))) {
			var tmp = code.addLocal(t);
			code.ldloca(tmp);
			code.opToken(IlOps.INITOBJ, g.typeTokenOf(t), 1, 0);
			code.ldloc(tmp);
		} else {
			code.op(IlOps.LDNULL, 0, 1);
		}
	}

	// The constructor of the native base class that `origin` names (null: the parameterless one), with
	// the arguments `pushArgs` pushes after `this`.
	static function nativeBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode, origin:Null<TClassField>, owner:Null<TClass>,
			pushArgs:Array<IlSigNorm>->Void):Void {
		var s = plan.c.superClass;
		if (origin == null) {
			baseCtor(g, plan, code);
			return;
		}
		if (owner != s.c) throw new Unsupported("inherited .NET constructors", true);
		var inst = [for (p in s.params) g.types.toSig(p)];
		code.ldarg(0);
		if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
			var m = g.externs.method(s.c, origin);
			var parent = ExternMembers.subst(m.parent, inst);
			var parentArgs = switch (parent) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			}
			var args = switch (m.sig) {
				case LMethod(_, _, l): [for (a in l) ExternMembers.subst(a, parentArgs)];
				case _: throw "internal error: not a method signature";
			}
			pushArgs(args);
			code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.methodSig(m.sig, 0)), args.length + 1, 0);
		} else {
			var m = realCtorOf(g, g.planOf.get(s.c), origin);
			var args = [for (a in m.args) DotnetTypes.substitute(a, inst, [])];
			pushArgs(args);
			code.opToken(IlOps.CALL, ctorToken(g, plan.superSig, m), args.length + 1, 0);
		}
	}

	// gencs's empty constructor: base(EmptyObject.EMPTY) under an hxgen class, the native base class's
	// constructor with the fewest parameters given nulls under a native one, nothing (the parameterless
	// one) at the root.
	static function emptyCtorBody(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var s = plan.c.superClass;
		var superPlan = superPlanOf(g, plan);
		if (s == null) {
			baseCtor(g, plan, code);
		} else if (superPlan != null && superPlan.emptyCtor != null) {
			emptyBaseCtor(g, plan, code);
		} else {
			// The first with the fewest, looking at the main constructor (listed last) before its overloads.
			var prev = HxGen.previousCtors(plan.c);
			var best = null;
			if (prev.length > 0) for (p in [prev[prev.length - 1]].concat(prev.slice(0, prev.length - 1)))
				if (best == null || p.args.length < best.args.length) best = p;
			if (best == null) {
				baseCtor(g, plan, code);
			} else {
				nativeBaseCtor(g, plan, code, best.origin, best.owner, args -> for (a in args) pushDefault(g, code, a));
			}
		}
		code.op(IlOps.RET, 0, 0);
	}

	static function functionOf(cf:TClassField, what:String):TFunc {
		return switch (cf.expr.expr) {
			case TFunction(tf): tf;
			case _: throw "internal error: method " + what + " has no function";
		}
	}

	// An hxgen class's real constructor: base(EmptyObject.EMPTY) when its body calls super(...) (which
	// the static constructor does), else the parameterless base constructor C# calls implicitly; then the
	// static constructor with `this` and the arguments.
	static function splitCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode):Void {
		var callsSuper = hc.own != null ? hasSuperCall(hc.own.expr) : hc.clone;
		if (callsSuper) emptyBaseCtor(g, plan, code) else baseCtor(g, plan, code);
		var stat = ctorOf(plan, hc.origin).stat;
		for (i in 0...m.args.length + 1) code.ldarg(i);
		var token = staticCtorRef(g, plan, stat, [for (i in 0...plan.classParams.length) LTypeParam(i)]);
		code.opToken(IlOps.CALL, token, m.args.length + 1, 0);
		code.op(IlOps.RET, 0, 0);
	}

	// The static constructor: the initializers, then the constructor's body, or for a cloned one the
	// base class's static constructor with the arguments.
	static function staticCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode, lower:TexprToIl, what:String):Void {
		var c = plan.c;
		if (hc.own != null) {
			if (TypeFunctions.hasMeta(":functionCode", hc.own.meta)) throw new Unsupported("@:functionCode", false, hc.own.pos);
			var tf = functionOf(hc.own, what);
			lower.bindArgs(tf, 1, m.args.slice(1));
			statement(lower, RReturn, withInits(c, tf.expr));
			return;
		}
		var inits = fieldInits(c);
		if (inits.length > 0) statement(lower, RVoid, {expr: TBlock(inits), type: TypeFunctions.tDynamic, pos: c.pos});
		if (hc.clone) {
			var s = c.superClass;
			var superPlan = g.planOf.get(s.c);
			var margs = [for (p in s.params) g.types.toSig(p)];
			var stat = ctorOf(superPlan, hc.origin).stat;
			for (i in 0...m.args.length) code.ldarg(i);
			code.opToken(IlOps.CALL, staticCtorRef(g, superPlan, stat, margs), m.args.length, 0);
		}
	}

	// A constructor cloned from a native base class's: that constructor with the arguments, then the
	// initializers, which C# runs after it.
	static function clonedCtorBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, hc:HaxeCtor, code:IlCode, lower:TexprToIl):Void {
		var owner = null;
		for (p in HxGen.previousCtors(plan.c)) if (p.origin == hc.origin) owner = p.owner;
		nativeBaseCtor(g, plan, code, hc.origin, owner, _ -> for (i in 0...m.args.length) code.ldarg(i + 1));
		var inits = fieldInits(plan.c);
		if (inits.length > 0) statement(lower, RVoid, {expr: TBlock(inits), type: TypeFunctions.tDynamic, pos: plan.c.pos});
	}

	// gencs's FixOverrides override for a method with a contravariant parameter (OOverload), with the
	// slot's signature: `return (R)this.f((A)a, ...)`, a call of the method, which keeps its own signature.
	@:access(hxc.codegen.dotnet.TexprToIl)
	static function bridgeBody(g:DotnetCtx, plan:ClassPlan, m:MethodPlan, cf:TClassField, code:IlCode, lower:TexprToIl):Void {
		var target = g.methodPlans.get(cf);
		if (target == null) throw "internal error: no method " + plan.hxPath + "." + cf.name;
		code.ldarg(0);
		for (i in 0...m.args.length) {
			code.ldarg(i + 1);
			lower.convert(m.args[i], target.args[i]);
		}
		var token = g.memberOf(plan, plan.thisSig, cf);
		if (cf.params.length > 0) token = g.mb.methodSpec(token, g.sigs.methodSpec([for (i in 0...cf.params.length) LMethodTypeParam(i)]));
		code.opToken(IlOps.CALLVIRT, token, m.args.length + 1, target.ret.match(LVoid) ? 0 : 1);
		if (m.ret.match(LVoid)) {
			if (!target.ret.match(LVoid)) code.op(IlOps.POP, 1, 0);
			code.op(IlOps.RET, 0, 0);
		} else {
			lower.convert(target.ret, m.ret);
			code.op(IlOps.RET, 1, 0);
		}
	}

	// Instance var initializers, as gencommon's init_funcs moves them into constructors: @:readOnly
	// ones, which C# runs as field initializers, in declaration order, then the others in reverse
	// declaration order.
	static function fieldInits(c:TClass):Array<TExpr> {
		var readOnly = [], others = [];
		var params = TypeFunctions.extractParamTypes(c.params);
		for (cf in c.orderedFields) {
			if (!cf.kind.match(Var(_)) || cf.expr == null || TypeFunctions.hasClassFieldFlag(cf, CfExtern) || !TypeFunctions.isPhysicalField(cf)) continue;
			var ethis:TExpr = {expr: TConst(TThis), type: TInst(c, params), pos: cf.pos};
			var assign:TExpr = {
				expr: TBinop(OpAssign, {expr: TField(ethis, FInstance(c, params, cf)), type: cf.type, pos: cf.pos}, cf.expr),
				type: cf.type,
				pos: cf.expr.pos
			};
			if (TypeFunctions.hasMeta(":readOnly", cf.meta)) readOnly.push(assign) else others.unshift(assign);
		}
		return readOnly.concat(others);
	}

	// The constructor body with the initializers: before it, or after its leading super(...) when the
	// class descends from a native class (whose constructor C# runs first).
	static function withInits(c:TClass, body:TExpr):TExpr {
		var inits = fieldInits(c);
		if (inits.length == 0) return body;
		var el = switch (body.expr) {
			case TBlock(el): el;
			case _: [body];
		}
		var first = el.length > 0 && isSuperCall(el[0]) && HxGen.descendsFromNative(c) ? 1 : 0;
		return {expr: TBlock(el.slice(0, first).concat(inits).concat(el.slice(first))), type: body.type, pos: body.pos};
	}

	// For a constructor without super(...): the initializers, then the base type's parameterless
	// constructor, as init_funcs puts them before the super() of a cloned or empty constructor; under a
	// .NET base, whose constructor C# runs first, the other way round.
	static function initsAndBaseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode, lower:TexprToIl):Void {
		var inits = plan.c == null ? [] : fieldInits(plan.c);
		var native = plan.c != null && HxGen.descendsFromNative(plan.c);
		if (native) baseCtor(g, plan, code);
		if (inits.length > 0) statement(lower, RVoid, {expr: TBlock(inits), type: TypeFunctions.tDynamic, pos: plan.c.pos});
		if (!native) baseCtor(g, plan, code);
	}

	static function emitMethod(g:DotnetCtx, plan:ClassPlan, m:MethodPlan):Void {
		// Abstract and interface methods have no body.
		if (m.flags & MethodAttrs.ABSTRACT != 0) return;
		var what = plan.hxPath + "." + label(m);
		var code = new IlCode(what);
		var failures:Array<Unsupported> = [];
		var stub:Null<Unsupported> = null;
		var lower = new TexprToIl(g, code, m.ret);
		if (!plan.isStd) lower.onError = u -> failures.push(u);
		lower.cls = plan.c;
		if (m.hasThis) lower.thisSig = plan.thisSig;
		try {
			g.types.inParams(plan.classParams, [], () -> switch (m.kind) {
				case MImplicitCtor:
					initsAndBaseCtor(g, plan, code, lower);
					if (failures.length == 0) lower.finish();
				case MEmptyCtor:
					emptyCtorBody(g, plan, code);
				case MSplitCtor(hc):
					splitCtorBody(g, plan, m, hc, code);
				case MClonedCtor(hc):
					clonedCtorBody(g, plan, m, hc, code, lower);
					if (failures.length == 0) lower.finish();
				case MStaticCtor(hc):
					// `__hx_this`, the first argument, stands for `this`; the class's type parameters are the
					// method's own.
					lower.thisSig = m.args[0];
					lower.splitCtor = true;
					g.types.inParams([], plan.classParams, () -> {
						staticCtorBody(g, plan, m, hc, code, lower, what);
						if (failures.length == 0) lower.finish();
					});
				case MReflect(r):
					ReflectionMembers.emit(g, plan, m, r, code, lower);
				case MToString(cf):
					code.ldarg(0);
					code.opToken(plan.isStruct ? IlOps.CALL : IlOps.CALLVIRT, g.memberOf(plan, plan.thisSig, cf), 1, 1);
					code.op(IlOps.RET, 1, 0);
				case MField(cf):
					if (TypeFunctions.hasMeta(":functionCode", cf.meta)) throw new Unsupported("@:functionCode", false, cf.pos);
					var tf = switch (cf.expr.expr) {
						case TFunction(tf): tf;
						case _: throw "internal error: method " + what + " has no function";
					}
					g.types.inParams(plan.classParams, cf.params, () -> {
						var body = tf.expr;
						if (m.name == ".ctor") {
							if (!plan.isStruct && !hasSuperCall(body)) initsAndBaseCtor(g, plan, code, lower) else body = withInits(plan.c, body);
						}
						if (m.ownArgs != null) lower.bindOwnArgs(tf, m.args, m.ownArgs) else lower.bindArgs(tf, m.hasThis ? 1 : 0, m.args);
						statement(lower, RReturn, body);
						if (failures.length == 0) lower.finish();
					});
				case MBridge(cf):
					g.types.inParams(plan.classParams, cf.params, () -> bridgeBody(g, plan, m, cf, code, lower));
				case MEntryPoint:
					var boot = g.bootInit();
					if (boot != null) code.opToken(IlOps.CALL, boot, 0, 0);
					if (g.ctx.main != null) statement(lower, RVoid, g.ctx.main);
					if (failures.length == 0) lower.finish();
				case MCctor:
					if (plan.initFlag) initGuard(g, plan, code);
					if (plan.hxPath == fieldLookupPath) fieldTable(g, plan, code);
					cctor(plan, lower);
					if (failures.length == 0) lower.finish();
			});
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = m.pos;
			if (plan.isStd && !u.isBug) stub = u else failures.push(u);
		}
		if (failures.length > 0) {
			for (u in failures) g.report(u);
			return;
		}
		var body = if (stub != null) {
			g.records.push("stubbed " + what + ": " + stub.what);
			stubBody(g, "hxc dotnet: " + what + " uses " + stub.what + ", which " + stub.verb() + " not supported yet");
		} else {
			code.body(code.locals.length == 0 ? 0 : g.mb.standAloneSig(g.sigs.locals(code.locals)));
		}
		g.mb.setBody(m.token, body);
	}

	// A statement outside any block, reported like a block's own in user code.
	static function statement(lower:TexprToIl, ret:Ret, e:TExpr):Void {
		if (lower.onError == null) {
			lower.texpr(ret, e);
			return;
		}
		lower.texpr(ret, {expr: TBlock([e]), type: e.type, pos: e.pos});
	}

	// gencs's guard: `if (C<object>.__hx_init_called) return; C<object>.__hx_init_called = true;`.
	static function initGuard(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var inst = [for (_ in plan.classParams) LObject];
		var owner = plan.isStruct ? LValueType(plan.path, inst) : LClass(plan.path, inst);
		var flag = g.mb.memberRef(g.typeTokenOf(owner), initFlagName, g.sigs.field(LBool));
		var go = code.newLabel();
		code.opToken(IlOps.LDSFLD, flag, 0, 1);
		code.branch(IlOps.BRFALSE, go);
		code.op(IlOps.RET, 0, 0);
		code.mark(go);
		code.ldcI4(1);
		code.opToken(IlOps.STSFLD, flag, 1, 0);
	}

	public static inline final fieldLookupPath = "cs.internal.FieldLookup";

	// FieldLookup's first snapshot, `new FieldTable(ids, names)` with every name FieldHashes recorded,
	// sorted by hash, as gencs fills `fieldIds` and `fields` (gencs.ml). FieldLookup's methods are
	// emitted after every other class's, so the table has them all; nothing in its .cctor comes before.
	static function fieldTable(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var tableField = plan.c.statics.get("table");
		var tableClass = g.runtimeClass("cs.internal.FieldTable");
		var tablePlan = tableClass == null ? null : g.planOf.get(tableClass);
		var ctor = null;
		if (tablePlan != null) for (m in tablePlan.methods) if (m.name == ".ctor" && m.args.length == 2) ctor = m;
		var token = tableField == null ? null : g.fieldTokens.get(tableField);
		if (ctor == null || token == null) throw "internal error: haxe.lang.FieldLookup has no table";
		var entries = FieldHashes.table();
		code.ldcI4(entries.length);
		code.opToken(IlOps.NEWARR, g.typeTokenOf(LInt32), 1, 1);
		for (i in 0...entries.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			code.ldcI4(entries[i].id);
			code.stelem(LInt32, () -> g.typeTokenOf(LInt32));
		}
		code.ldcI4(entries.length);
		code.opToken(IlOps.NEWARR, g.typeTokenOf(LString), 1, 1);
		for (i in 0...entries.length) {
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			code.opToken(IlOps.LDSTR, g.mb.userString(entries[i].name), 0, 1);
			code.opToken(IlOps.STELEM, g.typeTokenOf(LString), 3, 0);
		}
		code.opToken(IlOps.NEWOBJ, ctor.token, 2, 1);
		code.op(IlOps.VOLATILE, 0, 0);
		code.opToken(IlOps.STSFLD, token, 1, 0);
	}

	// gencommon's order: @:readOnly initializers, which C# runs as field initializers first, then
	// __init__, then the other static var initializers in declaration order. FieldLookup's table is
	// fieldTable's.
	static function cctor(plan:ClassPlan, lower:TexprToIl):Void {
		var c = plan.c;
		var readOnly = [], others = [];
		for (f in plan.fields) if (f.flags & FieldAttrs.STATIC != 0 && f.cf.expr != null) {
			if (plan.hxPath == fieldLookupPath && f.cf.name == "table") continue;
			var assign:TExpr = {
				expr: TBinop(OpAssign, {expr: TField({expr: TTypeExpr(TClassDecl(c)), type: f.cf.type, pos: f.cf.pos}, FStatic(c, f.cf)), type: f.cf.type, pos: f.cf.pos}, f.cf.expr),
				type: f.cf.type,
				pos: f.cf.pos
			};
			(TypeFunctions.hasMeta(":readOnly", f.cf.meta) ? readOnly : others).push(assign);
		}
		var exprs = readOnly.concat(c.init == null ? [] : [c.init]).concat(others);
		var block:TExpr = {expr: TBlock(exprs), type: TypeFunctions.tDynamic, pos: c.pos};
		lower.texpr(RVoid, block);
	}

	// The body of a standard-library method that uses something not supported yet.
	public static function stubBody(g:DotnetCtx, message:String):haxe.io.Bytes {
		var code = new IlCode("a stub");
		var ex = LClass({ns: ["System"], nested: [], name: "NotSupportedException"}, []);
		code.opToken(IlOps.LDSTR, g.mb.userString(message), 0, 1);
		code.opToken(IlOps.NEWOBJ, g.mb.memberRef(g.typeTokenOf(ex), ".ctor", g.sigs.method(true, LVoid, [LString], 0)), 1, 1);
		code.op(IlOps.THROW, 1, 0);
		return code.body(0);
	}
}

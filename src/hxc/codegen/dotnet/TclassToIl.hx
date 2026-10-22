package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
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
	token:Int
};

typedef FieldPlan = {cf:TClassField, name:String, flags:Int, sig:IlSigNorm};

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
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
}

// A Haxe class as a TypeDef with its fields and methods. Every member is public, as gencs makes
// them. Members come as instance fields, static fields, .ctor, instance methods, ToString, static
// methods, each in declaration order, then Main() and .cctor.

class TclassToIl {
	static final objectPath:IlPath = {ns: ["System"], nested: [], name: "Object"};
	static final valueTypePath:IlPath = {ns: ["System"], nested: [], name: "ValueType"};

	static function functionSig(g:DotnetCtx, t:T):{args:Array<IlSigNorm>, names:Array<String>, ret:IlSigNorm} {
		return switch (TypeFunctions.follow(t)) {
			case TFun(sig): {
					args: [for (a in sig.args) g.types.toSig(a.t)],
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
				var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG;
				if (isStatic) flags |= MethodAttrs.STATIC;
				else if (isCtor) flags |= MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME;
				else flags |= virtuality(g, c, f, isStruct, implementing.exists(f), sig);
				methods.push({
					kind: MField(f),
					name: isCtor ? ".ctor" : DotnetNames.fieldName(c, f.name),
					flags: flags,
					hasThis: !isStatic,
					ret: isCtor ? LVoid : sig.ret,
					args: sig.args,
					argNames: sig.names,
					generics: [for (p in f.params) p.name],
					pos: f.pos,
					token: 0
				});
			} catch (u:Unsupported) throw at(u, f.pos);
		}
		if (c.constructor != null && !TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			addMethod(c.constructor, false, true);
		} else if (!isInterface && !isStruct) {
			checkParameterlessBase(g, c);
			methods.push(implicitCtor(c.pos, TypeFunctions.hasClassFlag(c, CAbstract)));
		}
		for (cf in c.orderedFields) addMethod(cf, false, false);
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
			token: 0
		};
	}

	// The interfaces the class lists and the ones they extend, as C# writes them all on the type.
	static function interfaceClosure(g:DotnetCtx, c:TClass):Array<ImplementedInterface> {
		var r:Array<ImplementedInterface> = [];
		function add(i:TClass, params:Array<T>) {
			// An extern interface with no .NET counterpart is only a Haxe type.
			if (TypeFunctions.hasClassFlag(i, CExtern) && !g.ctx.netPathMap.exists(Globals.sTypePath(i.path))
				&& DotnetNames.nativeName(i.meta) == null)
				return;
			var sig = g.types.toSig(TInst(i, params));
			for (x in r) if (IlPaths.sigEq(x.sig, sig)) return;
			r.push({c: i, params: params, sig: sig});
			for (sup in i.interfaces) add(sup.c, [for (t in sup.params) TypeFunctions.applyParams(i.params, params, t)]);
		}
		for (i in c.interfaces) add(i.c, i.params);
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
		for (i in interfaces) {
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

	// gencs's modifiers: virtual unless final or inline, override without newslot, abstract, and
	// final virtual for a non-virtual method that implements an interface method.
	static function virtuality(g:DotnetCtx, c:TClass, cf:TClassField, isStruct:Bool, implementsInterface:Bool,
			sig:{args:Array<IlSigNorm>, ret:IlSigNorm}):Int {
		if (TypeFunctions.hasClassFlag(c, CInterface)) return MethodAttrs.VIRTUAL | MethodAttrs.NEW_SLOT | MethodAttrs.ABSTRACT;
		var isAbstract = TypeFunctions.hasClassFieldFlag(cf, CfAbstract);
		if (isOverride(cf)) {
			checkOverride(g, c, cf, sig);
			return MethodAttrs.VIRTUAL | (isAbstract ? MethodAttrs.ABSTRACT : 0);
		}
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

	// An override replaces the base method's slot only with the same signature; a covariant one would
	// silently become a new method.
	static function checkOverride(g:DotnetCtx, c:TClass, cf:TClassField, sig:{args:Array<IlSigNorm>, ret:IlSigNorm}):Void {
		var changed = new Unsupported("overrides that change the signature", true);
		var s = c.superClass;
		var params = s == null ? [] : s.params;
		while (s != null) {
			var base = s.c.fields.get(cf.name);
			if (base != null) {
				if (TypeFunctions.hasClassFlag(s.c, CExtern)) {
					if (s.c.params.length > 0 || c.params.length > 0) throw new Unsupported("overriding methods of generic .NET classes", true);
					var m = try g.externs.method(s.c, cf) catch (_:Unsupported) throw changed;
					if (!m.isVirtual) throw new Unsupported("overriding a non-virtual .NET method", false);
					var ret = switch (m.sig) {
						case LMethod(_, r, _): r;
						case _: throw "internal error: not a method signature";
					}
					if (!IlPaths.sigEq(ret, sig.ret)) throw changed;
					return;
				}
				for (f in [base].concat(base.overloads)) if (sameSig(methodSig(g, s.c, params, f), sig)) return;
				throw changed;
			}
			var next = s.c.superClass;
			if (next == null) return;
			params = [for (t in next.params) TypeFunctions.applyParams(s.c.params, params, t)];
			s = {c: next.c, params: params};
		}
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
		for (m in plan.methods) {
			m.token = mb.method(plan.token, m.flags, 0, m.name, g.sigs.method(m.hasThis, m.ret, m.args, m.generics.length), m.argNames);
			switch (m.kind) {
				case MField(cf):
					g.methodTokens.set(cf, m.token);
					g.methodSigs.set(cf, {ret: m.ret, args: m.args});
					g.ownerOf.set(cf, plan);
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
		for (m in plan.methods) emitMethod(g, plan, m);
	}

	static function label(m:MethodPlan):String {
		return switch (m.kind) {
			case MField(cf): cf.name;
			case MImplicitCtor: "new";
			case MEntryPoint: "Main";
			case MCctor: "__init__";
			case MToString(_): "ToString";
		}
	}

	// The base type's parameterless constructor: a MethodDef token when this module defines it for a
	// non-generic class, else a MemberRef.
	static function baseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var parent = plan.superSig == null ? LClass(objectPath, []) : plan.superSig;
		var token = 0;
		var superPlan = plan.c == null || plan.c.superClass == null ? null : g.planOf.get(plan.c.superClass.c);
		if (superPlan != null && parent.match(LClass(_, []))) for (m in superPlan.methods) if (m.name == ".ctor" && m.args.length == 0) token = m.token;
		if (token == 0) token = g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, [], 0));
		code.ldarg(0);
		code.opToken(IlOps.CALL, token, 1, 0);
	}

	static function descendsFromNative(c:TClass):Bool {
		var s = c.superClass;
		while (s != null) {
			if (TypeFunctions.hasClassFlag(s.c, CExtern)) return true;
			s = s.c.superClass;
		}
		return false;
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
	// class descends from a .NET class (whose constructor C# runs first).
	static function withInits(c:TClass, body:TExpr):TExpr {
		var inits = fieldInits(c);
		if (inits.length == 0) return body;
		var el = switch (body.expr) {
			case TBlock(el): el;
			case _: [body];
		}
		var first = el.length > 0 && isSuperCall(el[0]) && descendsFromNative(c) ? 1 : 0;
		return {expr: TBlock(el.slice(0, first).concat(inits).concat(el.slice(first))), type: body.type, pos: body.pos};
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
					baseCtor(g, plan, code);
					if (plan.c != null) statement(lower, RVoid, {expr: TBlock(fieldInits(plan.c)), type: TypeFunctions.tDynamic, pos: plan.c.pos});
					if (failures.length == 0) lower.finish();
				case MToString(cf):
					if (plan.classParams.length > 0) throw new Unsupported("instance members of generic classes", true, m.pos);
					code.ldarg(0);
					code.opToken(plan.isStruct ? IlOps.CALL : IlOps.CALLVIRT, g.methodTokens.get(cf), 1, 1);
					code.op(IlOps.RET, 1, 0);
				case MField(cf):
					if (TypeFunctions.hasMeta(":functionCode", cf.meta)) throw new Unsupported("@:functionCode", false, cf.pos);
					var tf = switch (cf.expr.expr) {
						case TFunction(tf): tf;
						case _: throw "internal error: method " + what + " has no function";
					}
					g.types.inParams(plan.classParams, cf.params, () -> {
						for (i in 0...tf.args.length) {
							var a = tf.args[i];
							if (a.c != null) throw new Unsupported("default argument values", true, cf.pos);
							lower.bindArg(a.v, i + (m.hasThis ? 1 : 0), m.args[i]);
						}
						var body = tf.expr;
						if (m.name == ".ctor") {
							if (!plan.isStruct && !hasSuperCall(body)) baseCtor(g, plan, code);
							body = withInits(plan.c, body);
						}
						statement(lower, RReturn, body);
						if (failures.length == 0) lower.finish();
					});
				case MEntryPoint:
					var boot = g.bootInit();
					if (boot != null) code.opToken(IlOps.CALL, boot, 0, 0);
					if (g.ctx.main != null) statement(lower, RVoid, g.ctx.main);
					if (failures.length == 0) lower.finish();
				case MCctor:
					cctor(plan, lower);
					if (failures.length == 0) lower.finish();
			});
		} catch (u:Unsupported) {
			if (u.pos == null) u.pos = m.pos;
			if (plan.isStd) stub = u else failures.push(u);
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

	// gencommon's order: @:readOnly initializers, which C# runs as field initializers first, then
	// __init__, then the other static var initializers in declaration order.
	static function cctor(plan:ClassPlan, lower:TexprToIl):Void {
		var c = plan.c;
		var readOnly = [], others = [];
		for (f in plan.fields) if (f.flags & FieldAttrs.STATIC != 0 && f.cf.expr != null) {
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

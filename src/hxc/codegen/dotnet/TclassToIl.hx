package hxc.codegen.dotnet;

import hxc.ast.Position;
import hxc.core.Globals;
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
	superSig:Null<IlSigNorm>,
	fields:Array<FieldPlan>,
	methods:Array<MethodPlan>,
	classParams:TypeParams,
	isStd:Bool,
	token:Int
};

class TypeAttrs {
	public static inline var PUBLIC = 0x1;
	public static inline var ABSTRACT = 0x80;
	public static inline var SEALED = 0x100;
	public static inline var BEFORE_FIELD_INIT = 0x100000;
}

class MethodAttrs {
	public static inline var PRIVATE = 0x1;
	public static inline var FAMILY = 0x4;
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
	public static inline var HIDE_BY_SIG = 0x80;
	public static inline var SPECIAL_NAME = 0x800;
	public static inline var RT_SPECIAL_NAME = 0x1000;
}

class FieldAttrs {
	public static inline var PUBLIC = 0x6;
	public static inline var STATIC = 0x10;
}

// A Haxe class as a TypeDef with its fields and methods. Every member is public, as gencs makes
// them. Members come as instance fields, static fields, .ctor, instance methods, static methods, each
// in declaration order, then Main() and .cctor.

class TclassToIl {
	static final objectPath:IlPath = {ns: ["System"], nested: [], name: "Object"};

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
		if (TypeFunctions.hasClassFlag(c, CInterface)) throw new Unsupported("interfaces", true);
		if (TypeFunctions.hasMeta(":struct", c.meta)) throw new Unsupported("structs", true);
		if (!isStd && TypeFunctions.hasMeta(":classCode", c.meta)) throw new Unsupported("@:classCode", false);
		var superSig = switch (c.superClass) {
			case null: null;
			case s: g.types.toSig(TInst(s.c, s.params));
		}
		if (superSig != null && superSig.match(LObject)) superSig = null;
		if (superSig != null && !superSig.match(LClass(_, _))) throw new Unsupported("extending a value type", false);
		for (i in c.interfaces) {
			// An extern interface with no .NET counterpart is only a Haxe type.
			if (TypeFunctions.hasClassFlag(i.c, CExtern) && !g.ctx.netPathMap.exists(Globals.sTypePath(i.c.path))
				&& DotnetNames.nativeName(i.c.meta) == null)
				continue;
			throw new Unsupported("interfaces", true);
		}

		var fields:Array<FieldPlan> = [];
		function addFields(list:Array<TClassField>, isStatic:Bool) {
			for (cf in list) {
				if (TypeFunctions.hasClassFieldFlag(cf, CfExtern) || !TypeFunctions.isPhysicalField(cf)) continue;
				try switch (cf.kind) {
					case Var(_):
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
			try {
				if (cf.overloads.length > 0) throw new Unsupported("overloaded methods", true);
				if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) throw new Unsupported("abstract methods", true);
				if (cf.expr == null) return;
				var f = g.types.withParams(c.params, cf.params, () -> functionSig(g, cf.type));
				var flags = MethodAttrs.PUBLIC | MethodAttrs.HIDE_BY_SIG;
				if (isStatic) flags |= MethodAttrs.STATIC;
				if (isCtor) flags |= MethodAttrs.SPECIAL_NAME | MethodAttrs.RT_SPECIAL_NAME;
				methods.push({
					kind: MField(cf),
					name: isCtor ? ".ctor" : DotnetNames.fieldName(c, cf.name),
					flags: flags,
					hasThis: !isStatic,
					ret: isCtor ? LVoid : f.ret,
					args: f.args,
					argNames: f.names,
					generics: [for (p in cf.params) p.name],
					pos: cf.pos,
					token: 0
				});
			} catch (u:Unsupported) throw at(u, cf.pos);
		}
		if (c.constructor != null && !TypeFunctions.hasClassFieldFlag(c.constructor, CfExtern)) {
			addMethod(c.constructor, false, true);
		} else {
			checkImplicitCtor(g, c);
			methods.push(implicitCtor(c.pos, TypeFunctions.hasClassFlag(c, CAbstract)));
		}
		for (cf in c.orderedFields) addMethod(cf, false, false);
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
		if (TypeFunctions.hasClassFlag(c, CAbstract)) flags |= TypeAttrs.ABSTRACT;
		if (TypeFunctions.hasClassFlag(c, CFinal)) flags |= TypeAttrs.SEALED;
		if (!hasCctor) flags |= TypeAttrs.BEFORE_FIELD_INIT;
		return {
			c: c,
			hxPath: DotnetTypes.haxePath(TClassDecl(c)),
			path: DotnetNames.typePath(TClassDecl(c)),
			flags: flags,
			superSig: superSig,
			fields: fields,
			methods: methods,
			classParams: c.params,
			isStd: isStd,
			token: 0
		};
	}

	// The base constructor the implicit one calls takes no arguments.
	static function checkImplicitCtor(g:DotnetCtx, c:TClass):Void {
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
				if (!ok) throw new Unsupported("a .NET base class without a parameterless constructor", false);
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
		return {
			c: null,
			hxPath: "EntryPoint__Main",
			path: {ns: mainPath.ns, nested: [], name: "EntryPoint__Main"},
			flags: TypeAttrs.PUBLIC | TypeAttrs.BEFORE_FIELD_INIT,
			superSig: null,
			fields: [],
			methods: [implicitCtor(main.pos, false), entryPoint(main.pos)],
			classParams: [],
			isStd: false,
			token: 0
		};
	}

	// The plan's field and method rows, after every TypeDef row exists.
	public static function write(g:DotnetCtx, plan:ClassPlan):Void {
		var mb = g.mb;
		mb.setExtends(plan.token, plan.superSig == null ? mb.typeToken(objectPath, false) : sigToken(g, plan.superSig));
		if (plan.c != null && plan.isStd && TypeFunctions.hasMeta(":classCode", plan.c.meta)) g.records.push("ignored @:classCode in " + plan.hxPath);
		for (f in plan.fields) {
			var token = mb.field(plan.token, f.flags, f.name, g.sigs.field(f.sig));
			g.fieldTokens.set(f.cf, token);
			g.fieldSigs.set(f.cf, f.sig);
		}
		for (m in plan.methods) {
			m.token = mb.method(plan.token, m.flags, 0, m.name, g.sigs.method(m.hasThis, m.ret, m.args, m.generics.length), m.argNames);
			switch (m.kind) {
				case MField(cf):
					g.methodTokens.set(cf, m.token);
					g.methodSigs.set(cf, {ret: m.ret, args: m.args});
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
		}
	}

	// Haxe requires super(...) only when some ancestor has a constructor; otherwise the constructor
	// calls the base type's parameterless one itself, as C# does.
	static function ancestorHasCtor(c:TClass):Bool {
		var s = c.superClass;
		while (s != null) {
			if (s.c.constructor != null) return true;
			s = s.c.superClass;
		}
		return false;
	}

	// The base type's parameterless constructor: a MethodDef token when this module defines it for a
	// non-generic class, else a MemberRef.
	static function baseCtor(g:DotnetCtx, plan:ClassPlan, code:IlCode):Void {
		var parent = plan.superSig == null ? LClass(objectPath, []) : plan.superSig;
		var token = 0;
		var superPlan = plan.c == null || plan.c.superClass == null ? null : g.planOf.get(plan.c.superClass.c);
		if (superPlan != null && parent.match(LClass(_, []))) for (m in superPlan.methods) if (m.name == ".ctor") token = m.token;
		if (token == 0) token = g.mb.memberRef(g.typeTokenOf(parent), ".ctor", g.sigs.method(true, LVoid, [], 0));
		code.ldarg(0);
		code.opToken(IlOps.CALL, token, 1, 0);
	}

	static function emitMethod(g:DotnetCtx, plan:ClassPlan, m:MethodPlan):Void {
		var what = plan.hxPath + "." + label(m);
		var code = new IlCode(what);
		var failures:Array<Unsupported> = [];
		var stub:Null<Unsupported> = null;
		var lower = new TexprToIl(g, code, m.ret);
		if (!plan.isStd) lower.onError = u -> failures.push(u);
		try {
			g.types.inParams(plan.classParams, [], () -> switch (m.kind) {
				case MImplicitCtor:
					baseCtor(g, plan, code);
					code.op(IlOps.RET, 0, 0);
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
						if (cf.name == "new" && !ancestorHasCtor(plan.c)) baseCtor(g, plan, code);
						statement(lower, RReturn, tf.expr);
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

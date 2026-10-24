package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.TexprTools;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;

// The locals a local function captures, sorted by name then reversed (its closure class's fields and
// constructor arguments), and the type parameters it uses, in gencs's order.
private typedef Captures = {vars:Array<TVar>, params:Array<TClass>};

// gencs's closuresToClass, run over the typed AST before any class is planned. Each local function
// becomes a public class extending haxe.lang.Function, in the package and module of the class whose
// code holds it, named `<Class>_<field>_<line>__Fun`: <field> is the method's name, the split
// constructor's `__hx_ctor_<pack>_<Class>` for a constructor and the instance initializers and
// dynamic methods it runs, `Anon` for the static initializers, and the variable's name for a local
// generic function. Among the classes one class adds, the last one made keeps a name and earlier ones
// with the same name get `_0`, `_1`, ... backwards (gencommon's run_filters). The locals it captures
// become public fields and constructor arguments, sorted by name and reversed; the type parameters it
// uses become the class's. Its body becomes an override of `__hx_invoke<N>_f` (a return type like a
// Float, not an Int64 or a Null<T>) or `_o`, or of `__hx_invokeDynamic` for six arguments or more,
// which first unpacks the arguments; the constructor calls `super(arity, type)`, type 1 for `_f`. The
// function is replaced by `new <Class>(captured)`, or without captures and type parameters by the
// class's cached `__hx_current`. The mapped expressions go to DotnetCtx.closureExprs and closureInits:
// the typed AST is shared with the compilation server and never changed.

@:access(hxc.codegen.dotnet.TexprDynamic)
class ClosuresToClass {
	// gencs's max_arity: from this many arguments on, they come boxed in an object[].
	static inline final maxArity = 6;

	final g:DotnetCtx;
	final fn:TClass;
	final runtime:TClass;
	final added:Array<TClass> = [];
	// The Haxe paths taken, by the program's types and the classes added so far.
	final taken = new Map<String, Bool>();
	// The local generic functions declared so far, by variable id: their class and captured locals.
	final generics = new Map<Int, {c:TClass, vars:Array<TVar>}>();

	// The class whose code is being mapped, the field name its closures take, the closure classes it
	// added (in the order they were made), and whether its type parameters are a split constructor's own
	// (named `<T>_c`, as overloadingConstructor gives the static method its type parameters).
	var owner:TClass;
	var field = "";
	var created:Array<TClass> = [];
	var inSplitCtor = false;

	function new(g:DotnetCtx, fn:TClass, runtime:TClass) {
		this.g = g;
		this.fn = fn;
		this.runtime = runtime;
		for (mt in g.ctx.types) taken.set(Globals.sTypePath(TypeFunctions.tInfos(mt).path), true);
	}

	// Maps the candidates' code and returns the closure classes it made.
	public static function run(g:DotnetCtx, candidates:Array<TClass>):Array<TClass> {
		var fn = g.runtimeClass("cs.internal.Function"), runtime = g.runtimeClass("cs.internal.Runtime");
		if (fn == null || runtime == null || !runtime.statics.exists("undefined")) return [];
		var pass = new ClosuresToClass(g, fn, runtime);
		for (c in candidates) pass.mapClass(c);
		return pass.added;
	}

	// gencommon processes a class's instance fields, then its statics, the split constructor
	// (overloadingConstructor puts it first among them) with the instance initializers and dynamic
	// methods init_funcs moved into it, then the constructor of a class outside the split model, then
	// the static initializers.
	function mapClass(c:TClass):Void {
		if (TypeFunctions.hasClassFlag(c, CInterface)) return;
		owner = c;
		created = [];
		var split = !TypeFunctions.hasMeta(":struct", c.meta) && HxGen.hasCtorModel(c) && !HxGen.descendsFromNative(c);
		methods(c.orderedFields);
		if (split) ctorCode(c, HxGen.ctorName(c), c.params.length > 0);
		methods(c.orderedStatics);
		if (!split) ctorCode(c, "new", false);
		field = "Anon";
		var init = c.init;
		if (init != null && hasFunction(init)) g.closureInits.set(c, map(init));
		for (cf in c.orderedStatics) if (isInitialized(cf)) value(cf);
		rename();
	}

	function methods(list:Array<TClassField>):Void {
		for (cf in list) if (cf.kind.match(Method(MethNormal | MethInline)) && !TypeFunctions.hasClassFieldFlag(cf, CfExtern))
			for (f in [cf].concat(cf.overloads)) method(f, f.name);
	}

	// The constructor's code under `name`: the instance initializers (in TclassToIl.fieldInits's order),
	// the dynamic methods (init_funcs adds them in reverse), then the constructor's own body.
	function ctorCode(c:TClass, name:String, ownParams:Bool):Void {
		field = name;
		inSplitCtor = ownParams;
		var readOnly = [], others = [], dynamics = [];
		for (cf in c.orderedFields) {
			if (!isInitialized(cf)) continue;
			if (cf.kind.match(Method(_))) dynamics.unshift(cf);
			else if (TypeFunctions.hasMeta(":readOnly", cf.meta)) readOnly.push(cf);
			else others.unshift(cf);
		}
		for (cf in readOnly.concat(others).concat(dynamics)) value(cf);
		var ctor = c.constructor;
		if (ctor != null && !TypeFunctions.hasClassFieldFlag(ctor, CfExtern)) for (f in ctor.overloads.concat([ctor])) method(f, name);
		inSplitCtor = false;
	}

	// A variable with an initializer, or a dynamic method, whose value the code sets.
	static function isInitialized(cf:TClassField):Bool {
		if (cf.expr == null || TypeFunctions.hasClassFieldFlag(cf, CfExtern)) return false;
		return switch (cf.kind) {
			case Var(_): TypeFunctions.isPhysicalField(cf);
			case Method(MethDynamic): true;
			case _: false;
		}
	}

	// A method's body: the function stays, the ones inside it become classes.
	function method(f:TClassField, name:String):Void {
		if (f.expr == null) return;
		switch (f.expr.expr) {
			case TFunction(tf) if (hasFunction(tf.expr)):
				field = name;
				g.closureExprs.set(f, TypeFunctions.mk(TFunction(new TFunc(tf.args, tf.type, map(tf.expr))), f.expr.type, f.expr.pos));
			case _:
		}
	}

	// A variable's initializer or a dynamic method's function, which becomes a class itself.
	function value(cf:TClassField):Void {
		if (hasFunction(cf.expr)) g.closureExprs.set(cf, map(cf.expr));
	}

	static function hasFunction(e:TExpr):Bool {
		return e.expr.match(TFunction(_)) || TexprTools.checkExpr(hasFunction, e);
	}

	// Inner functions first, as gencs maps a function's body before the function. A local generic
	// function's declaration goes (each use of it creates its class), as gencs's tparam_anon_decl and
	// tparam_anon_acc have it.
	function map(e:TExpr):TExpr {
		return switch (e.expr) {
			case TFunction(tf):
				closure(e, mapBody(tf), null).expr;
			case TVarExpr(v, init) if (init != null && isGeneric(v) && genericFunction(init) != null):
				declareGeneric(v, genericFunction(init), e.pos);
			case TBinop(OpAssign, {expr: TLocal(v)}, f = {expr: TFunction(_)}) if (isGeneric(v)):
				declareGeneric(v, f, e.pos);
			case TLocal(v) if (generics.exists(v.id)):
				useGeneric(v, v.type, e);
			case TArray({expr: TLocal(v)}, _) if (generics.exists(v.id)):
				useGeneric(v, elementType(v.type), e);
			case _:
				TexprTools.mapExpr(map, e);
		}
	}

	function mapBody(tf:TFunc):TFunc {
		return new TFunc(tf.args, tf.type, map(tf.expr));
	}

	static function isGeneric(v:TVar):Bool {
		return v.extra != null && v.extra.params != null && v.extra.params.length > 0;
	}

	// A local generic function's declared value: the function, or the function in the box the
	// captured_vars filter puts it in.
	static function genericFunction(init:TExpr):Null<TExpr> {
		return switch (init.expr) {
			case TFunction(_): init;
			case TCall({expr: TIdent("__array__")}, [f = {expr: TFunction(_)}]) | TArrayDecl([f = {expr: TFunction(_)}]): f;
			case _: null;
		}
	}

	function declareGeneric(v:TVar, f:TExpr, pos:Position):TExpr {
		var tf = switch (f.expr) {
			case TFunction(tf): tf;
			case _: throw "internal error: not a function";
		}
		var r = closure(f, mapBody(tf), v);
		generics.set(v.id, {c: r.c, vars: r.vars});
		return TypeFunctions.mk(TBlock([]), g.ctx.basic.tvoid, pos);
	}

	// A use of a local generic function: a new instance of its class, its own type parameters bound by
	// the type the use has, Dynamic where nothing binds one.
	function useGeneric(v:TVar, declared:T, e:TExpr):TExpr {
		var info = generics.get(v.id);
		var own = v.extra.params;
		var bound = DotnetTypes.inferParams(own, declared, e.type);
		var params = [
			for (tp in info.c.params) {
				var t = tp.type;
				for (i in 0...own.length) switch (t) {
					case TInst(p, _) if (DotnetTypes.isParam(own[i], p)): t = bound[i];
					case _:
				}
				t;
			}
		];
		return TypeFunctions.mk(TNew(info.c, params, [for (cv in info.vars) local(cv, e.pos)]), e.type, e.pos);
	}

	// The type of a boxed local's values, a NativeArray's element.
	static function elementType(t:T):T {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, [p]) if (c.path.name == "NativeArray" && c.path.pack.length == 1 && c.path.pack[0] == "cs"): p;
			case _: t;
		}
	}

	static function local(v:TVar, pos:Position):TExpr {
		return TypeFunctions.mk(TLocal(v), v.type, pos);
	}

	// The class of the function `fexpr`, whose body `tf` is mapped already, and what replaces it.
	function closure(fexpr:TExpr, tf:TFunc, tvar:Null<TVar>):{c:TClass, vars:Array<TVar>, expr:TExpr} {
		var basic = g.ctx.basic;
		var pos = tf.expr.pos;
		var caps = captures(fexpr, tf);
		var line = Position.lineNumber(fexpr.pos);
		var name = owner.path.name + "_" + (tvar != null ? tvar.name : field) + "_" + (line <= 0 ? 1 : line) + "__Fun";
		var c = TypeFunctions.mkClass(owner.module, {pack: owner.path.pack.copy(), name: name}, pos, pos);
		// Outside gencs's class model, as the classes closuresToClass adds are.
		c.meta = [{name: ":nativeGen", params: [], pos: pos}];
		c.params = [
			for (p in caps.params)
				new TypedTypeParam(inSplitCtor && isOwnerParam(p) ? p.path.name + "_c" : p.path.name, TInst(p, []))
		];
		c.superClass = {c: fn, params: []};
		var thisParams = TypeFunctions.extractParamTypes(c.params);
		var thisType = TInst(c, thisParams);

		var fieldOf = new Map<Int, TClassField>();
		for (v in caps.vars) {
			var cf = TypeFunctions.mkField(v.name, v.type, v.pos, v.pos);
			c.fields.set(cf.name, cf);
			c.orderedFields.push(cf);
			fieldOf.set(v.id, cf);
		}
		function toField(e:TExpr):TExpr {
			return switch (e.expr) {
				case TLocal(v) if (fieldOf.exists(v.id)):
					var ethis = TypeFunctions.mk(TConst(TThis), thisType, e.pos);
					TypeFunctions.mk(TField(ethis, FInstance(c, thisParams, fieldOf.get(v.id))), v.type, e.pos);
				case _:
					TexprTools.mapExpr(toField, e);
			}
		}
		var invoke = invokeMethod(fexpr, new TFunc(tf.args, tf.type, toField(tf.expr)), pos);
		c.fields.set(invoke.cf.name, invoke.cf);
		c.orderedFields.push(invoke.cf);

		// new(captured...) { super(arity, type); this.v = v; ... }
		var ctorArgs = [for (v in caps.vars) TypeFunctions.allocVar(VGenerated, v.name, v.type, pos)];
		var ctorType = TFun({args: [for (a in ctorArgs) {name: a.name, opt: false, t: a.type}], ret: basic.tvoid});
		var superCall = TypeFunctions.mk(TCall(TypeFunctions.mk(TConst(TSuper), TInst(fn, []), pos), [int(invoke.arity, pos), int(invoke.type, pos)]),
			basic.tvoid, pos);
		var body = [superCall];
		for (i in 0...ctorArgs.length) {
			var target = toField(local(caps.vars[i], pos));
			body.push(TypeFunctions.mk(TBinop(OpAssign, target, local(ctorArgs[i], pos)), target.type, pos));
		}
		var ctor = newMethod("new", ctorType, pos);
		var fun = new TFunc([for (a in ctorArgs) {v: a}], basic.tvoid, TypeFunctions.mk(TBlock(body), basic.tvoid, pos));
		ctor.expr = TypeFunctions.mk(TFunction(fun), ctorType, pos);
		c.constructor = ctor;

		added.push(c);
		created.push(c);
		g.addClosureClass(c, owner);

		var expr = if (caps.vars.length == 0 && caps.params.length == 0) {
			// (C.__hx_current != null) ? C.__hx_current : (C.__hx_current = new C())
			var selfType = TInst(c, []);
			var cache = TypeFunctions.mkField("__hx_current", selfType, pos, pos, true, true);
			c.statics.set(cache.name, cache);
			c.orderedStatics.push(cache);
			var cls = TypeFunctions.mk(TTypeExpr(TClassDecl(c)), TypeFunctions.tDynamic, pos);
			function current() return TypeFunctions.mk(TField(cls, FStatic(c, cache)), selfType, pos);
			var isSet = TypeFunctions.mk(TBinop(OpNotEq, current(), TypeFunctions.nullExpr(selfType, pos)), basic.tbool, pos);
			var make = TypeFunctions.mk(TBinop(OpAssign, current(), TypeFunctions.mk(TNew(c, [], []), selfType, pos)), selfType, pos);
			TypeFunctions.mk(TIf(isSet, current(), make), fexpr.type, fexpr.pos);
		} else {
			TypeFunctions.mk(TNew(c, [for (p in caps.params) TInst(p, [])], [for (v in caps.vars) local(v, fexpr.pos)]), fexpr.type, fexpr.pos);
		}
		return {c: c, vars: caps.vars, expr: expr};
	}

	function isOwnerParam(p:TClass):Bool {
		for (tp in owner.params) if (DotnetTypes.isParam(tp, p)) return true;
		return false;
	}

	function int(i:Int, pos:Position):TExpr {
		return TypeFunctions.mk(TConst(TInt(i)), g.ctx.basic.tint, pos);
	}

	static function newMethod(name:String, t:T, pos:Position):TClassField {
		var cf = TypeFunctions.mkField(name, t, pos, pos);
		cf.kind = Method(MethNormal);
		return cf;
	}

	// gencs's get_captured: the captured locals the function reads that it does not declare, and the
	// type parameters of its argument and return types, of the variables it declares and of the
	// locals it captures, the last one found first.
	function captures(fexpr:TExpr, tf:TFunc):Captures {
		var declared = new Map<Int, Bool>();
		var seen = new Map<Int, Bool>();
		var vars:Array<TVar> = [];
		var params:Array<TClass> = [];
		function check(t:T) typeParams(params, t, 0);
		for (a in tf.args) declared.set(a.v.id, true);
		switch (TypeFunctions.follow(fexpr.type)) {
			case TFun(sig):
				for (a in sig.args) check(a.t);
				check(sig.ret);
			case _:
		}
		function walk(e:TExpr):Void {
			switch (e.expr) {
				case TFor(v, _, _):
					declared.set(v.id, true);
					check(v.type);
					TexprTools.iter(walk, e);
				case TFunction(inner):
					for (a in inner.args) declared.set(a.v.id, true);
					switch (TypeFunctions.follow(e.type)) {
						case TFun(sig):
							for (a in sig.args) check(a.t);
							check(sig.ret);
						case _:
					}
					TexprTools.iter(walk, e);
				case TVarExpr(v, init):
					if (!isGeneric(v)) check(v.type);
					declared.set(v.id, true);
					if (init != null) walk(init);
				case TTry(body, catches):
					walk(body);
					for (ct in catches) {
						declared.set(ct.v.id, true);
						walk(ct.expr);
					}
				case TLocal(v) if (isGeneric(v)):
				case TLocal(v) if (TypeFunctions.hasVarFlag(v, VCaptured)):
					if (!declared.exists(v.id) && !seen.exists(v.id)) {
						check(v.type);
						seen.set(v.id, true);
						vars.push(v);
					}
				case _:
					TexprTools.iter(walk, e);
			}
		}
		walk(tf.expr);
		vars.sort((a, b) -> a.name < b.name ? -1 : a.name > b.name ? 1 : a.id - b.id);
		vars.reverse();
		return {vars: vars, params: params};
	}

	// gencs's get_type_params: each type parameter `t` uses, put in front of `acc` when new.
	static function typeParams(acc:Array<TClass>, t:T, depth:Int):Void {
		if (depth > 30) return;
		inline function all(l:Array<T>) for (x in l) typeParams(acc, x, depth + 1);
		switch (t) {
			case TInst(c, []) if (c.kind.match(KTypeParameter(_))):
				if (acc.indexOf(c) < 0) acc.unshift(c);
			case TFun(sig):
				typeParams(acc, sig.ret, depth + 1);
				for (a in sig.args) typeParams(acc, a.t, depth + 1);
			case TDynamic(null):
			case TDynamic(t2):
				typeParams(acc, t2, depth + 1);
			case TAbstract(a, pl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				typeParams(acc, TypeFunctions.getUnderlyingType(a, pl), depth + 1);
			case TAnon(an):
				var names = [for (k in an.fields.keys()) k];
				names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
				for (n in names) {
					var cf = an.fields.get(n);
					var inner:Array<TClass> = [];
					typeParams(inner, cf.type, depth + 1);
					inner.reverse();
					for (p in inner) {
						var own = false;
						for (tp in cf.params) if (DotnetTypes.isParam(tp, p)) own = true;
						if (!own && acc.indexOf(p) < 0) acc.unshift(p);
					}
				}
			case TType(_, pl) | TAbstract(_, pl) | TEnum(_, pl) | TInst(_, pl):
				all(pl);
			case TMono(m):
				if (m.type != null) typeParams(acc, m.type, depth + 1);
			case TLazy(f):
				typeParams(acc, TypeFunctions.lazyType(f), depth + 1);
		}
	}

	// gencs's closure_to_classfield: the override that holds the function's body, with the arguments
	// unpacked first, the last one first (below six arguments), from `__hx_invokeDynamic`'s object[] in
	// order (from six on). A Void function returns null.
	function invokeMethod(fexpr:TExpr, tf:TFunc, pos:Position):{cf:TClassField, arity:Int, type:Int} {
		var basic = g.ctx.basic;
		var sig:TSignature = switch (TypeFunctions.follow(fexpr.type)) {
			case TFun(s): s;
			case _: {args: [for (a in tf.args) {name: a.v.name, opt: a.c != null, t: a.v.type}], ret: tf.type};
		}
		var arity = sig.args.length;
		var type = isNull(sig.ret) ? 0 : TexprDynamic.likeFloat(sig.ret) && !TexprDynamic.likeI64Real(sig.ret) ? 1 : 0;
		var name = arity >= maxArity ? "__hx_invokeDynamic" : "__hx_invoke" + arity + (type == 1 ? "_f" : "_o");
		var base = fn.fields.get(name);
		if (base == null) throw "internal error: haxe.lang.Function has no " + name;
		var baseSig = switch (TypeFunctions.follow(base.type)) {
			case TFun(s): s;
			case _: throw "internal error: haxe.lang.Function." + name + " is not a method";
		}
		var args = [for (a in baseSig.args) TypeFunctions.allocVar(VGenerated, a.name, a.t, pos)];
		var undefined = runtime.statics.get("undefined");
		var rt = TypeFunctions.mk(TTypeExpr(TClassDecl(runtime)), TypeFunctions.tDynamic, pos);

		var unpack:Array<TExpr> = [];
		function declare(a:TFuncArg, value:TExpr) unpack.push(TypeFunctions.mk(TVarExpr(a.v, value), basic.tvoid, pos));
		// The Dynamic half of an argument, or its default value where it is null.
		function fromDynamic(a:TFuncArg, d:TExpr):TExpr {
			var t = a.v.type;
			if (a.c == null) return TypeFunctions.mkCast(d, t, pos);
			var isNull = TypeFunctions.mk(TBinop(OpEq, d, TypeFunctions.nullExpr(d.type, pos)), basic.tbool, pos);
			return TypeFunctions.mk(TIf(isNull, a.c, TypeFunctions.mkCast(d, t, pos)), t, pos);
		}
		if (arity >= maxArity) {
			for (i in 0...tf.args.length) {
				var item = TypeFunctions.mk(TArray(local(args[0], pos), int(i, pos)), TypeFunctions.tDynamic, pos);
				declare(tf.args[i], fromDynamic(tf.args[i], item));
			}
		} else {
			var i = tf.args.length;
			while (i-- > 0) {
				var a = tf.args[i];
				var f = local(args[2 * i], pos), d = local(args[2 * i + 1], pos);
				var undef = TypeFunctions.mk(TField(rt, FStatic(runtime, undefined)), undefined.type, pos);
				var isUndefined = TypeFunctions.mk(TBinop(OpEq, d, undef), basic.tbool, pos);
				declare(a, TypeFunctions.mk(TIf(isUndefined, fromFloat(f, a.v.type, pos), fromDynamic(a, d)), a.v.type, pos));
			}
		}

		var body = isVoid(sig.ret) ? returnsNull(tf.expr) : tf.expr;
		var el = unpack.concat(switch (body.expr) {
			case TBlock(l): l;
			case _: [body];
		});
		var cf = newMethod(name, base.type, tf.expr.pos);
		TypeFunctions.addClassFieldFlag(cf, CfOverride);
		var fun = new TFunc([for (a in args) {v: a}], baseSig.ret, TypeFunctions.mk(TBlock(el), basic.tvoid, pos));
		cf.expr = TypeFunctions.mk(TFunction(fun), base.type, tf.expr.pos);
		return {cf: cf, arity: arity, type: type};
	}

	// The Float half of an argument as its type: a number converts, as C#'s cast does (a Char or small
	// integer through Int); anything else goes boxed, through the conversion of a Dynamic, gencs's
	// `(T)(object)__fn_float1`. The box is a variable: a cast to Dynamic under another cast is lowered
	// as the outer one alone.
	function fromFloat(f:TExpr, t:T, pos:Position):TExpr {
		var value = unNull(t);
		if (TexprDynamic.likeFloatReal(value) || TexprDynamic.likeI64Real(value)) {
			if (isSmallInt(value)) f = TypeFunctions.mkCast(f, g.ctx.basic.tint, pos);
			return TypeFunctions.mkCast(f, t, pos);
		}
		var box = TypeFunctions.allocVar(VGenerated, "__fn_box", TypeFunctions.tDynamic, pos);
		return TypeFunctions.mk(TBlock([
			TypeFunctions.mk(TVarExpr(box, TypeFunctions.mkCast(f, TypeFunctions.tDynamic, pos)), g.ctx.basic.tvoid, pos),
			TypeFunctions.mkCast(local(box, pos), t, pos)
		]), t, pos);
	}

	static function unNull(t:T):T {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [p]) if (a.path.pack.length == 0 && a.path.name == "Null"): p;
			case _: t;
		}
	}

	static function isNull(t:T):Bool {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [_]): a.path.pack.length == 0 && a.path.name == "Null";
			case _: false;
		}
	}

	static function isSmallInt(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []):
				a.path.pack.length == 1 && a.path.pack[0] == "cs" && ["Char16", "Int8", "Int16", "UInt8", "UInt16"].indexOf(a.path.name) >= 0;
			case _: false;
		}
	}

	static function isVoid(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		}
	}

	// A Void function's body as an `_o` override's: `return null` at its end and for each `return`.
	function returnsNull(e:TExpr):TExpr {
		var pos = e.pos;
		function ret() return TypeFunctions.mk(TReturn(TypeFunctions.nullExpr(TypeFunctions.tDynamic, pos)), TypeFunctions.tDynamic, pos);
		function walk(e:TExpr):TExpr {
			return switch (e.expr) {
				case TReturn(null):
					TypeFunctions.mk(TReturn(TypeFunctions.nullExpr(TypeFunctions.tDynamic, e.pos)), e.type, e.pos);
				case TReturn(r):
					// `return f()` with a Void f.
					TypeFunctions.mk(TBlock([walk(r), ret()]), e.type, e.pos);
				case TFunction(_):
					e;
				case _:
					TexprTools.mapExpr(walk, e);
			}
		}
		var body = walk(e);
		var el = switch (body.expr) {
			case TBlock(l): l.copy();
			case _: [body];
		}
		el.push(ret());
		return TypeFunctions.mk(TBlock(el), body.type, pos);
	}

	// Among the classes the class added, the last one made keeps its name; earlier ones with a name that
	// is taken get the first free `_<n>`.
	function rename():Void {
		var i = created.length;
		while (i-- > 0) {
			var c = created[i];
			var base = c.path.name, name = base, n = 0;
			while (taken.exists(Globals.sTypePath({pack: c.path.pack, name: name}))) name = base + "_" + (n++);
			c.path = {pack: c.path.pack, name: name};
			taken.set(Globals.sTypePath(c.path), true);
		}
	}
}

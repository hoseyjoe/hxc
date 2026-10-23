package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlCode;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TexprToIl.Ret;
import hxc.codegen.dotnet.TexprToIl.isNullConst;
import hxc.codegen.dotnet.TexprToIl.isTypeParam;
import hxc.codegen.dotnet.TexprToIl.needVal;
import hxc.codegen.dotnet.TexprToIl.strip;

// Dynamic in TexprToIl, lowered to the haxe.lang.Runtime calls gencs emits: field access through
// getField, setField and callField (dynamicFieldAccess.ml, reflectionCFs.ml), operators through eq,
// refEq, plus, compare and the conversions (dynamicOperators.ml and gencs's handlers), and the
// conversions of a Dynamic to other types (castDetect.ml and gencs's cast handler). Shares its state
// through the TexprToIl that owns it.
@:allow(hxc.codegen.dotnet.TexprToIl, hxc.codegen.dotnet.TexprOps, hxc.codegen.dotnet.TexprFlow, hxc.codegen.dotnet.TexprCalls,
	hxc.codegen.dotnet.ReflectionMembers)
class TexprDynamic {
	final tl:TexprToIl;
	final g:DotnetCtx;
	final code:IlCode;

	public function new(tl:TexprToIl) {
		this.tl = tl;
		g = tl.g;
		code = tl.code;
	}

	// ---- Haxe types as gencs classifies them

	static function isPath(p:Path, pack:Array<String>, name:String):Bool {
		return p.name == name && IlPaths.strsEq(p.pack, pack);
	}

	// gencs's is_dynamic, on the real type: Dynamic, an unbound monomorph, a type parameter, an
	// anonymous structure that is not a class's statics, EnumValue; abstracts are followed, and Null<T>
	// is Dynamic only when its type is (haxe.lang.Null<T> otherwise).
	static function isDynamic(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TDynamic(_): true;
			case TMono(_): true;
			case TAnon(a): !a.status.get().match(Statics(_) | EnumStatics(_) | AbstractStatics(_));
			case TInst(c, _): c.kind.match(KTypeParameter(_));
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): !isTypeParamType(p) && !isBasic(p) && isDynamic(p, depth + 1);
			case TAbstract(a, _) if (isPath(a.path, [], "EnumValue") || isPath(a.path, [], "Dynamic")): true;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): isDynamic(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case _: false;
		}
	}

	// gencs's is_null on the real type: a Null<T> of a basic type or a type parameter, which is
	// haxe.lang.Null<T>.
	static function isNullType(t:T):Bool {
		return switch (TypeFunctions.followWithoutNull(t)) {
			case TAbstract(a, [p]) if (isPath(a.path, [], "Null")): isBasic(p) || isTypeParamType(p);
			case _: false;
		}
	}

	// Followed as Haxe's `follow` does (Null<T> included, abstracts not).
	static function isTDynamic(t:T):Bool return TypeFunctions.follow(t).match(TDynamic(_));

	static function isStringType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): isPath(c.path, [], "String");
			case _: false;
		}
	}

	static function isTypeParamType(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, _): c.kind.match(KTypeParameter(_));
			case _: false;
		}
	}

	// gencs's is_cs_basic_type.
	static function isBasic(t:T, depth = 0):Bool {
		if (depth > 20) return false;
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, []) if (isPath(c.path, ["haxe"], "Int32") || isPath(c.path, ["haxe"], "Int64")): true;
			case TAbstract(a, []) if (isPath(a.path, ["cs"], "Int64") || isPath(a.path, ["cs"], "UInt64") || isPath(a.path, [], "Int")
				|| isPath(a.path, [], "Float") || isPath(a.path, [], "Bool")):
				true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case t2 = TAbstract(_, _) if (likeFloat(t2)): true;
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)): isBasic(TypeFunctions.getUnderlyingType(a, tl), depth + 1);
			case TEnum(en, _): !HxGen.isHxGen(TEnumDecl(en));
			case TInst(c, _): TypeFunctions.hasMeta(":struct", c.meta);
			case _: false;
		}
	}

	// gencommon's like_float and like_int: Float or Int, or an abstract with a from or to cast to one.
	static function likeFloat(t:T, depth = 0):Bool {
		if (depth > 10) return false;
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []) if (isPath(a.path, [], "Float") || isPath(a.path, [], "Int")): true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case TAbstract(a, _): Lambda.exists(a.from, x -> likeFloat(x, depth + 1)) || Lambda.exists(a.to, x -> likeFloat(x, depth + 1));
			case _: false;
		}
	}

	static function likeInt(t:T, depth = 0):Bool {
		if (depth > 10) return false;
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, []) if (isPath(a.path, [], "Int")): true;
			case TAbstract(a, _) if (isPath(a.path, ["cs"], "Pointer")): false;
			case TAbstract(a, _): Lambda.exists(a.from, x -> likeInt(x, depth + 1)) || Lambda.exists(a.to, x -> likeInt(x, depth + 1));
			case _: false;
		}
	}

	// A field access gencs reaches through Runtime: a field of a Dynamic or of an anonymous structure
	// that is not a class's statics. A name the receiver's class declares is its own field in gencs.
	static function isDynamicReceiver(fa:TFieldAccess, obj:TExpr):Bool {
		return switch (fa) {
			case FDynamic(n): !isClassField(obj.type, n);
			case FAnon(_): isDynamic(obj.type);
			case _: false;
		}
	}

	static function isClassField(t:T, name:String):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (!c.kind.match(KTypeParameter(_))): TypeFunctions.rawClassFieldOpt(f -> f.type, c, params, name) != null;
			case _: false;
		}
	}

	static function fieldName(fa:TFieldAccess):String {
		return switch (fa) {
			case FDynamic(n): n;
			case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf): cf.name;
			case FEnum(_, ef): ef.name;
		}
	}

	// ---- haxe.lang.Runtime

	// The static method of haxe.lang.Runtime with this name, the overload whose first argument is
	// `first` when it has several.
	function runtimeMethod(name:String, ?first:IlSigNorm):{token:Int, m:{ret:IlSigNorm, args:Array<IlSigNorm>}} {
		var rt = g.runtimeClass("cs.internal.Runtime");
		if (rt == null) throw new Unsupported("Dynamic without haxe.lang.Runtime", false);
		g.types.checkKept(TClassDecl(rt));
		var cf = rt.statics.get(name);
		if (cf != null) for (f in [cf].concat(cf.overloads)) {
			var m = g.methodSigs.get(f), token = g.methodTokens.get(f);
			if (m == null || token == null) continue;
			if (first == null || m.args.length > 0 && IlPaths.sigEq(m.args[0], first)) return {token: token, m: m};
		}
		throw new Unsupported("haxe.lang.Runtime." + name, false);
	}

	// Calls a Runtime method whose arguments are on the stack; `margs` instantiate a generic one.
	function runtimeCall(name:String, ?first:IlSigNorm, ?margs:Array<IlSigNorm>):IlSigNorm {
		var r = runtimeMethod(name, first);
		var token = margs == null || margs.length == 0 ? r.token : g.mb.methodSpec(r.token, g.sigs.methodSpec(margs));
		code.opToken(IlOps.CALL, token, r.m.args.length, r.m.ret.match(LVoid) ? 0 : 1);
		return margs == null ? r.m.ret : DotnetTypes.substitute(r.m.ret, [], margs);
	}

	// Std.string, which gencs writes for a Dynamic or a type parameter in a String concatenation; the
	// object on the stack.
	function stdString():Void {
		var std = switch (g.types.typeNamed("Std")) {
			case TClassDecl(c): c;
			case _: null;
		}
		var cf = std == null ? null : std.statics.get("string");
		var token = cf == null ? null : g.methodTokens.get(cf);
		if (token == null) throw new Unsupported("Dynamic in string concatenation without Std.string", false);
		g.types.checkKept(TClassDecl(std));
		code.opToken(IlOps.CALL, token, 1, 1);
	}

	// A value of type `from` where `ret` wants it, through the expression's own type `own` as gencs's
	// casts to the expression's type do.
	function finish(from:IlSigNorm, own:IlSigNorm, ret:Ret):Void {
		if (!needVal(ret) || own.match(LVoid)) {
			tl.coerce(from, ret);
			return;
		}
		tl.convert(from, own);
		tl.coerce(own, ret);
	}

	function own(e:TExpr):IlSigNorm return tl.sig(e.type);

	// ---- conversions

	// The object on the stack as a `to`, as gencs converts a Dynamic: Runtime.toInt (then C#'s cast to a
	// smaller integer), toDouble (then to Single), toBool, toString, genericCast<T> for a type parameter,
	// C#'s cast for any other type. Inside haxe.lang.Runtime gencs writes C#'s cast for all but Bool.
	function toSig(to:IlSigNorm):Void {
		if (to.match(LObject)) return;
		if (tl.inRuntimeClass() && !to.match(LBool)) {
			if (DotnetTypes.isValueType(to) || isTypeParam(to)) code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1) else tl.castTo(to);
			return;
		}
		switch (to) {
			case LInt32 | LUInt32:
				runtimeCall("toInt");
			case LInt8 | LUInt8 | LInt16 | LUInt16 | LChar:
				runtimeCall("toInt");
				code.op(switch (to) {
					case LInt8: IlOps.CONV_I1;
					case LUInt8: IlOps.CONV_U1;
					case LInt16: IlOps.CONV_I2;
					case _: IlOps.CONV_U2;
				}, 1, 1);
			case LFloat64:
				runtimeCall("toDouble");
			case LFloat32:
				runtimeCall("toDouble");
				code.op(IlOps.CONV_R4, 1, 1);
			case LBool:
				runtimeCall("toBool");
			case LString:
				runtimeCall("toString");
			case LTypeParam(_) | LMethodTypeParam(_):
				runtimeCall("genericCast", null, [to]);
			case _ if (DotnetTypes.isValueType(to)):
				code.opToken(IlOps.UNBOX_ANY, g.typeTokenOf(to), 1, 1);
			case _:
				tl.castTo(to);
		}
	}

	// ---- field access

	// Pushes the receiver, the name and its hash, the start of every Runtime field call.
	function fieldHead(obj:TExpr, name:String):Void {
		tl.texpr(RValue(LObject), obj);
		code.opToken(IlOps.LDSTR, g.mb.userString(name), 0, 1);
		code.ldcI4(FieldHashes.use(name));
	}

	// `obj.name` through Runtime.getField(obj, "name", hash, throwErrors), or getField_f when the access
	// is typed like a Float (`resultType`), then converted to it; `e` is the expression whose value this is.
	function fieldGet(ret:Ret, e:TExpr, obj:TExpr, name:String, resultType:T, throwErrors:Bool):Void {
		var isFloat = likeFloat(resultType);
		fieldHead(obj, name);
		code.ldcI4(throwErrors ? 1 : 0);
		if (isFloat) {
			runtimeCall("getField_f", LObject);
			// gencs casts the Float to the access's type, then the value goes where the expression goes.
			var rs = tl.sig(resultType);
			if (!needVal(ret)) {
				tl.coerce(LFloat64, ret);
				return;
			}
			tl.convert(LFloat64, rs);
			finish(rs, own(e), ret);
		} else {
			runtimeCall("getField", LObject);
			finish(LObject, own(e), ret);
		}
	}

	// `obj.name = value` through Runtime.setField, or setField_f with the value as a Float when the
	// assignment is typed like a Float (`fieldType`); its value is what the call returns.
	function fieldSet(ret:Ret, e:TExpr, obj:TExpr, name:String, value:TExpr, fieldType:T):Void {
		var isFloat = likeFloat(fieldType);
		fieldHead(obj, name);
		tl.texpr(RValue(isFloat ? LFloat64 : LObject), value);
		if (isFloat) {
			runtimeCall("setField_f", LObject);
			if (!needVal(ret)) {
				tl.coerce(LFloat64, ret);
				return;
			}
			var rs = tl.sig(fieldType);
			tl.convert(LFloat64, rs);
			finish(rs, own(e), ret);
		} else {
			runtimeCall("setField", LObject);
			finish(LObject, own(e), ret);
		}
	}

	// `obj.name(args)` through Runtime.callField(obj, "name", hash, new object[]{args}), null for no
	// arguments; the result is converted to the call's type.
	function fieldCall(ret:Ret, e:TExpr, obj:TExpr, name:String, args:Array<TExpr>):Void {
		fieldHead(obj, name);
		pushObjects(args);
		runtimeCall("callField", LObject);
		finish(LObject, own(e), ret);
	}

	// C#'s `new object[]{...}`, or null for no values.
	function pushObjects(args:Array<TExpr>):Void {
		if (args.length == 0) {
			code.op(IlOps.LDNULL, 0, 1);
			return;
		}
		var objToken = g.typeTokenOf(LObject);
		code.ldcI4(args.length);
		code.opToken(IlOps.NEWARR, objToken, 1, 1);
		for (i in 0...args.length) {
			if (strip(args[i]).expr.match(TUnop(Spread, _, _))) throw new Unsupported("the spread operator", false);
			code.op(IlOps.DUP, 1, 2);
			code.ldcI4(i);
			tl.texpr(RValue(LObject), args[i]);
			code.opToken(IlOps.STELEM, objToken, 3, 0);
		}
	}

	// The type a field named `name` has on a value of type `t` (a class instance's or an anonymous
	// structure's), or Dynamic, as gencs's mk_field_access types Reflect.field and setField with a
	// constant name.
	static function fieldTypeOn(t:T, name:String):T {
		switch (TypeFunctions.follow(t)) {
			case TInst(c, params) if (!c.kind.match(KTypeParameter(_))):
				var r = TypeFunctions.rawClassFieldOpt(f -> f.type, c, params, name);
				if (r != null) return r.t;
			case TAnon(a) if (a.fields.exists(name)):
				return a.fields.get(name).type;
			case _:
		}
		return TypeFunctions.tDynamic;
	}

	// Reflect.field(o, "name") and Reflect.setField(o, "name", v) with a constant name, as field access
	// that does not throw for a missing field; false for any other call.
	function reflectCall(ret:Ret, e:TExpr, c:TClass, cf:TClassField, args:Array<TExpr>):Bool {
		if (c.path.pack.length != 0 || c.path.name != "Reflect") return false;
		var name = args.length < 2 ? null : switch (strip(args[1]).expr) {
			case TConst(TString(s)): s;
			case _: null;
		}
		if (name == null) return false;
		switch [cf.name, args.length] {
			case ["field", 2]:
				// An anonymous structure or Dynamic reads as Dynamic, a class instance as its field's type.
				fieldGet(ret, e, args[0], name, isDynamic(args[0].type) ? TypeFunctions.tDynamic : fieldTypeOn(args[0].type, name), false);
				return true;
			case ["setField", 3]:
				fieldSet(ret, e, args[0], name, args[2], fieldTypeOn(args[0].type, name));
				return true;
			case _:
				return false;
		}
	}

	// ---- operators

	// gencs's should_handle_opeq: Dynamic, an anonymous structure, a monomorph, a type parameter or a
	// Null<T> of a value type.
	static function handlesEq(t:T):Bool return isDynamic(t) || isNullType(t);

	static function isUndefined(e:TExpr):Bool return TexprOps.isUndefined(e);

	// Whether `==` and `!=` go through Runtime: not a comparison of a Dynamic or Null<T> with literal null,
	// nor one with Runtime.undefined.
	static function eqChanges(e1:TExpr, e2:TExpr):Bool {
		if (isNullConst(e1) && (!isTypeParamType(e2.type) && isDynamic(e2.type) || isNullType(e2.type))) return false;
		if (isNullConst(e2) && (!isTypeParamType(e1.type) && isDynamic(e1.type) || isNullType(e1.type))) return false;
		if (isUndefined(e1) || isUndefined(e2)) return false;
		return handlesEq(e1.type) || handlesEq(e2.type);
	}

	// Lowers `e` (op e1 e2) when an operand makes it Dynamic, as gencs's DynamicOperators does; false for
	// the operators that lower as usual.
	function binop(ret:Ret, e:TExpr, op:Binop, e1:TExpr, e2:TExpr):Bool {
		switch (op) {
			case OpEq | OpNotEq:
				if (!eqChanges(e1, e2)) return false;
				// Runtime.refEq when neither side is basic, Dynamic, a String or a type parameter.
				var isBasicOp = isBasic(e1.type) || isBasic(e2.type);
				var isRef = !isBasicOp && !(isTDynamic(e1.type) || isTDynamic(e2.type) || isStringType(e1.type) || isStringType(e2.type)
					|| isTypeParamType(e1.type) || isTypeParamType(e2.type));
				tl.texpr(RValue(LObject), e1);
				tl.texpr(RValue(LObject), e2);
				runtimeCall(isRef ? "refEq" : "eq");
				if (op.match(OpNotEq)) tl.ops.not();
				finish(LBool, own(e), ret);
				return true;
			case OpAdd:
				if (!(isDynamic(e1.type) || isDynamic(e2.type))) return false;
				// A String result is a concatenation, lowered with the other String operands.
				if (tl.sig(e.type).match(LString)) return false;
				tl.texpr(RValue(LObject), e1);
				tl.texpr(RValue(LObject), e2);
				runtimeCall("plus");
				finish(LObject, own(e), ret);
				return true;
			case OpLt | OpLte | OpGt | OpGte:
				if (isDynamic(e.type) || isDynamic(e1.type) || isDynamic(e2.type) || isStringType(e1.type) || isStringType(e2.type)) {
					// String.CompareOrdinal(a, b) <op> 0 when the left side is a String, else
					// Runtime.compare(a, b) <op> 0.
					var ordinal = isStringType(e1.type);
					tl.texpr(RValue(ordinal ? LString : LObject), e1);
					tl.texpr(RValue(ordinal ? LString : LObject), e2);
					if (ordinal) {
						code.opToken(IlOps.CALL, g.mb.memberRef(g.typeTokenOf(LString), "CompareOrdinal",
							g.sigs.method(false, LInt32, [LString, LString], 0)), 2, 1);
					} else {
						runtimeCall("compare");
					}
					code.ldcI4(0);
					switch (op) {
						case OpLt: code.op(IlOps.CLT, 2, 1);
						case OpGt: code.op(IlOps.CGT, 2, 1);
						case OpLte:
							code.op(IlOps.CGT, 2, 1);
							tl.ops.not();
						case _:
							code.op(IlOps.CLT, 2, 1);
							tl.ops.not();
					}
					finish(LBool, own(e), ret);
					return true;
				}
				return false;
			case OpSub | OpMult | OpDiv | OpMod | OpAnd | OpOr | OpXor | OpShl | OpShr | OpUShr:
				if (!(isDynamic(e.type) || isDynamic(e1.type) || isDynamic(e2.type))) return false;
				// Arithmetic on Floats (Ints when the expression is typed Int), bitwise operators on Ints.
				var t = op.match(OpSub | OpMult | OpDiv | OpMod) && !likeInt(e.type) ? LFloat64 : LInt32;
				tl.texpr(RValue(t), e1);
				tl.ops.numericTail(op, t, e2, t, false);
				finish(t, own(e), ret);
				return true;
			case _:
				return false;
		}
	}

	// `-e1` and `~e1` on a Dynamic: through Runtime.toDouble and toInt; false otherwise.
	function unary(ret:Ret, e:TExpr, op:Unop, e1:TExpr):Bool {
		if (!isDynamic(e1.type) && !isDynamic(e.type)) return false;
		switch (op) {
			case Neg:
				var t = likeFloat(e.type) ? tl.sig(e.type) : LFloat64;
				if (!t.match(LFloat64 | LInt32)) t = LFloat64;
				tl.texpr(RValue(t), e1);
				code.op(IlOps.NEG, 1, 1);
				finish(t, own(e), ret);
			case NegBits:
				tl.texpr(RValue(LInt32), e1);
				code.op(IlOps.NOT, 1, 1);
				finish(LInt32, own(e), ret);
			case _:
				return false;
		}
		return true;
	}

	// The access `obj.name` gencs reaches through Runtime, or null.
	static function dynamicField(e:TExpr):Null<{obj:TExpr, name:String}> {
		return switch (strip(e).expr) {
			case TField(obj, fa) if (isDynamicReceiver(fa, obj)): {obj: obj, name: fieldName(fa)};
			case _: null;
		}
	}

	// `++` and `--` on a Dynamic, as Floats: a field through getField_f and setField_f, a variable or
	// other place by Runtime.toDouble and a boxed result, as gencs's DynamicOperators writes it.
	function incDec(ret:Ret, e:TExpr, increment:Bool, postfix:Bool, e1:TExpr):Bool {
		var df = dynamicField(e1);
		if (df == null && !isDynamic(e1.type) && !isNullType(e1.type)) return false;
		function step() {
			code.opR8(IlOps.LDC_R8, 1.0, 0, 1);
			code.op(increment ? IlOps.ADD : IlOps.SUB, 2, 1);
		}
		var kept = needVal(ret) ? code.addLocal(LFloat64) : -1;
		if (df != null) {
			tl.texpr(RValue(LObject), df.obj);
			var recv = code.addLocal(LObject);
			code.stloc(recv);
			var hash = FieldHashes.use(df.name);
			code.ldloc(recv);
			code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
			code.ldcI4(hash);
			code.ldcI4(1);
			runtimeCall("getField_f", LObject);
			if (postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			step();
			var next = code.addLocal(LFloat64);
			code.stloc(next);
			code.ldloc(recv);
			code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
			code.ldcI4(hash);
			code.ldloc(next);
			runtimeCall("setField_f", LObject);
			// setField_f returns the value it stored.
			if (!postfix && kept >= 0) code.stloc(kept) else code.op(IlOps.POP, 1, 0);
		} else {
			var p = tl.place(e1);
			if (p == null) throw new Unsupported("this kind of assignment", false);
			p.prepare();
			p.load();
			tl.convert(p.sig, LFloat64);
			if (postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			step();
			if (!postfix && kept >= 0) {
				code.op(IlOps.DUP, 1, 2);
				code.stloc(kept);
			}
			tl.convert(LFloat64, p.sig);
			p.store();
		}
		if (kept >= 0) {
			code.ldloc(kept);
			finish(LFloat64, own(e), ret);
		}
		return true;
	}

	// `lhs op= rhs` with a Dynamic operand, as gencs's DynamicOperators writes it: `lhs = lhs op rhs`
	// with the operator lowered as above (the receiver of a Dynamic field in a temporary); `+=` is
	// Dynamic only for a Dynamic left side.
	function compound(ret:Ret, e:TExpr, op:Binop, lhs:TExpr, rhs:TExpr):Bool {
		var changes = op.match(OpAdd) ? isDynamic(lhs.type) || isNullType(lhs.type) : isDynamic(e.type) || isDynamic(lhs.type) || isDynamic(rhs.type);
		if (!changes || tl.sig(e.type).match(LString)) return false;
		// The value of `lhs op rhs`, typed as the assignment, with lhs's value pushed by `load` as `ls`.
		function value(load:Void->Void, ls:IlSigNorm):IlSigNorm {
			if (op.match(OpAdd)) {
				load();
				tl.convert(ls, LObject);
				tl.texpr(RValue(LObject), rhs);
				runtimeCall("plus");
				var t = own(e);
				tl.convert(LObject, t);
				return t;
			}
			var t = op.match(OpSub | OpMult | OpDiv | OpMod) && !likeInt(e.type) ? LFloat64 : LInt32;
			load();
			tl.convert(ls, t);
			tl.ops.numericTail(op, t, rhs, t, false);
			return t;
		}
		var df = dynamicField(lhs);
		if (df != null) {
			tl.texpr(RValue(LObject), df.obj);
			var recv = code.addLocal(LObject);
			code.stloc(recv);
			var hash = FieldHashes.use(df.name);
			var isFloat = likeFloat(e.type);
			code.ldloc(recv);
			code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
			code.ldcI4(hash);
			var v = value(() -> {
				code.ldloc(recv);
				code.opToken(IlOps.LDSTR, g.mb.userString(df.name), 0, 1);
				code.ldcI4(hash);
				code.ldcI4(1);
				runtimeCall("getField", LObject);
			}, LObject);
			tl.convert(v, isFloat ? LFloat64 : LObject);
			runtimeCall(isFloat ? "setField_f" : "setField", LObject);
			finish(isFloat ? LFloat64 : LObject, own(e), ret);
			return true;
		}
		var p = tl.place(lhs);
		if (p == null) throw new Unsupported("this kind of assignment", false);
		p.prepare();
		var v = value(p.load, p.sig);
		tl.convert(v, p.sig);
		var tmp = needVal(ret) ? tl.ops.keep(p) : -1;
		p.store();
		if (needVal(ret)) {
			if (tmp >= 0) code.ldloc(tmp);
			finish(p.sig, own(e), ret);
		}
		return true;
	}

	// ---- Std.isOfType

	// Std.isOfType(o, T) with a type expression, inline as gencs writes it (gencs.ml's Std.is handler):
	// C#'s `is`, `o is double || o is int || o is uint` for Float, `o is int || o is uint ||
	// Runtime.isInt(o)` for Int, `o is uint || Runtime.isUInt(o)` for UInt (plain `is` for all three
	// inside haxe.lang.Runtime), and not null for Dynamic.
	function isOfType(ret:Ret, obj:TExpr, texpr:TExpr):Void {
		var mt = switch (texpr.expr) {
			case TTypeExpr(mt): mt;
			case _: throw "internal error: not a type expression";
		}
		// An abstract named as a value is its implementation class.
		var path = switch (mt) {
			case TClassDecl({kind: KAbstractImpl(a)}): DotnetTypes.haxePath(TAbstractDecl(a));
			case _: DotnetTypes.haxePath(mt);
		}
		tl.texpr(RValue(LObject), obj);
		if (path == "Dynamic") {
			code.op(IlOps.LDNULL, 0, 1);
			code.op(IlOps.CGT_UN, 2, 1);
			tl.coerce(LBool, ret);
			return;
		}
		// A generic class is tested through gencs's companion interface, plan 3c.
		if (TypeFunctions.tParams(mt).length > 0) throw new Unsupported("Std.isOfType with a generic type", false);
		var tests:Array<IlSigNorm> = [], call:Null<String> = null;
		if (!tl.inRuntimeClass()) switch (path) {
			case "Float": tests = [LFloat64, LInt32, LUInt32];
			case "Int":
				tests = [LInt32, LUInt32];
				call = "isInt";
			case "UInt":
				tests = [LUInt32];
				call = "isUInt";
			case _:
		}
		if (tests.length == 0) {
			code.opToken(IlOps.ISINST, g.typeTokenOf(tl.calls.typeArg(texpr)), 1, 1);
			code.op(IlOps.LDNULL, 0, 1);
			code.op(IlOps.CGT_UN, 2, 1);
			tl.coerce(LBool, ret);
			return;
		}
		var tmp = code.addLocal(LObject);
		code.stloc(tmp);
		var yes = code.newLabel(), end = code.newLabel();
		for (s in tests) {
			code.ldloc(tmp);
			code.opToken(IlOps.ISINST, g.typeTokenOf(s), 1, 1);
			code.branch(IlOps.BRTRUE, yes);
		}
		if (call != null) {
			code.ldloc(tmp);
			runtimeCall(call);
		} else {
			code.ldcI4(0);
		}
		code.branch(IlOps.BR, end);
		code.mark(yes);
		code.ldcI4(1);
		code.mark(end);
		tl.coerce(LBool, ret);
	}
}
